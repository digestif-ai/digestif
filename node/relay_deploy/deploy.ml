(* The deploy pass of `digestif run` (docs/releases.md, The deploy step). It is due when this node
   operates a relay (Operate), folds a newest relay release newer than the version the relay
   reports and not refused on it, holds a token Cloudflare has not refused, and no node switch is
   on trial. Then:

   1. Verify: download the bundle, check its size and sha256 against the manifest, unpack it, and
      check that its migrations are the manifest's, byte for byte.
   2. Migrations: read d1_migrations (the table `wrangler d1 migrations apply` keeps) through the D1
      query API and apply each listed migration it lacks, in order, each with its row in one
      request.
   3. Upload: the bundle's assets through an assets upload session, then the module as a new
      Worker version with keep_bindings, tagged relay-v<version> and annotated with the bundle's
      sha256; a version already carrying both is reused.
   4. Deploy: record the version serving now as the rollback target, then deploy the new one at
      100%; a pass finding it already serving deploys nothing.

   A bundle carrying a Durable Object migration tag the Worker has not applied takes 3 and 4 as
   one step instead: the rollback target recorded, the module uploaded as the Worker script itself
   with the migrations the Worker lacks, which serves it at once, since a version upload cannot
   apply a migration.
   5. Health check: a signed GET /v0/circle at the home circle's address, <url>/c/<root hex>,
      answering 200 with this relay_version and the circle's root, and GET /app/ answering 200,
      within two minutes of awake time.
   6. Kept, or rolled back to the recorded version, the release refused on this relay for good;
      the rollback's check reads the unsigned GET /v0/version, which every supported relay release
      answers, and GET /app/.

   A step failing before 4 changes nothing the relay serves and is kept as pending, tried again on
   the update pass's backoff. An answer saying the token itself is wrong, expired or lacks a
   permission waits for a new token; that is read from Cloudflare's error code, so a 401 or 403 of
   any other code, and an account with no workers.dev subdomain, are pending too, each with a digest
   line saying what Cloudflare answered. A migration D1 refuses, and a
   signed bundle that cannot be deployed as it stands, are refused for good: a later pass would
   meet the same bytes. Every step reads where the relay is, so a pass interrupted by sleep resumes
   there. *)

module Version = Digestif_update.Version
module Release = Digestif_update.Release
module Cf = Cloudflare

type outcome =
  | Deployed of { url : string; version : Version.t }
  | Rolled_back of {
      url : string;
      version : Version.t;
      to_ : string;
      why : string;
    }
  | Rollback_failed of { url : string; version : Version.t; why : string }
  | Refused of { url : string; version : Version.t; why : string }
  | Pending of { url : string; why : string; retry_at : float }
  | Token_refused of { url : string; why : string }

let outcome_to_string = function
  | Deployed { url; version } ->
      Printf.sprintf "deployed relay %s to %s" (Version.to_string version) url
  | Rolled_back { url; version; to_; why } ->
      Printf.sprintf
        "relay %s failed its health check on %s (%s); rolled back to %s"
        (Version.to_string version)
        url why to_
  | Rollback_failed { url; version; why } ->
      Printf.sprintf "relay %s failed on %s and the rollback failed too: %s"
        (Version.to_string version)
        url why
  | Refused { url; version; why } ->
      Printf.sprintf "relay %s is refused on %s: %s"
        (Version.to_string version)
        url why
  | Pending { url; why; retry_at } ->
      Printf.sprintf "the deploy to %s is pending: %s; retry at %s" url why
        (Time_fmt.of_unix_local retry_at)
  | Token_refused { url; why } ->
      Printf.sprintf "the deploy to %s waits for a new token: %s" url why

(* What the pass reaches the world through, so tests put a fake account, relay and clock behind
   it. *)
type env = {
  cloudflare : Cf.transport;
  form : Cf.form_transport;
  relay : Relay_client.transport;
  fetch : Digestif_update.Feed.fetch;
  sleep : float -> unit;
  wall : unit -> float;
}

let default_env =
  {
    cloudflare = Cf.curl;
    form = Cf.form_curl;
    relay = Relay_client.curl;
    fetch = Digestif_update.Feed.curl;
    sleep = Unix.sleepf;
    wall = Unix.gettimeofday;
  }

(* The health check's bound and step, in awake seconds, as a node's trial counts them. *)
let health_bound = 120.
let health_step = 1.

(* Why a step stopped the pass. *)
type stop =
  | Retry of string * string  (** the step, and why: pending *)
  | Held of string * Cf.error
      (** the step, and Cloudflare's refusal that is not the token's: pending,
          and the digest says what it answered *)
  | Token of string  (** Cloudflare refused the token *)
  | Refuse of string  (** this release never deploys on this relay *)

