(* The deploy pass (docs/releases.md, The deploy step), against a fake Cloudflare account, a fake
   relay and a clock that moves only when the pass sleeps: verify, migrations, upload, deploy,
   health check, kept or rolled back, pending, a refused token, and the digest lines. *)

open Digestif_core
module O = Digestif_relay_deploy.Operate
module D = Digestif_relay_deploy.Deploy
module Cf = Digestif_relay_deploy.Cloudflare
module Version = Digestif_update.Version
module Release = Digestif_update.Release

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let contains s sub =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  go 0

let tmpdir () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "digestif-deploy-test-%d-%s" (Unix.getpid ())
       (B64url.encode (Crypto.random 6)))

let url = "https://dinners.test"
let token = "cf-token-SECRET-123"

let write path s =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc s)

(* A node operating [url]: it wrote the relay's relay message and holds a token and a record. *)
let operator_node () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  let d = ok (Node.init n ~phrase:(Phrase.generate ())) in
  let dinner =
    Bodies.dinner_json
      {
        host = Keys.public d.identity;
        date = "2026-11-04";
        label = "Relay dinner";
        guests = [];
        relays = [ url ];
      }
  in
  let root, _ = ok (Node.write n ~kind:"dinner" dinner) in
  Node.set_root n root;
  ignore
    (ok (Node.write n ~kind:"relay" (Bodies.make_relay ~url ~mailer:true ())));
  ok (n.keystore.put O.token_name token);
  O.save n.dir
    {
      O.url;
      account_id = "acct";
      worker = "digestif-relay";
      database_id = "db-1";
      rollback_version_id = "ver-now";
      reported_version = Some "0.1.0";
      pending = None;
      refused = [];
      told_not_operator = false;
      token_refused = false;
      notes = [];
    };
  n

let plain_bundle_json =
  {|{"main_module":"index.js","compatibility_date":"2026-08-01","compatibility_flags":["nodejs_compat"]}|}

(* bundle.json of a release carrying the store class (relay/scripts/bundle-json.ts). *)
let store_bundle_json =
  {|{"main_module":"index.js","compatibility_date":"2026-08-01","compatibility_flags":["nodejs_compat"],"durable_objects":[{"name":"CIRCLE_STORE","class_name":"CircleStore"}],"migrations":[{"tag":"v1","new_sqlite_classes":["CircleStore"]}]}|}

(* A bundle for [version] with two migrations, and its manifest. *)
let bundle ?(bundle_json = plain_bundle_json) version =
  let dir = tmpdir () in
  let root = Filename.concat dir "b" in
  List.iter
    (fun d -> Unix.mkdir d 0o700)
    [
      dir;
      root;
      Filename.concat root "worker";
      Filename.concat root "app";
      Filename.concat root "app/assets";
      Filename.concat root "migrations";
    ];
  write (Filename.concat root "worker/index.js") "export default {}";
  write (Filename.concat root "worker/index.js.map") "{}";
  write (Filename.concat root "app/index.html") "<html></html>";
  write (Filename.concat root "app/assets/app.js") "console.log(1)";
  write (Filename.concat root "migrations/0001_init.sql") "CREATE TABLE a(x);";
  write (Filename.concat root "migrations/0002_more.sql") "CREATE TABLE b(y);";
  write (Filename.concat root "bundle.json") bundle_json;
  let archive = Filename.concat dir ("digestif-relay-" ^ version ^ ".tar.gz") in
  (match Proc.run [| "tar"; "-czf"; archive; "-C"; root; "." |] with
  | Ok { code = 0; _ } -> ()
  | _ -> Alcotest.fail "tar");
  let m =
    ok
      (Digestif_update.Relay_bundle.manifest ~version ~notes:"n"
         ~url_base:"https://releases.test/" ~compatible_with:"0.1.0"
         ~published_at:"2026-11-04T00:00:00.000Z" ~archive)
  in
  (m, In_channel.with_open_bin archive In_channel.input_all)

let releases (m : Release.relay_manifest) :
    Digestif_update.Circle_relay_release.t =
  let r = { Release.bytes = ""; doc = m; signatures = [] } in
  { counted = [ r ]; newest = Some r; faults = [] }

(* A fake account and relay. [served] maps a Worker version id to the relay_version it answers
   (None: it answers 503). *)
type world = {
  mutable applied : string list;
  mutable versions : (string * string * string) list;  (** id, tag, message *)
  mutable serving : string;
  mutable deployed : string list;
  mutable uploads : int;
  mutable metadata : Yojson.Safe.t option;
  mutable served : (string * string option) list;
  mutable fail : string option;  (** a path prefix answering [fail_status] *)
  mutable fail_status : int;
  mutable fail_migration : bool;
  mutable one_file_buckets : bool;
      (** the assets session puts each file in a bucket of its own *)
  mutable buckets : int;  (** buckets the assets session named *)
  mutable bucket_uploads : int;  (** asset uploads Cloudflare took *)
  mutable clock : float;
  mutable sleeps : int;
  mutable migration_tag : string option;
      (** the newest Durable Object migration the Worker has applied *)
  mutable scripts : int;  (** script uploads Cloudflare took *)
  mutable rollback_refused : bool;
      (** Cloudflare refuses a deployment of a version older than a migration *)
  mutable circle_reads : string list;
      (** the url of every GET /v0/circle the pass sent, newest first *)
}

let world () =
  {
    applied = [ "0001_init.sql" ];
    versions = [];
    serving = "ver-now";
    deployed = [];
    uploads = 0;
    metadata = None;
    served = [ ("ver-now", Some "0.1.0"); ("ver-new", Some "0.2.0") ];
    fail = None;
    fail_status = 503;
    fail_migration = false;
    one_file_buckets = false;
    buckets = 0;
    bucket_uploads = 0;
    clock = 1000.;
    sleeps = 0;
    migration_tag = None;
    scripts = 0;
    rollback_refused = false;
    circle_reads = [];
  }

let answer result =
  Ok
    {
      Relay_client.status = 200;
      body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("success", `Bool true); ("errors", `List []); ("result", result);
             ]);
    }

