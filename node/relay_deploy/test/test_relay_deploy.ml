(* Operating a relay (docs/releases.md, Who operates a relay): `digestif relay operate`, `--remove`,
   `digestif relay status`, the token checks against a fake Cloudflare account, and the operator
   test. *)

open Digestif_core
module O = Digestif_relay_deploy.Operate
module Cf = Digestif_relay_deploy.Cloudflare

let ok = function Ok v -> v | Error e -> Alcotest.fail e
let check_str = Alcotest.(check string)

let contains s sub =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  go 0

let tmpdir () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "digestif-relay-test-%d-%s" (Unix.getpid ())
       (B64url.encode (Crypto.random 6)))

let url = "https://dinners.test"
let token = "cf-token-SECRET-123"

(* A node that founded a circle and wrote the relay message for [url], so the circle reads it as
   that relay's operator. *)
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
  n

(* A fake Cloudflare account holding [workers], answering for [token] only. *)
let cloudflare ?(workers = [ "digestif-relay" ]) ?(user_token = true)
    ?(calls = ref []) () : Cf.transport =
 fun ~meth ~path ~token:t ~body:_ ->
  calls := (meth, path) :: !calls;
  let answer result =
    Ok
      {
        Relay_client.status = 200;
        body =
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("success", `Bool true);
                 ("errors", `List []);
                 ("result", result);
               ]);
      }
  in
  let refuse status =
    Ok
      {
        Relay_client.status;
        body =
          {|{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}|};
      }
  in
  if t <> token then refuse 401
  else
    match path with
    | "/user/tokens/verify" ->
        if user_token then answer (`Assoc [ ("status", `String "active") ])
        else refuse 401
    | "/accounts/acct/tokens/verify" ->
        answer (`Assoc [ ("status", `String "active") ])
    | "/accounts/acct/workers/scripts" ->
        answer
          (`List (List.map (fun w -> `Assoc [ ("id", `String w) ]) workers))
    | "/accounts/acct/d1/database/db-1" ->
        answer (`Assoc [ ("uuid", `String "db-1") ])
    | "/accounts/acct/workers/scripts/digestif-relay/deployments" ->
        answer
          (`Assoc
             [
               ( "deployments",
                 `List
                   [
                     `Assoc
                       [
                         ("created_on", `String "2026-10-01T00:00:00Z");
                         ( "versions",
                           `List
                             [
                               `Assoc
                                 [
                                   ("version_id", `String "ver-old");
                                   ("percentage", `Int 100);
                                 ];
                             ] );
                       ];
                     `Assoc
                       [
                         ("created_on", `String "2026-11-01T00:00:00Z");
                         ( "versions",
                           `List
                             [
                               `Assoc
                                 [
                                   ("version_id", `String "ver-now");
                                   ("percentage", `Int 100);
                                 ];
                             ] );
                       ];
                   ] );
             ])
    | _ -> Ok { Relay_client.status = 404; body = "{}" }

(* The relay answering GET /v0/circle with [version]. *)
let relay ?version () : Relay_client.transport =
 fun ~meth:_ ~url:u ~headers:_ ~body:_ ->
  if u <> url ^ "/v0/circle" then Error ("no route to " ^ u)
  else
    Ok
      {
        Relay_client.status = 200;
        body =
          Yojson.Safe.to_string
            (`Assoc
               ([ ("root", `String "r"); ("epoch", `Int 0) ]
               @
               match version with
               | Some v -> [ ("relay_version", `String v) ]
               | None -> []));
      }

let setup =
  {
    O.account_id = "acct";
    worker = "digestif-relay";
    database_id = "db-1";
    token;
  }

let releases () : Digestif_update.Circle_relay_release.t =
  { newest = None; counted = []; faults = [] }

let read_record (n : Node.t) =
  In_channel.with_open_bin (O.record_path n.dir) In_channel.input_all

let sets_up_a_relay () =
  let n = operator_node () in
  let lines =
    ok
      (O.operate ~cloudflare:(cloudflare ())
         ~transport:(relay ~version:"0.1.0" ())
         n ~url setup)
  in
  Alcotest.(check bool)
    "says what it deploys" true
    (List.mem
       ("This node deploys " ^ url ^ " from each signed relay release.")
       lines);
  Alcotest.(check (option string))
    "the token is in the keystore" (Some token)
    (ok (n.keystore.get "relay-deploy-token"));
  let r = Option.get (ok (O.load n.dir)) in
  check_str "account" "acct" r.account_id;
  check_str "worker" "digestif-relay" r.worker;
  check_str "database" "db-1" r.database_id;
  check_str "the version serving now is the rollback target" "ver-now"
    r.rollback_version_id;
  Alcotest.(check (option string))
    "starts from what the relay runs" (Some "0.1.0") r.reported_version;
  Alcotest.(check bool)
    "the record holds no token" false
    (contains (read_record n) token);
  Alcotest.(check (list string))
    "this node operates it" [ url ]
    (O.operated n (Node.fold n));
  let status = String.concat "\n" (O.status n ~releases:(releases ())) in
  Alcotest.(check bool) "status names the relay" true (contains status url);
  Alcotest.(check bool)
    "status says this node operates it" true
    (contains status "operator\tthis node");
  Alcotest.(check bool)
    "status names the deployed version" true
    (contains status "deployed version\t0.1.0");
  Alcotest.(check bool)
    "status never prints the token" false (contains status token);
  Alcotest.(check int)
    "no digest line for the operator" 0
    (List.length (O.digest_lines n ~now:0.))

let refuses_and_stores_nothing name ?cf ?(url = url) ?(relay = relay ()) want ()
    =
  let n = operator_node () in
  let cf = Option.value cf ~default:(cloudflare ()) in
  (match O.operate ~cloudflare:cf ~transport:relay n ~url setup with
  | Ok _ -> Alcotest.failf "%s: operate succeeded" name
  | Error e -> Alcotest.(check bool) (name ^ ": " ^ e) true (contains e want));
  Alcotest.(check (option string))
    (name ^ ": no token stored")
    None
    (ok (n.keystore.get "relay-deploy-token"));
  Alcotest.(check bool)
    (name ^ ": no record") false
    (Sys.file_exists (O.record_path n.dir))

let refuses_a_second_worker =
  refuses_and_stores_nothing "a second Worker"
    ~cf:(cloudflare ~workers:[ "digestif-relay"; "something-else" ] ())
    "something-else"

let refuses_a_token_without_the_worker =
  refuses_and_stores_nothing "no Worker"
    ~cf:(cloudflare ~workers:[] ())
    "cannot see the Worker"

let refuses_a_bad_token () =
  let n = operator_node () in
  (match
     O.operate ~cloudflare:(cloudflare ()) ~transport:(relay ()) n ~url
       { setup with token = "wrong" }
   with
  | Ok _ -> Alcotest.fail "a wrong token was taken"
  | Error e ->
      Alcotest.(check bool) e true (contains e "refused the deploy token"));
  Alcotest.(check (option string))
    "nothing stored" None
    (ok (n.keystore.get "relay-deploy-token"))

let refuses_a_relay_the_circle_does_not_name =
  refuses_and_stores_nothing "unnamed relay" ~url:"https://elsewhere.test"
    "names no relay"

let refuses_a_relay_that_does_not_answer =
  refuses_and_stores_nothing "relay down"
    ~relay:(fun ~meth:_ ~url:_ ~headers:_ ~body:_ -> Error "connection refused")
    "did not answer"

(* A token the account owns answers only at the account's own verify route. *)
let takes_an_account_token () =
  let n = operator_node () in
  let calls = ref [] in
  ignore
    (ok
       (O.operate
          ~cloudflare:(cloudflare ~user_token:false ~calls ())
          ~transport:(relay ()) n ~url setup));
  Alcotest.(check bool)
    "asked the account's verify route" true
    (List.mem ("GET", "/accounts/acct/tokens/verify") !calls);
  Alcotest.(check (option string))
    "an unstamped relay reports no version" None
    (Option.get (ok (O.load n.dir))).reported_version

(* A trailing slash names the same relay; operate run again replaces the token. *)
let operate_again_replaces_the_token () =
  let n = operator_node () in
  let cf = cloudflare () in
  ignore
    (ok
       (O.operate ~cloudflare:cf ~transport:(relay ()) n ~url:(url ^ "/") setup));
  let count = Log.count n.log in
  ignore (ok (O.operate ~cloudflare:cf ~transport:(relay ()) n ~url setup));
  Alcotest.(check int)
    "the operator's own relay message is not written again" count
    (Log.count n.log);
  ignore
    (ok
       (Node.write n ~kind:"relay"
          (Bodies.make_relay ~url:"https://other.test" ~mailer:false ())));
  match
    O.operate ~cloudflare:cf ~transport:(relay ()) n ~url:"https://other.test"
      setup
  with
  | Ok _ -> Alcotest.fail "a second relay was taken"
  | Error e -> Alcotest.(check bool) e true (contains e "operate --remove")

let remove_deletes_both () =
  let n = operator_node () in
  ignore
    (ok
       (O.operate ~cloudflare:(cloudflare ()) ~transport:(relay ()) n ~url setup));
  Alcotest.(check bool)
    "another url is refused" true
    (Result.is_error (O.remove n ~url:"https://other.test"));
  ignore (ok (O.remove n ~url));
  Alcotest.(check (option string))
    "token gone" None
    (ok (n.keystore.get "relay-deploy-token"));
  Alcotest.(check bool)
    "record gone" false
    (Sys.file_exists (O.record_path n.dir));
  Alcotest.(check (list string))
    "operates nothing" []
    (O.operated n (Node.fold n));
  ignore (ok (O.remove n ~url))

(* The operator test from its facts: both halves, or nothing. *)
let the_operator_test () =
  let r =
    {
      O.url;
      account_id = "acct";
      worker = "w";
      database_id = "d";
      rollback_version_id = "v";
      reported_version = None;
      pending = None;
      refused = [];
      told_not_operator = false;
      token_refused = false;
      notes = [];
    }
  in
  let name = function
    | O.Operates _ -> "operates"
    | Not_operator _ -> "not operator"
    | Not_set_up -> "not set up"
  in
  let judge ?(operator = Some "me") ?(identity = Some "me") ?(record = Some r)
      ?(token_held = true) () =
    name (O.judge ~operator ~identity ~record ~token_held)
  in
  check_str "both halves" "operates" (judge ());
  check_str "another member's relay message" "not operator"
    (judge ~operator:(Some "you") ());
  check_str "no relay message" "not operator" (judge ~operator:None ());
  check_str "no token" "not set up" (judge ~token_held:false ());
  check_str "no record" "not set up" (judge ~record:None ())

(* A token held for a relay the circle does not name as this node's: deploys nothing, and the
   digest says so once. *)
let a_token_for_another_relay_is_said_once () =
  let n = operator_node () in
  ignore
    (ok
       (O.operate ~cloudflare:(cloudflare ()) ~transport:(relay ()) n ~url setup));
  let r = Option.get (ok (O.load n.dir)) in
  O.save n.dir { r with url = "https://not-ours.test" };
  Alcotest.(check (list string))
    "deploys nothing" []
    (O.operated n (Node.fold n));
  (match O.digest_lines n ~now:0. with
  | [ l ] ->
      Alcotest.(check bool) l.text true (contains l.text "deploys nothing");
      l.tell ()
  | ls -> Alcotest.failf "%d lines" (List.length ls));
  Alcotest.(check int) "said once" 0 (List.length (O.digest_lines n ~now:0.));
  let status = String.concat "\n" (O.status n ~releases:(releases ())) in
  Alcotest.(check bool) status true (contains status "deploys nothing")

(* The token reaches curl on stdin, never on an argv. *)
let the_token_is_never_an_argument () =
  let config =
    Cf.curl_config ~meth:"GET" ~path:"/user/tokens/verify" ~token:"a\"b\\c"
      ~body:None
  in
  Alcotest.(check bool)
    "the config carries it, quoted" true
    (contains config {|header = "Authorization: Bearer a\"b\\c"|});
  Alcotest.(check bool)
    "curl reads its config from stdin" true
    (Array.exists (( = ) "-K") Cf.curl_argv);
  Alcotest.(check bool)
    "no argument carries a token" false
    (Array.exists (fun a -> contains a "Bearer") Cf.curl_argv)

let () =
  Ci_alcotest.run "digestif-relay-deploy"
    [
      ( "operate",
        [
          Alcotest.test_case "sets up a relay" `Quick sets_up_a_relay;
          Alcotest.test_case "refuses a second Worker" `Quick
            refuses_a_second_worker;
          Alcotest.test_case "refuses a token without the Worker" `Quick
            refuses_a_token_without_the_worker;
          Alcotest.test_case "refuses a bad token" `Quick refuses_a_bad_token;
          Alcotest.test_case "refuses a relay the circle does not name" `Quick
            refuses_a_relay_the_circle_does_not_name;
          Alcotest.test_case "refuses a relay that does not answer" `Quick
            refuses_a_relay_that_does_not_answer;
          Alcotest.test_case "takes an account token" `Quick
            takes_an_account_token;
          Alcotest.test_case "again replaces the token" `Quick
            operate_again_replaces_the_token;
          Alcotest.test_case "remove deletes both" `Quick remove_deletes_both;
          Alcotest.test_case "the token is never an argument" `Quick
            the_token_is_never_an_argument;
        ] );
      ( "operator",
        [
          Alcotest.test_case "the operator test" `Quick the_operator_test;
          Alcotest.test_case "a token for another relay is said once" `Quick
            a_token_for_another_relay_is_said_once;
        ] );
    ]