let ( let* ) = Result.bind

(* A Cloudflare error from [step]: a refused token waits for a new one, anything else is retried (a
   401 or 403 that is not the token's, and an account that is not set up, with a digest line) unless
   [rejected] says what a refusal Cloudflare means is. *)
let cf ?rejected step = function
  | Ok v -> Ok v
  | Error (Cf.Unauthorized _ as e) -> Error (Token (Cf.error_to_string e))
  | Error ((Cf.No_subdomain _ | Cf.Forbidden _) as e) -> Error (Held (step, e))
  | Error (Cf.Rejected _ as e) when rejected <> None ->
      Error (Refuse (Option.get rejected ^ ": " ^ Cf.error_to_string e))
  | Error e -> Error (Retry (step, Cf.error_to_string e))

let host url =
  let rest =
    match String.index_opt url ':' with
    | Some i when String.length url > i + 3 && String.sub url i 3 = "://" ->
        String.sub url (i + 3) (String.length url - i - 3)
    | _ -> url
  in
  match String.index_opt rest '/' with
  | Some i -> String.sub rest 0 i
  | None -> rest

let read path = In_channel.with_open_bin path In_channel.input_all

let write path bytes =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes)

(* Standard base64 with padding, which the assets upload takes. *)
let base64 s =
  let u =
    String.map (function '-' -> '+' | '_' -> '/' | c -> c) (B64url.encode s)
  in
  u ^ String.make ((4 - (String.length u mod 4)) mod 4) '='

(* bundle.json: how the module is uploaded. *)
type bundle = {
  main_module : string;
  compatibility_date : string;
  compatibility_flags : string list;
  assets_binding : string;
  html_handling : string;
  run_worker_first : bool;
  durable_objects : (string * string) list;
      (** each Durable Object binding's name and the class of the module it
          names *)
  migrations : (string * Yojson.Safe.t) list;
      (** every Durable Object migration step, oldest first: its tag and the
          step *)
}

(* bundle.json's Durable Object bindings and migration steps: absent is none, and anything else
   that is not a list of what a deploy reads refuses the bundle. *)
let durable_objects_of = function
  | None -> Ok []
  | Some (`List l) ->
      List.fold_right
        (fun b acc ->
          let* acc = acc in
          match b with
          | `Assoc f -> (
              match
                (List.assoc_opt "name" f, List.assoc_opt "class_name" f)
              with
              | Some (`String n), Some (`String c) when n <> "" && c <> "" ->
                  Ok ((n, c) :: acc)
              | _ ->
                  Error
                    "bundle.json names a Durable Object binding without its \
                     name and class")
          | _ -> Error "bundle.json's durable_objects is not a list of objects")
        l (Ok [])
  | Some _ -> Error "bundle.json's durable_objects is not a list"

let migrations_of = function
  | None -> Ok []
  | Some (`List l) ->
      let* steps =
        List.fold_right
          (fun step acc ->
            let* acc = acc in
            match step with
            | `Assoc f -> (
                match List.assoc_opt "tag" f with
                | Some (`String t) when t <> "" -> Ok ((t, step) :: acc)
                | _ -> Error "bundle.json names a migration step without a tag")
            | _ -> Error "bundle.json's migrations is not a list of objects")
          l (Ok [])
      in
      let tags = List.map fst steps in
      if List.length (List.sort_uniq String.compare tags) <> List.length tags
      then Error "bundle.json names a migration tag twice"
      else Ok steps
  | Some _ -> Error "bundle.json's migrations is not a list"

let bundle_of_json (j : Yojson.Safe.t) : (bundle, string) result =
  let field name =
    match j with `Assoc f -> List.assoc_opt name f | _ -> None
  in
  let sub o name =
    match o with Some (`Assoc f) -> List.assoc_opt name f | _ -> None
  in
  let assets = field "assets" in
  let* durable_objects = durable_objects_of (field "durable_objects") in
  let* migrations = migrations_of (field "migrations") in
  match field "compatibility_date" with
  | Some (`String compatibility_date) ->
      let main_module =
        match field "main_module" with
        | Some (`String m) when m <> "" -> m
        | _ -> "index.js"
      in
      if String.contains main_module '/' || String.contains main_module ';' then
        Error ("bundle.json names the module " ^ main_module)
      else
        Ok
          {
            main_module;
            compatibility_date;
            compatibility_flags =
              (match field "compatibility_flags" with
              | Some (`List l) ->
                  List.filter_map (function `String s -> Some s | _ -> None) l
              | _ -> []);
            assets_binding =
              (match sub assets "binding" with
              | Some (`String b) -> b
              | _ -> "ASSETS");
            html_handling =
              (match sub assets "html_handling" with
              | Some (`String h) -> h
              | _ -> "none");
            run_worker_first =
              (match sub assets "run_worker_first" with
              | Some (`Bool b) -> b
              | _ -> true);
            durable_objects;
            migrations;
          }
  | _ -> Error "bundle.json names no compatibility_date"

(* Every file under [root], as (path from root with a leading slash, file). *)
let rec files root rel =
  let dir = if rel = "" then root else Filename.concat root rel in
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
      let r = if rel = "" then name else rel ^ "/" ^ name in
      let p = Filename.concat root r in
      if Sys.is_directory p then files root r else [ ("/" ^ r, p) ])