let refuse status =
  Ok
    {
      Relay_client.status;
      body = {|{"success":false,"errors":[{"code":7500,"message":"no"}]}|};
    }

let starts_with ~prefix s = String.starts_with ~prefix s

let cloudflare w : Cf.transport =
 fun ~meth ~path ~token:t ~body ->
  if t <> token then refuse 401
  else
    match w.fail with
    | Some p when starts_with ~prefix:p path -> refuse w.fail_status
    | _ -> (
        let script = "/accounts/acct/workers/scripts/digestif-relay" in
        match (meth, path) with
        | "POST", "/accounts/acct/d1/database/db-1/query" ->
            let sql =
              match Yojson.Safe.from_string (Option.get body) with
              | `Assoc f -> (
                  match List.assoc_opt "sql" f with
                  | Some (`String s) -> s
                  | _ -> "")
              | _ -> ""
            in
            let ok_rows rows =
              answer
                (`List
                   [
                     `Assoc [ ("success", `Bool true); ("results", `List rows) ];
                   ])
            in
            if
              starts_with ~prefix:"CREATE TABLE IF NOT EXISTS d1_migrations" sql
            then ok_rows []
            else if starts_with ~prefix:"SELECT name FROM d1_migrations" sql
            then
              ok_rows
                (List.map (fun n -> `Assoc [ ("name", `String n) ]) w.applied)
            else if w.fail_migration then refuse 400
            else (
              (match String.index_opt sql '\'' with
              | Some i ->
                  let j = String.index_from sql (i + 1) '\'' in
                  w.applied <-
                    w.applied @ [ String.sub sql (i + 1) (j - i - 1) ]
              | None -> ());
              ok_rows [])
        | "GET", "/accounts/acct/workers/scripts" ->
            answer
              (`List
                 [
                   `Assoc
                     (("id", `String "digestif-relay")
                     ::
                     (match w.migration_tag with
                     | Some t -> [ ("migration_tag", `String t) ]
                     | None -> []));
                   `Assoc [ ("id", `String "another-worker") ];
                 ])
        | "POST", p when p = script ^ "/deployments" && w.rollback_refused ->
            refuse 400
        | "GET", p when p = script ^ "/versions" ->
            answer
              (`Assoc
                 [
                   ( "items",
                     `List
                       (List.map
                          (fun (id, tag, msg) ->
                            `Assoc
                              [
                                ("id", `String id);
                                ( "annotations",
                                  `Assoc
                                    [
                                      ("workers/tag", `String tag);
                                      ("workers/message", `String msg);
                                    ] );
                              ])
                          w.versions) );
                 ])
        | "POST", p when p = script ^ "/assets-upload-session" ->
            let hashes =
              match Yojson.Safe.from_string (Option.get body) with
              | `Assoc [ ("manifest", `Assoc entries) ] ->
                  List.filter_map
                    (fun (_, e) ->
                      match e with
                      | `Assoc f -> (
                          match List.assoc_opt "hash" f with
                          | Some (`String h) -> Some (`String h)
                          | _ -> None)
                      | _ -> None)
                    entries
              | _ -> []
            in
            let buckets =
              if w.one_file_buckets then List.map (fun h -> `List [ h ]) hashes
              else [ `List hashes ]
            in
            w.buckets <- List.length buckets;
            answer
              (`Assoc
                 [ ("jwt", `String "upload-jwt"); ("buckets", `List buckets) ])
        | "GET", p when p = script ^ "/deployments" ->
            answer
              (`Assoc
                 [
                   ( "deployments",
                     `List
                       [
                         `Assoc
                           [
                             ("created_on", `String "2026-11-01T00:00:00Z");
                             ( "versions",
                               `List
                                 [
                                   `Assoc
                                     [
                                       ("version_id", `String w.serving);
                                       ("percentage", `Int 100);
                                     ];
                                 ] );
                           ];
                       ] );
                 ])
        | "POST", p when p = script ^ "/deployments" ->
            let id =
              match Yojson.Safe.from_string (Option.get body) with
              | `Assoc f -> (
                  match List.assoc_opt "versions" f with
                  | Some (`List [ `Assoc v ]) -> (
                      match List.assoc_opt "version_id" v with
                      | Some (`String id) -> id
                      | _ -> "")
                  | _ -> "")
              | _ -> ""
            in
            w.serving <- id;
            w.deployed <- w.deployed @ [ id ];
            answer (`Assoc [ ("id", `String "dep") ])
        | _ -> Ok { Relay_client.status = 404; body = "{}" })

let annotation j k =
  match j with
  | `Assoc f -> (
      match List.assoc_opt "annotations" f with
      | Some (`Assoc a) -> (
          match List.assoc_opt k a with Some (`String s) -> s | _ -> "")
      | _ -> "")
  | _ -> ""

let form w : Cf.form_transport =
 fun ~meth ~path ~token:t ~parts ->
  match w.fail with
  | Some p when starts_with ~prefix:p path -> refuse w.fail_status
  | _ ->
      if path = "/accounts/acct/workers/assets/upload?base64=true" then
        if t <> "upload-jwt" then refuse 401
        else (
          List.iter
            (fun (p : Cf.part) ->
              let b64 = In_channel.with_open_bin p.file In_channel.input_all in
              if String.length b64 mod 4 <> 0 then
                Alcotest.fail "unpadded base64")
            parts;
          w.bucket_uploads <- w.bucket_uploads + 1;
          (* Cloudflare's answer: 202 and an empty body for every bucket but the last. *)
          if w.bucket_uploads < w.buckets then
            Ok { Relay_client.status = 202; body = "" }
          else
            Ok
              {
                Relay_client.status = 201;
                body = {|{"success":true,"result":{"jwt":"done-jwt"}}|};
              })
      else if path = "/accounts/acct/workers/scripts/digestif-relay/versions"
      then (
        if t <> token then refuse 401
        else
          let meta =
            List.find (fun (p : Cf.part) -> p.name = "metadata") parts
          in
          let j = Yojson.Safe.from_file meta.file in
          w.metadata <- Some j;
          w.uploads <- w.uploads + 1;
          w.versions <-
            ( "ver-new",
              annotation j "workers/tag",
              annotation j "workers/message" )
            :: w.versions;
          answer (`Assoc [ ("id", `String "ver-new") ]))
      else if
        meth = "PUT" && path = "/accounts/acct/workers/scripts/digestif-relay"
      then (
        if t <> token then refuse 401
        else
          let meta =
            List.find (fun (p : Cf.part) -> p.name = "metadata") parts
          in
          let j = Yojson.Safe.from_file meta.file in
          w.metadata <- Some j;
          w.scripts <- w.scripts + 1;
          (match j with
          | `Assoc f -> (
              match List.assoc_opt "migrations" f with
              | Some (`Assoc g) -> (
                  match List.assoc_opt "new_tag" g with
                  | Some (`String tag) -> w.migration_tag <- Some tag
                  | _ -> ())
              | _ -> ())
          | _ -> ());
          w.versions <-
            ( "ver-new",
              annotation j "workers/tag",
              annotation j "workers/message" )
            :: w.versions;
          (* A script upload serves its version at once. *)
          w.serving <- "ver-new";
          answer (`Assoc [ ("id", `String "digestif-relay") ]))
      else Ok { Relay_client.status = 404; body = "{}" }

(* The home circle's address on the fake relay: <url>/c/<root hex>. *)
let address (n : Node.t) =
  let root = Option.get (Node.root n) in
  url ^ "/c/"
  ^ String.sub root
      (String.length Keys.sha256_prefix)
      (String.length root - String.length Keys.sha256_prefix)

(* The fake relay serves the home circle at its address only: an unprefixed GET /v0/circle has no
   route, as on a relay that dropped the unprefixed routes (DES-271). *)
let relay w (n : Node.t) : Relay_client.transport =
 fun ~meth:_ ~url:u ~headers:_ ~body:_ ->
  if String.ends_with ~suffix:"/v0/circle" u then
    w.circle_reads <- u :: w.circle_reads;
  if u = url ^ "/app/" then Ok { Relay_client.status = 200; body = "<html>" }
  else if u = address n ^ "/v0/circle" then
    match List.assoc_opt w.serving w.served with
    | Some (Some v) ->
        Ok
          {
            Relay_client.status = 200;
            body =
              Yojson.Safe.to_string
                (`Assoc
                   [
                     ("root", `String (Option.get (Node.root n)));
                     ("relay_version", `String v);
                   ]);
          }
    | _ -> Ok { Relay_client.status = 503; body = "{}" }
  else Error ("no route to " ^ u)

let env w n bytes : D.env =
  {
    cloudflare = cloudflare w;
    form = form w;
    relay = relay w n;
    fetch =
      (fun ~limit:_ u ->
        if u = "https://releases.test/digestif-relay-0.2.0.tar.gz" then Ok bytes
        else Error ("404 " ^ u));
    sleep =
      (fun d ->
        w.sleeps <- w.sleeps + 1;
        w.clock <- w.clock +. d);
    wall = (fun () -> w.clock);
  }

let record n = Option.get (ok (O.load n.Node.dir))

let pass ?(now = 1000.) w n bytes m =
  D.pass ~env:(env w n bytes) ~dir:n.Node.dir n ~releases:(releases m) ~now

let texts lines =
  List.map (fun (l : Digestif_relay_deploy.Line.t) -> l.text) lines

let deploys_and_says_so_once () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  (match pass w n bytes m with
  | [ D.Deployed { version; _ } ] ->
      Alcotest.(check string) "deployed" "0.2.0" (Version.to_string version)
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check (list string))
    "applied only the migration the database lacked"
    [ "0001_init.sql"; "0002_more.sql" ]
    w.applied;
  Alcotest.(check (list string))
    "deployed the new version" [ "ver-new" ] w.deployed;
  let meta = Option.get w.metadata in
  let field k = match meta with `Assoc f -> List.assoc_opt k f | _ -> None in
  Alcotest.(check bool)
    "keeps the deployment's bindings" true
    (match field "keep_bindings" with
    | Some (`List l) ->
        List.mem (`String "secret_text") l && List.mem (`String "d1") l
    | _ -> false);
  Alcotest.(check bool)
    "carries HOME_ROOT forward: keeps every var and names none of its own" true
    ((match field "keep_bindings" with
       | Some (`List l) -> List.mem (`String "plain_text") l
       | _ -> false)
    &&
    match field "bindings" with
    | Some (`List bs) ->
        List.for_all
          (function
            | `Assoc b -> List.assoc_opt "type" b <> Some (`String "plain_text")
            | _ -> true)
          bs
    | _ -> false);
  Alcotest.(check bool)
    "carries the assets' completion token" true
    (match field "assets" with
    | Some (`Assoc a) -> List.assoc_opt "jwt" a = Some (`String "done-jwt")
    | _ -> false);
  Alcotest.(check bool)
    "tagged with the release" true
    (List.exists
       (fun (_, t, s) -> t = "relay-v0.2.0" && s = m.bundle.bundle_sha256)
       w.versions);
  let r = record n in
  Alcotest.(check (option string))
    "records the version" (Some "0.2.0") r.reported_version;
  Alcotest.(check string)
    "the rollback target is what served" "ver-now" r.rollback_version_id;
  Alcotest.(check bool)
    "the record holds no token" false
    (contains
       (In_channel.with_open_bin (O.record_path n.dir) In_channel.input_all)
       token);
  let lines = D.digest_lines n ~now:0. in
  Alcotest.(check (list string))
    "the digest says it"
    [ "Deployed relay 0.2.0 to dinners.test." ]
    (texts lines);
  List.iter (fun (l : Digestif_relay_deploy.Line.t) -> l.tell ()) lines;
  Alcotest.(check int) "once" 0 (List.length (D.digest_lines n ~now:0.));
  Alcotest.(check int) "nothing more is due" 0 (List.length (pass w n bytes m))

(* A pass cut off after its upload and deploy finds the tagged version serving, uploads nothing,
   deploys nothing, and checks the relay. *)
let uploads_assets_in_several_buckets () =
  let n = operator_node () and w = world () in
  w.one_file_buckets <- true;
  let m, bytes = bundle "0.2.0" in
  (match pass w n bytes m with
  | [ D.Deployed { version; _ } ] ->
      Alcotest.(check string) "deployed" "0.2.0" (Version.to_string version)
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check int) "two buckets" 2 w.buckets;
  Alcotest.(check int) "uploaded both" 2 w.bucket_uploads;
  Alcotest.(check bool)
    "carries the last bucket's completion token" true
    (match Option.get w.metadata with
    | `Assoc f -> (
        match List.assoc_opt "assets" f with
        | Some (`Assoc a) -> List.assoc_opt "jwt" a = Some (`String "done-jwt")
        | _ -> false)
    | _ -> false)

let resumes_where_the_relay_is () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.versions <- [ ("ver-new", "relay-v0.2.0", m.bundle.bundle_sha256) ];
  w.serving <- "ver-new";
  w.served <- [ ("ver-new", Some "0.1.0") ];
  (* The relay still answers the old version at first: a slow edge. *)
  let calls = ref 0 in
  let e = env w n bytes in
  let e =
    {
      e with
      relay =
        (fun ~meth ~url:u ~headers ~body ->
          incr calls;
          if !calls > 3 then w.served <- [ ("ver-new", Some "0.2.0") ];
          relay w n ~meth ~url:u ~headers ~body);
    }
  in
  (match D.pass ~env:e ~dir:n.dir n ~releases:(releases m) ~now:1000. with
  | [ D.Deployed _ ] -> ()
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check int) "uploaded nothing" 0 w.uploads;
  Alcotest.(check (list string)) "deployed nothing" [] w.deployed;
  Alcotest.(check bool) "waited for the relay" true (w.sleeps > 0)

let rolls_back_a_failed_health_check () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.served <- [ ("ver-now", Some "0.1.0"); ("ver-new", None) ];
  (match pass w n bytes m with
  | [ D.Rolled_back { to_; _ } ] -> Alcotest.(check string) "to" "0.1.0" to_
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check (list string))
    "deployed, then deployed the old version back" [ "ver-new"; "ver-now" ]
    w.deployed;
  Alcotest.(check bool) "waited two minutes of awake time" true (w.sleeps >= 120);
  let r = record n in
  Alcotest.(check (list string))
    "refused on this relay" [ "0.2.0" ]
    (List.map (fun (x : O.refused) -> x.version) r.refused);
  (match texts (D.digest_lines n ~now:0.) with
  | [ t ] ->
      Alcotest.(check bool)
        t true
        (contains t "Relay 0.2.0 failed its health check on dinners.test"
        && contains t "rolled the relay back to 0.1.0")
  | l -> Alcotest.failf "lines: %s" (String.concat " | " l));
  Alcotest.(check int) "never tried again" 0 (List.length (pass w n bytes m))

let a_failed_rollback_leads_until_the_relay_answers () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.served <- [ ("ver-now", None); ("ver-new", None) ];
  (match pass w n bytes m with
  | [ D.Rollback_failed _ ] -> ()
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  let lead = D.lead_lines n ~now:0. in
  Alcotest.(check int) "a lead line" 1 (List.length lead);
  Alcotest.(check bool)
    "names the rollback to run" true
    (contains (List.hd (texts lead)) "npx wrangler rollback");
  List.iter (fun (l : Digestif_relay_deploy.Line.t) -> l.tell ()) lead;
  Alcotest.(check int) "carried again" 1 (List.length (D.lead_lines n ~now:0.));
  Alcotest.(check int)
    "and not among the once lines" 0
    (List.length (D.digest_lines n ~now:0.));
  (* The operator rolls back by hand: the relay answers 0.1.0 again. *)
  w.served <- [ ("ver-now", Some "0.1.0") ];
  w.serving <- "ver-now";
  ignore (pass w n bytes m);
  Alcotest.(check int) "cleared" 0 (List.length (D.lead_lines n ~now:0.))

let a_failure_before_the_deploy_is_pending () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.fail <-
    Some "/accounts/acct/workers/scripts/digestif-relay/assets-upload-session";
  (match pass ~now:1000. w n bytes m with
  | [ D.Pending { retry_at; _ } ] ->
      Alcotest.(check (float 0.1)) "ten minutes" 1600. retry_at
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check (list string)) "deployed nothing" [] w.deployed;
  Alcotest.(check int)
    "waits for its retry" 0
    (List.length (pass ~now:1500. w n bytes m));
  (match pass ~now:1700. w n bytes m with
  | [ D.Pending { retry_at; _ } ] ->
      Alcotest.(check (float 0.1)) "doubled" 2900. retry_at
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check int) "two attempts" 2 (Option.get (record n).pending).attempts;
  Alcotest.(check int)
    "no digest line for a retry" 0
    (List.length (D.digest_lines n ~now:0.));
  w.fail <- None;
  (match pass ~now:3000. w n bytes m with
  | [ D.Deployed _ ] -> ()
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check bool) "pending cleared" true ((record n).pending = None)

let a_bundle_that_does_not_match_is_pending () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  (match pass w n (bytes ^ "x") m with
  | [ D.Pending { why; _ } ] ->
      Alcotest.(check bool) why true (contains why "bytes")
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check (list string)) "applied nothing" [ "0001_init.sql" ] w.applied

let a_refused_token_waits_for_a_new_one () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.fail <- Some "/accounts/acct/d1";
  w.fail_status <- 403;
  (match pass w n bytes m with
  | [ D.Token_refused _ ] -> ()
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  w.fail <- None;
  Alcotest.(check int) "not retried" 0 (List.length (pass ~now:1e9 w n bytes m));
  match texts (D.digest_lines n ~now:0.) with
  | [ t ] -> Alcotest.(check bool) t true (contains t "digestif relay operate")
  | l -> Alcotest.failf "lines: %s" (String.concat " | " l)

let a_failed_migration_is_refused_for_good () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  w.fail_migration <- true;
  (match pass w n bytes m with
  | [ D.Refused { why; _ } ] ->
      Alcotest.(check bool) why true (contains why "0002_more.sql")
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check int) "uploaded nothing" 0 w.uploads;
  Alcotest.(check (list string)) "deployed nothing" [] w.deployed;
  w.fail_migration <- false;
  Alcotest.(check int)
    "never tried again" 0
    (List.length (pass ~now:1e9 w n bytes m))

let not_due () =
  let m, bytes = bundle "0.2.0" in
  (* On trial. *)
  let n = operator_node () and w = world () in
  Digestif_update.Trial.save n.dir
    {
      release = "r";
      version = ok (Version.of_string "9.9.9");
      previous = "p";
      starts = 0;
    };
  Alcotest.(check int)
    "not while a switch is on trial" 0
    (List.length (pass w n bytes m));
  Alcotest.(check (list string)) "trial: nothing deployed" [] w.deployed;
  (* The relay already reports the release: deployed by hand. *)
  let n = operator_node () and w = world () in
  w.served <- [ ("ver-now", Some "0.2.0") ];
  Alcotest.(check int)
    "not for a relay already on it" 0
    (List.length (pass w n bytes m));
  Alcotest.(check (option string))
    "records it" (Some "0.2.0") (record n).reported_version;
  (* No newer release. *)
  let n = operator_node () and w = world () in
  let old, _ = bundle "0.1.0" in
  Alcotest.(check int)
    "not for the version it runs" 0
    (List.length (pass w n bytes old));
  (* No token: not an operator. *)
  let n = operator_node () and w = world () in
  ok (n.keystore.delete O.token_name);
  Alcotest.(check int) "not without a token" 0 (List.length (pass w n bytes m));
  Alcotest.(check (list string)) "nothing deployed" [] w.deployed

let field j k = match j with `Assoc f -> List.assoc_opt k f | _ -> None

let store_binding =
  `Assoc
    [
      ("type", `String "durable_object_namespace");
      ("name", `String "CIRCLE_STORE");
      ("class_name", `String "CircleStore");
    ]

let fail_outcomes os =
  Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os))

(* A release whose migration tag the Worker has not applied is uploaded as the Worker script, with
   the migration and the class's binding, and serves without a separate deployment. *)
let uploads_the_script_for_a_new_migration_tag () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle ~bundle_json:store_bundle_json "0.2.0" in
  (match pass w n bytes m with
  | [ D.Deployed { version; _ } ] ->
      Alcotest.(check string) "deployed" "0.2.0" (Version.to_string version)
  | os -> fail_outcomes os);
  Alcotest.(check int) "one script upload" 1 w.scripts;
  Alcotest.(check int) "no version upload" 0 w.uploads;
  Alcotest.(check (list string)) "no separate deployment" [] w.deployed;
  Alcotest.(check (option string)) "the tag applied" (Some "v1") w.migration_tag;
  let meta = Option.get w.metadata in
  Alcotest.(check string)
    "the migrations the Worker lacks, each step without its tag"
    {|{"new_tag":"v1","steps":[{"new_sqlite_classes":["CircleStore"]}]}|}
    (Yojson.Safe.to_string (Option.get (field meta "migrations")));
  Alcotest.(check bool)
    "binds the class" true
    (match field meta "bindings" with
    | Some (`List l) -> List.mem store_binding l
    | _ -> false);
  Alcotest.(check string)
    "tagged with the release" "relay-v0.2.0"
    (annotation meta "workers/tag");
  let r = record n in
  Alcotest.(check string)
    "the rollback target is what served" "ver-now" r.rollback_version_id;
  Alcotest.(check (option string))
    "records the version" (Some "0.2.0") r.reported_version

(* Once the Worker has applied the bundle's newest tag, a release is a version upload as any other,
   still binding the class. *)
let uploads_a_version_once_the_tag_is_applied () =
  let n = operator_node () and w = world () in
  w.migration_tag <- Some "v1";
  let m, bytes = bundle ~bundle_json:store_bundle_json "0.2.0" in
  (match pass w n bytes m with
  | [ D.Deployed _ ] -> ()
  | os -> fail_outcomes os);
  Alcotest.(check int) "no script upload" 0 w.scripts;
  Alcotest.(check int) "a version upload" 1 w.uploads;
  Alcotest.(check (list string)) "deployed it" [ "ver-new" ] w.deployed;
  let meta = Option.get w.metadata in
  Alcotest.(check bool) "no migrations" true (field meta "migrations" = None);
  Alcotest.(check bool)
    "binds the class" true
    (match field meta "bindings" with
    | Some (`List l) -> List.mem store_binding l
    | _ -> false)

let refuses_a_tag_the_bundle_does_not_carry () =
  let n = operator_node () and w = world () in
  w.migration_tag <- Some "v9";
  let m, bytes = bundle ~bundle_json:store_bundle_json "0.2.0" in
  (match pass w n bytes m with
  | [ D.Refused { why; _ } ] ->
      Alcotest.(check bool) why true (contains why "v9")
  | os -> fail_outcomes os);
  Alcotest.(check int) "no upload" 0 (w.scripts + w.uploads);
  Alcotest.(check (list string)) "deployed nothing" [] w.deployed

(* A script upload that fails its health check is rolled back as any release; Cloudflare refusing
   to deploy a version older than the migration leads the digest with the rollback to run. *)
let a_failed_script_upload_is_rolled_back_or_says_why_not () =
  let n = operator_node () and w = world () in
  w.served <- [ ("ver-now", Some "0.1.0"); ("ver-new", None) ];
  let m, bytes = bundle ~bundle_json:store_bundle_json "0.2.0" in
  (match pass w n bytes m with
  | [ D.Rolled_back { to_; _ } ] -> Alcotest.(check string) "to" "0.1.0" to_
  | os -> fail_outcomes os);
  Alcotest.(check (list string))
    "deployed the old version back" [ "ver-now" ] w.deployed;
  let n = operator_node () and w = world () in
  w.served <- [ ("ver-now", Some "0.1.0"); ("ver-new", None) ];
  w.rollback_refused <- true;
  (match pass w n bytes m with
  | [ D.Rollback_failed { why; _ } ] ->
      Alcotest.(check bool)
        why true
        (contains why "Cloudflare did not deploy it")
  | os -> fail_outcomes os);
  Alcotest.(check int) "a lead line" 1 (List.length (D.lead_lines n ~now:0.))

let refuses_a_malformed_store_bundle () =
  List.iter
    (fun (name, j) ->
      match D.bundle_of_json (Yojson.Safe.from_string j) with
      | Ok _ -> Alcotest.failf "%s: read" name
      | Error _ -> ())
    [
      ( "a binding without its class",
        {|{"compatibility_date":"2026-08-01","durable_objects":[{"name":"CIRCLE_STORE"}]}|}
      );
      ( "a step without a tag",
        {|{"compatibility_date":"2026-08-01","migrations":[{"new_sqlite_classes":["A"]}]}|}
      );
      ( "a tag twice",
        {|{"compatibility_date":"2026-08-01","migrations":[{"tag":"v1"},{"tag":"v1"}]}|}
      );
    ];
  match D.bundle_of_json (Yojson.Safe.from_string store_bundle_json) with
  | Ok b ->
      Alcotest.(check (list (pair string string)))
        "the binding"
        [ ("CIRCLE_STORE", "CircleStore") ]
        b.durable_objects;
      Alcotest.(check (list string))
        "the tags" [ "v1" ]
        (List.map fst b.migrations)
  | Error e -> Alcotest.fail e

(* Every health check read goes to the home circle's address, <url>/c/<root hex>, never the
   unprefixed routes a relay counts as last_unprefixed_at. *)
let checks_the_home_circle_at_its_address () =
  let n = operator_node () and w = world () in
  let m, bytes = bundle "0.2.0" in
  (match pass w n bytes m with
  | [ D.Deployed _ ] -> ()
  | os ->
      Alcotest.failf "%s" (String.concat "; " (List.map D.outcome_to_string os)));
  Alcotest.(check bool) "read the circle" true (w.circle_reads <> []);
  List.iter
    (fun u ->
      let path =
        String.sub u (String.length url) (String.length u - String.length url)
      in
      Alcotest.(check bool)
        ("the health check's path starts with /c/: " ^ path)
        true
        (String.starts_with ~prefix:"/c/" path);
      Alcotest.(check string)
        "at the home circle's address"
        (address n ^ "/v0/circle")
        u)
    w.circle_reads

(* A relay url that already names a circle's address (a node's stored urls once rewritten) is
   taken from its base: the address never nests a second /c/. *)
let the_address_never_nests () =
  let root = "sha256:" ^ String.make 64 'a' in
  let address = url ^ "/c/" ^ String.make 64 'a' in
  Alcotest.(check string)
    "from the base" address
    (Relay_client.circle_address url ~root);
  Alcotest.(check string)
    "from the address" address
    (Relay_client.circle_address address ~root);
  Alcotest.(check string)
    "from the address with a slash" address
    (Relay_client.circle_address (address ^ "/") ~root);
  Alcotest.(check string)
    "the base of an address" url
    (Relay_client.relay_base address);
  Alcotest.(check string)
    "a path that is not an address is kept" (url ^ "/c/x")
    (Relay_client.relay_base (url ^ "/c/x"))

let () =
  Ci_alcotest.run "digestif-relay-deploy-pass"
    [
      ( "deploy",
        [
          Alcotest.test_case "deploys and says so once" `Quick
            deploys_and_says_so_once;
          Alcotest.test_case "checks the home circle at its address" `Quick
            checks_the_home_circle_at_its_address;
          Alcotest.test_case "the address never nests" `Quick
            the_address_never_nests;
          Alcotest.test_case "uploads assets in several buckets" `Quick
            uploads_assets_in_several_buckets;
          Alcotest.test_case "resumes where the relay is" `Quick
            resumes_where_the_relay_is;
          Alcotest.test_case "rolls back a failed health check" `Quick
            rolls_back_a_failed_health_check;
          Alcotest.test_case "a failed rollback leads until the relay answers"
            `Quick a_failed_rollback_leads_until_the_relay_answers;
          Alcotest.test_case "a failure before the deploy is pending" `Quick
            a_failure_before_the_deploy_is_pending;
          Alcotest.test_case "a bundle that does not match is pending" `Quick
            a_bundle_that_does_not_match_is_pending;
          Alcotest.test_case "a refused token waits for a new one" `Quick
            a_refused_token_waits_for_a_new_one;
          Alcotest.test_case "a failed migration is refused for good" `Quick
            a_failed_migration_is_refused_for_good;
          Alcotest.test_case "not due" `Quick not_due;
          Alcotest.test_case "uploads the script for a new migration tag" `Quick
            uploads_the_script_for_a_new_migration_tag;
          Alcotest.test_case "uploads a version once the tag is applied" `Quick
            uploads_a_version_once_the_tag_is_applied;
          Alcotest.test_case "refuses a tag the bundle does not carry" `Quick
            refuses_a_tag_the_bundle_does_not_carry;
          Alcotest.test_case
            "a failed script upload is rolled back or says why not" `Quick
            a_failed_script_upload_is_rolled_back_or_says_why_not;
          Alcotest.test_case "refuses a malformed store bundle" `Quick
            refuses_a_malformed_store_bundle;
        ] );
    ]
