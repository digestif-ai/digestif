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

(* A bundle for [version] with two migrations, and its manifest. *)
let bundle version =
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
  write
    (Filename.concat root "bundle.json")
    {|{"main_module":"index.js","compatibility_date":"2026-08-01","compatibility_flags":["nodejs_compat"]}|};
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

let form w : Cf.form_transport =
 fun ~path ~token:t ~parts ->
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
          let annotation k =
            match j with
            | `Assoc f -> (
                match List.assoc_opt "annotations" f with
                | Some (`Assoc a) -> (
                    match List.assoc_opt k a with
                    | Some (`String s) -> s
                    | _ -> "")
                | _ -> "")
            | _ -> ""
          in
          w.versions <-
            ("ver-new", annotation "workers/tag", annotation "workers/message")
            :: w.versions;
          answer (`Assoc [ ("id", `String "ver-new") ]))
      else Ok { Relay_client.status = 404; body = "{}" }

let relay w (n : Node.t) : Relay_client.transport =
 fun ~meth:_ ~url:u ~headers:_ ~body:_ ->
  if u = url ^ "/app/" then Ok { Relay_client.status = 200; body = "<html>" }
  else if u = url ^ "/v0/circle" then
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
      (fun u ->
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

let () =
  Ci_alcotest.run "digestif-relay-deploy-pass"
    [
      ( "deploy",
        [
          Alcotest.test_case "deploys and says so once" `Quick
            deploys_and_says_so_once;
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
        ] );
    ]