let extension path =
  match String.rindex_opt (Filename.basename path) '.' with
  | Some i ->
      let b = Filename.basename path in
      String.sub b (i + 1) (String.length b - i - 1)
  | None -> ""

let content_type path =
  match String.lowercase_ascii (extension path) with
  | "html" -> "text/html"
  | "js" | "mjs" -> "application/javascript"
  | "css" -> "text/css"
  | "json" | "map" -> "application/json"
  | "webmanifest" -> "application/manifest+json"
  | "svg" -> "image/svg+xml"
  | "png" -> "image/png"
  | "jpg" | "jpeg" -> "image/jpeg"
  | "ico" -> "image/x-icon"
  | "woff2" -> "font/woff2"
  | "woff" -> "font/woff"
  | "txt" -> "text/plain"
  | _ -> "application/octet-stream"

(* An asset's key in the upload session: 32 hex characters over its base64 and its extension, as
   wrangler forms one (wrangler hashes with BLAKE3; Cloudflare keys by the value and checks
   nothing about how it was made). *)
let asset_hash ~b64 ~path =
  String.sub (Crypto.sha256_hex (b64 ^ extension path)) 0 32

(* 1. Verify: the bundle's bytes against the manifest, unpacked into [dir]. *)
let verify env (m : Release.relay_manifest) ~dir =
  let* bytes =
    Result.map_error
      (fun e -> Retry ("download", "the bundle did not download: " ^ e))
      (env.fetch ~limit:m.bundle.bundle_size m.bundle.bundle_url)
  in
  let* () =
    if String.length bytes <> m.bundle.bundle_size then
      Error
        (Retry
           ( "download",
             Printf.sprintf "the bundle is %d bytes, the manifest says %d"
               (String.length bytes) m.bundle.bundle_size ))
    else if Keys.hash_of_bytes bytes <> m.bundle.bundle_sha256 then
      Error
        (Retry
           ( "download",
             "the bundle hashes to " ^ Keys.hash_of_bytes bytes
             ^ ", the manifest says " ^ m.bundle.bundle_sha256 ))
    else Ok ()
  in
  let archive = Filename.concat dir "bundle.tar.gz" in
  write archive bytes;
  let root = Filename.concat dir "bundle" in
  Unix.mkdir root 0o700;
  let refuse r = Result.map_error (fun e -> Refuse e) r in
  let* () = refuse (Digestif_update.Relay_bundle.unpack ~archive ~dir:root) in
  let* migrations =
    refuse (Digestif_update.Relay_bundle.migrations ~dir:root)
  in
  let* () =
    if migrations = m.migrations then Ok ()
    else
      Error
        (Refuse "the bundle's migrations are not the ones its manifest lists")
  in
  let* bundle =
    match Yojson.Safe.from_file (Filename.concat root "bundle.json") with
    | j -> refuse (bundle_of_json j)
    | exception (Yojson.Json_error e | Sys_error e) ->
        Error (Refuse ("the bundle's bundle.json: " ^ e))
  in
  let worker = Filename.concat root "worker" in
  let* () =
    if Sys.file_exists (Filename.concat worker bundle.main_module) then Ok ()
    else Error (Refuse ("the bundle holds no worker/" ^ bundle.main_module))
  in
  let app = Filename.concat root "app" in
  let* () =
    if Sys.file_exists app && Sys.is_directory app then Ok ()
    else Error (Refuse "the bundle holds no app/")
  in
  Ok (root, bundle)

(* The table wrangler keeps, made as wrangler makes it so either can apply next. *)
let migrations_table =
  "CREATE TABLE IF NOT EXISTS d1_migrations(id INTEGER PRIMARY KEY \
   AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT \
   CURRENT_TIMESTAMP NOT NULL);"

(* 2. Migrations: each the database lacks, with its row, in order. A name is
   NNNN_<lowercase words>.sql (Release.is_migration_name), so it is quoted as it stands. *)
let migrate env (r : Operate.record) ~token (m : Release.relay_manifest) ~root =
  let q sql =
    Cf.d1_query env.cloudflare ~token ~account_id:r.account_id
      ~database_id:r.database_id sql
  in
  let* _ = cf "migrations" (q migrations_table) in
  let* rows =
    cf "migrations" (q "SELECT name FROM d1_migrations ORDER BY id;")
  in
  let applied =
    List.concat_map
      (List.filter_map (function
        | `Assoc f -> (
            match List.assoc_opt "name" f with
            | Some (`String n) -> Some n
            | _ -> None)
        | _ -> None))
      rows
  in
  List.fold_left
    (fun acc (mg : Release.relay_migration) ->
      let* () = acc in
      if List.mem mg.migration applied then Ok ()
      else
        let sql =
          read
            (Filename.concat (Filename.concat root "migrations") mg.migration)
        in
        let* _ =
          cf
            ~rejected:("migration " ^ mg.migration ^ " failed")
            "migrations"
            (q
               (sql ^ "\nINSERT INTO d1_migrations (name) VALUES ('"
              ^ mg.migration ^ "');"))
        in
        Ok ())
    (Ok ()) m.migrations

let tag version = "relay-v" ^ Version.to_string version

(* 3a. The assets, through an upload session: the completion token the version carries. *)
let upload_assets env (r : Operate.record) ~token ~root ~scratch =
  let app = Filename.concat root "app" in
  let entries =
    List.map
      (fun (path, file) ->
        let b64 = base64 (read file) in
        (path, file, b64, asset_hash ~b64 ~path, (Unix.stat file).st_size))
      (files app "")
  in
  let* jwt, buckets =
    cf "upload"
      (Cf.assets_session env.cloudflare ~token ~account_id:r.account_id
         ~worker:r.worker
         (List.map (fun (p, _, _, h, size) -> (p, (h, size))) entries))
  in
  (* With no bucket the session's token is already the completion token; otherwise only a bucket's
     201 carries it, and every bucket before that is answered 202 with none. *)
  let* completion =
    List.fold_left
      (fun acc bucket ->
        let* completion = acc in
        let parts =
          List.filter_map
            (fun h ->
              List.find_map
                (fun (p, _, b64, h', _) ->
                  if h' <> h then None
                  else
                    let f = Filename.concat scratch h in
                    write f b64;
                    Some
                      { Cf.name = h; file = f; content_type = content_type p })
                entries)
            bucket
        in
        let* next =
          cf "upload"
            (Cf.assets_upload env.form ~jwt ~account_id:r.account_id parts)
        in
        Ok (match next with Some _ -> next | None -> completion))
      (Ok (if buckets = [] then Some jwt else None))
      buckets
  in
  match completion with
  | Some j -> Ok j
  | None ->
      cf "upload"
        (Error
           (Cf.Failed
              "Cloudflare took every bucket and named no completion token"))

(* The binding kinds every upload keeps from the version serving now: the deployment's vars,
   secrets and database are set once in the operator's account and never in a bundle. HOME_ROOT,
   the relay's home circle, is one of those vars: `digestif circle found --relay` writes it, and
   every release carries it forward from the version it replaces, since the metadata names no
   plain_text binding of its own. *)
let keep_bindings =
  [
    "plain_text";
    "secret_text";
    "json";
    "d1";
    "kv_namespace";
    "r2_bucket";
    "durable_object_namespace";
    "service";
    "queue";
    "analytics_engine";
    "version_metadata";
    "secret_key";
  ]

(* The upload's metadata: the module, its compatibility settings, the assets and Durable Object
   bindings the bundle names beside every kind the deployment keeps, tagged with this release and
   annotated with its bundle's sha256, and, for a script upload, the migrations the Worker lacks. *)
let metadata (m : Release.relay_manifest) (b : bundle) ~jwt ?migrations () =
  `Assoc
    ([
       ("main_module", `String b.main_module);
       ("compatibility_date", `String b.compatibility_date);
       ( "compatibility_flags",
         `List (List.map (fun f -> `String f) b.compatibility_flags) );
       ( "bindings",
         `List
           (`Assoc
              [ ("type", `String "assets"); ("name", `String b.assets_binding) ]
           :: List.map
                (fun (name, class_name) ->
                  `Assoc
                    [
                      ("type", `String "durable_object_namespace");
                      ("name", `String name);
                      ("class_name", `String class_name);
                    ])
                b.durable_objects) );
       ("keep_bindings", `List (List.map (fun k -> `String k) keep_bindings));
       ( "assets",
         `Assoc
           [
             ("jwt", `String jwt);
             ( "config",
               `Assoc
                 [
                   ("html_handling", `String b.html_handling);
                   ("run_worker_first", `Bool b.run_worker_first);
                 ] );
           ] );
       ( "annotations",
         `Assoc
           [
             ("workers/tag", `String (tag m.relay_version));
             ("workers/message", `String m.bundle.bundle_sha256);
           ] );
     ]
    @ match migrations with Some j -> [ ("migrations", j) ] | None -> [])

(* The multipart parts of an upload: the metadata, the module and its source map when the bundle
   has one. *)
let module_parts ~root (b : bundle) ~scratch metadata =
  let meta = Filename.concat scratch "metadata.json" in
  write meta (Yojson.Safe.to_string metadata);
  let module_ = Filename.concat (Filename.concat root "worker") b.main_module in
  let map = module_ ^ ".map" in
  [
    { Cf.name = "metadata"; file = meta; content_type = "application/json" };
    {
      name = b.main_module;
      file = module_;
      content_type = "application/javascript+module";
    };
  ]
  @
  if Sys.file_exists map then
    [
      {
        Cf.name = b.main_module ^ ".map";
        file = map;
        content_type = "application/source-map";
      };
    ]
  else []

(* The Durable Object migrations the Worker lacks, as the script upload's metadata names them: None
   when the bundle carries no step or the Worker has applied its newest tag, else every step after
   the tag the Worker has applied (all of them when it has applied none), each without its tag. A
   Worker on a tag the bundle does not carry refuses the release: no later pass meets other bytes. *)
let pending_migrations env (r : Operate.record) ~token (b : bundle) =
  match List.rev b.migrations with
  | [] -> Ok None
  | (newest, _) :: _ -> (
      let* applied =
        cf "upload"
          (Cf.migration_tag env.cloudflare ~token ~account_id:r.account_id
             ~worker:r.worker)
      in
      let rec after t = function
        | [] -> None
        | (t', _) :: rest -> if t' = t then Some rest else after t rest
      in
      let untagged = function
        | `Assoc f -> `Assoc (List.filter (fun (k, _) -> k <> "tag") f)
        | j -> j
      in
      match applied with
      | Some t when t = newest -> Ok None
      | Some t when after t b.migrations = None ->
          Error
            (Refuse
               ("the relay has applied the Durable Object migration " ^ t
              ^ ", which the bundle does not carry"))
      | _ ->
          let steps =
            match applied with
            | None -> b.migrations
            | Some t -> Option.get (after t b.migrations)
          in
          Ok
            (Some
               (`Assoc
                  ((match applied with
                     | Some t -> [ ("old_tag", `String t) ]
                     | None -> [])
                  @ [
                      ("new_tag", `String newest);
                      ( "steps",
                        `List (List.map (fun (_, s) -> untagged s) steps) );
                    ]))))

(* 3. Upload: the version tagged with this release and annotated with its bundle's sha256, reused
   when Cloudflare already holds one. *)
let upload env (r : Operate.record) ~token (m : Release.relay_manifest) ~root
    (b : bundle) ~scratch =
  let* existing =
    cf "upload"
      (Cf.versions env.cloudflare ~token ~account_id:r.account_id
         ~worker:r.worker)
  in
  match
    List.find_opt
      (fun (v : Cf.version) ->
        v.tag = Some (tag m.relay_version)
        && v.message = Some m.bundle.bundle_sha256)
      existing
  with
  | Some v -> Ok v.id
  | None ->
      let* jwt = upload_assets env r ~token ~root ~scratch in
      cf "upload"
        (Cf.upload_version env.form ~token ~account_id:r.account_id
           ~worker:r.worker
           (module_parts ~root b ~scratch (metadata m b ~jwt ())))

(* GET /app/ on the relay's base url answering 200: the phone app serves. *)
let app_serves env ~url =
  match
    env.relay ~meth:"GET"
      ~url:(Relay_client.relay_base url ^ "/app/")
      ~headers:[] ~body:None
  with
  | Ok { status = 200; _ } -> Ok ()
  | Ok { status; _ } -> Error (Printf.sprintf "/app/ answered %d" status)
  | Error e -> Error ("/app/ did not answer: " ^ e)

(* The new release's health check, read once: [Ok ()] when a signed GET /v0/circle at the home
   circle's address answers the version [want] and the circle's root, and the app serves; else what
   it answered. *)
let answers env (n : Node.t) ~url ~want =
  let* key = Node.device_key n in
  let* address = Operate.home_address n ~url in
  let* () =
    match Relay_client.circle env.relay ~base:address ~key with
    | Error e -> Error ("it did not answer: " ^ Relay_client.error_to_string e)
    | Ok j ->
        let field name =
          match j with
          | `Assoc f -> (
              match List.assoc_opt name f with
              | Some (`String s) -> Some s
              | _ -> None)
          | _ -> None
        in
        let got = field "relay_version" in
        if got <> Some want then
          Error ("it answered relay_version " ^ Option.value got ~default:"none")
        else if field "root" <> Node.root n then
          Error
            ("it answered the root "
            ^ Option.value (field "root") ~default:"none")
        else Ok ()
  in
  app_serves env ~url

(* The rollback's check, read once: [Ok ()] when the relay's GET /v0/version answers the version
   [want] it reported before (None: a Worker that reports none) and the app serves. The version
   read, not the home circle's, since the Worker rolled back to may be a release older than the
   circle routes at /c/<root hex> (docs/releases.md, Relay releases). *)
let answers_back env ~url ~want =
  let* () =
    match Relay_client.version env.relay ~base:url with
    | Error e -> Error ("it did not answer: " ^ Relay_client.error_to_string e)
    | Ok got when got <> want ->
        Error ("it answered relay_version " ^ Option.value got ~default:"none")
    | Ok _ -> Ok ()
  in
  app_serves env ~url

(* 5. The health check: [read] until it passes or two minutes of awake time have passed; [Error]
   is the last thing the relay answered. *)
let healthy env read =
  let rec go awake =
    match read () with
    | Ok () -> Ok ()
    | Error last when awake.Digestif_update.Awake.elapsed >= health_bound ->
        Error last
    | Error _ ->
        let before = env.wall () in
        env.sleep health_step;
        go
          (Digestif_update.Awake.step awake ~nominal:health_step
             ~wall_delta:(env.wall () -. before))
  in
  go Digestif_update.Awake.zero

let note ?(lead = false) text = { Operate.text; lead; told = false }

let rollback_line url =
  Printf.sprintf
    "npx wrangler rollback --env <environment> from relay/README.md \
     \"Operations\", logged in to the account %s runs in"
    (host url)

(* 5 and 6, once the release serves. Answers the record to save. *)
let check env (n : Node.t) (r : Operate.record) ~token
    (m : Release.relay_manifest) =
  let url = r.url and v = Version.to_string m.relay_version in
  let refuse why = { Operate.version = v; why } :: r.refused in
  match healthy env (fun () -> answers env n ~url ~want:v) with
  | Ok () ->
      Ok
        ( {
            r with
            reported_version = Some v;
            pending = None;
            notes =
              r.notes
              @ [
                  note (Printf.sprintf "Deployed relay %s to %s." v (host url));
                ];
          },
          Deployed { url; version = m.relay_version } )
  | Error answered -> (
      let previous = r.reported_version in
      let to_ =
        Option.value previous ~default:"the Worker it ran before relay releases"
      in
      let back =
        match
          Cf.deploy env.cloudflare ~token ~account_id:r.account_id
            ~worker:r.worker ~version_id:r.rollback_version_id
        with
        | Error e ->
            Error ("Cloudflare did not deploy it: " ^ Cf.error_to_string e)
        | Ok () -> healthy env (fun () -> answers_back env ~url ~want:previous)
      in
      let why = "it failed its health check: " ^ answered in
      match back with
      | Ok () ->
          Ok
            ( {
                r with
                pending = None;
                refused = refuse why;
                notes =
                  r.notes
                  @ [
                      note
                        (Printf.sprintf
                           "Relay %s failed its health check on %s (%s), so \
                            this node rolled the relay back to %s."
                           v (host url) answered to_);
                    ];
              },
              Rolled_back
                { url; version = m.relay_version; to_; why = answered } )
      | Error failed ->
          let text =
            Printf.sprintf
              "Relay %s failed its health check on %s (%s), and this node \
               could not roll it back to %s (%s). Roll it back by hand: %s."
              v (host url) answered to_ failed (rollback_line url)
          in
          Ok
            ( {
                r with
                pending = None;
                refused = refuse why;
                notes = r.notes @ [ note ~lead:true text ];
              },
              Rollback_failed
                {
                  url;
                  version = m.relay_version;
                  why = answered ^ "; " ^ failed;
                } ))

(* 4, from a verified bundle uploaded as [version_id], then 5 and 6. *)
let deploy_and_check env (n : Node.t) (r : Operate.record) ~token
    (m : Release.relay_manifest) ~version_id =
  let* serving =
    cf "deploy"
      (Cf.serving_version env.cloudflare ~token ~account_id:r.account_id
         ~worker:r.worker)
  in
  let* r =
    if serving = version_id then Ok r
    else
      let r = { r with rollback_version_id = serving } in
      Operate.save n.dir r;
      let* () =
        cf "deploy"
          (Cf.deploy env.cloudflare ~token ~account_id:r.account_id
             ~worker:r.worker ~version_id)
      in
      Ok r
  in
  check env n r ~token m

(* 3 and 4 as one step, for a bundle whose Durable Object [migrations] the Worker lacks: the version
   serving now recorded as the rollback target, then the module uploaded as the Worker script with
   them, which serves it at once; then 5 and 6. *)
let script_and_check env (n : Node.t) (r : Operate.record) ~token
    (m : Release.relay_manifest) ~root (b : bundle) ~scratch ~migrations =
  let* serving =
    cf "deploy"
      (Cf.serving_version env.cloudflare ~token ~account_id:r.account_id
         ~worker:r.worker)
  in
  let* jwt = upload_assets env r ~token ~root ~scratch in
  let r = { r with rollback_version_id = serving } in
  Operate.save n.dir r;
  let* () =
    cf "deploy"
      (Cf.upload_script env.form ~token ~account_id:r.account_id
         ~worker:r.worker
         (module_parts ~root b ~scratch (metadata m b ~jwt ~migrations ())))
  in
  check env n r ~token m

let with_scratch f =
  let dir = Filename.temp_dir "digestif-relay-deploy" "" in
  Fun.protect
    ~finally:(fun () ->
      try Digestif_update.Stage.remove_tree dir with _ -> ())
    (fun () -> f dir)

(* What the digest says of a deploy Cloudflare holds back for a cause that is not the token. It
   names no time, so a later try that meets the same cause makes the same line. *)
let held_line (r : Operate.record) v (e : Cf.error) =
  let why = Cf.error_to_string e in
  match e with
  | Cf.No_subdomain _ ->
      Printf.sprintf
        "Relay %s is not deployed to %s yet: Cloudflare account %s has no \
         workers.dev subdomain (%s). Open Workers and Pages in that account's \
         Cloudflare dashboard to create it; this node tries again on its own."
        v (host r.url) r.account_id why
  | _ ->
      Printf.sprintf
        "Relay %s is not deployed to %s yet (%s). This node tries again on its \
         own; digestif relay status shows when."
        v (host r.url) why

(* [step] failed and is tried again on the backoff. Of the notes an earlier try of [v] left, only
   the told ones stay: [line], when it is not one of them, is said next. *)
let pend (r : Operate.record) ~v ~step ~why ?line ~now () =
  let earlier =
    match r.pending with Some p when p.version = v -> Some p | _ -> None
  in
  let attempts =
    match earlier with Some p -> p.Operate.attempts + 1 | None -> 1
  in
  let told =
    match earlier with
    | Some p -> List.filter (fun (x : Operate.note) -> x.told) p.notes
    | None -> []
  in
  let notes =
    match line with
    | Some text
      when not (List.exists (fun (x : Operate.note) -> x.text = text) told) ->
        told @ [ note text ]
    | _ -> told
  in
  let retry_at = now +. Digestif_update.Updater.backoff attempts in
  ( {
      r with
      pending = Some { step; why; retry_at; version = v; attempts; notes };
    },
    Pending { url = r.url; why = step ^ ": " ^ why; retry_at } )

(* One deploy of [m] to the relay [r] describes, the token in hand. *)
let deploy env (n : Node.t) (r : Operate.record) ~token
    (m : Release.relay_manifest) ~now =
  let url = r.url and v = Version.to_string m.relay_version in
  let run () =
    with_scratch (fun dir ->
        let* root, bundle = verify env m ~dir in
        let* () = migrate env r ~token m ~root in
        let scratch = Filename.concat dir "upload" in
        Unix.mkdir scratch 0o700;
        let* migrations = pending_migrations env r ~token bundle in
        match migrations with
        | Some migrations ->
            script_and_check env n r ~token m ~root bundle ~scratch ~migrations
        | None ->
            let* version_id = upload env r ~token m ~root bundle ~scratch in
            deploy_and_check env n r ~token m ~version_id)
  in
  match run () with
  | Ok (r, outcome) -> (r, outcome)
  | Error (Token why) ->
      ( {
          r with
          pending = None;
          token_refused = true;
          notes =
            r.notes
            @ [
                note
                  (Printf.sprintf
                     "Cloudflare refused this node's deploy token for %s, so \
                      relay %s is not deployed (%s). Run digestif relay \
                      operate %s with a new token; no deploy is tried until \
                      then."
                     (host url) v why url);
              ];
        },
        Token_refused { url; why } )
  | Error (Refuse why) ->
      ( {
          r with
          pending = None;
          refused = { Operate.version = v; why } :: r.refused;
          notes =
            r.notes
            @ [
                note
                  (Printf.sprintf
                     "Relay %s was not deployed to %s and never will be by \
                      this node: %s. The relay still runs %s."
                     v (host url) why
                     (Option.value r.reported_version ~default:"what it ran"));
              ];
        },
        Refused { url; version = m.relay_version; why } )
  | Error (Held (step, e)) ->
      pend r ~v ~step ~why:(Cf.error_to_string e) ~line:(held_line r v e) ~now
        ()
  | Error (Retry (step, why)) -> pend r ~v ~step ~why ~now ()

let refused (r : Operate.record) v =
  List.exists
    (fun (x : Operate.refused) -> x.version = Version.to_string v)
    r.refused

let reported (r : Operate.record) =
  Option.bind r.reported_version (fun s ->
      Result.to_option (Version.of_string s))

(* What the relay reports now on its GET /v0/version (Relay_client.version); None when it did not
   answer. *)
let live env ~url = Result.to_option (Relay_client.version env.relay ~base:url)

(* A lead line stands until the relay answers a version this node knows: a counted relay release,
   or the one it ran before. *)
let clear_lead env (n : Node.t) (r : Operate.record)
    ~(releases : Digestif_update.Circle_relay_release.t) =
  if not (List.exists (fun (x : Operate.note) -> x.lead) r.notes) then r
  else
    match live env ~url:r.url with
    | Some (Some v)
      when List.exists
             (fun (c : Release.relay_manifest Release.signed) ->
               Version.to_string c.doc.relay_version = v)
             releases.counted
           || Some v = r.reported_version ->
        let r =
          {
            r with
            reported_version = Some v;
            notes = List.filter (fun (x : Operate.note) -> not x.lead) r.notes;
          }
        in
        Operate.save n.dir r;
        r
    | _ -> r

(* One pass, run by `digestif run` after each sync with the relay releases that sync folded. It
   answers what it did; a pass with nothing due answers nothing. *)
let pass ?(env = default_env) ?fold ~dir (n : Node.t)
    ~(releases : Digestif_update.Circle_relay_release.t) ~now : outcome list =
  let fold = match fold with Some f -> f | None -> Node.fold n in
  match Operate.standing n fold with
  | Error _ | Ok (Not_operator _ | Not_set_up) -> []
  | Ok (Operates r) -> (
      let r = clear_lead env n r ~releases in
      match releases.newest with
      | None -> []
      | Some { doc = m; _ } -> (
          let behind =
            match reported r with
            | Some v -> Version.compare m.relay_version v > 0
            | None -> true
          in
          let waiting =
            match r.pending with
            | Some p ->
                p.version = Version.to_string m.relay_version
                && now < p.retry_at
            | None -> false
          in
          if
            (not behind) || refused r m.relay_version || r.token_refused
            || waiting
            || Digestif_update.Trial.load dir <> None
          then []
          else
            match Operate.token n with
            | Error _ | Ok None -> []
            | Ok (Some token) -> (
                (* A relay already on this release, or a newer one, was deployed some other way
                   (by hand, or by a pass cut off after its deploy): record it and deploy nothing. *)
                match live env ~url:r.url with
                | Some (Some v)
                  when match Version.of_string v with
                       | Ok lv -> Version.compare lv m.relay_version >= 0
                       | Error _ -> false ->
                    Operate.save n.dir
                      { r with reported_version = Some v; pending = None };
                    []
                | _ ->
                    let r, outcome = deploy env n r ~token m ~now in
                    Operate.save n.dir r;
                    [ outcome ])))

let lines_of (n : Node.t) ~lead =
  match Operate.load n.dir with
  | Ok (Some r) ->
      let pending (r : Operate.record) =
        match r.pending with Some p -> p.notes | None -> []
      in
      List.filter_map
        (fun (x : Operate.note) ->
          if x.lead <> lead || ((not lead) && x.told) then None
          else
            Some
              {
                Line.text = x.text;
                tell =
                  (fun () ->
                    (* Re-read, so a tell never writes back a record a pass has moved since. *)
                    match Operate.load n.dir with
                    | Ok (Some r) ->
                        Operate.save n.dir
                          {
                            r with
                            notes =
                              List.filter_map
                                (fun (y : Operate.note) ->
                                  if y.text <> x.text then Some y
                                  else if y.lead then
                                    Some { y with told = true }
                                  else None)
                                r.notes;
                            pending =
                              Option.map
                                (fun (p : Operate.pending) ->
                                  {
                                    p with
                                    notes =
                                      List.map
                                        (fun (y : Operate.note) ->
                                          if y.text = x.text then
                                            { y with told = true }
                                          else y)
                                        p.notes;
                                  })
                                r.pending;
                          }
                    | _ -> ());
              })
        (r.notes @ pending r)
  | _ -> []

(* A rollback that failed: the digest's lead lines, carried on every digest until the relay
   answers a version this node knows. *)
let lead_lines (n : Node.t) ~now:(_ : float) : Line.t list =
  lines_of n ~lead:true

(* The digest's deploy lines: what this node deployed, why it rolled back, refused a release,
   waits for a new token or is held back by Cloudflare, each once. *)
let digest_lines (n : Node.t) ~now:(_ : float) : Line.t list =
  lines_of n ~lead:false
