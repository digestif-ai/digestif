(* The localhost server: who may call it, the deny layer, and the API over a demo circle. *)

open Digestif_core
open Digestif_web

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  go 0

(* Where [needle] first starts in [hay]. *)
let index_of hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i =
    if i + n > h then raise Not_found
    else if String.sub hay i n = needle then i
    else go (i + 1)
  in
  go 0

(* One path segment, as the UI's client writes it with encodeURIComponent. *)
let enc s =
  String.concat ""
    (List.map
       (fun c ->
         match c with
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
             String.make 1 c
         | c -> Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq s)))

let tmpdir () =
  let d = Filename.temp_file "digestif-web" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  d

(* A fixture folder that the test removes at its end: [fixture] makes one under the temp folder,
   and [cleaned] runs a test and removes every folder it made, whether it passed or not. *)
let fixtures = ref []

let remove_tree p =
  ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; p ]))

let fixture () =
  let d = Filename.temp_file "digestif-web" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  fixtures := d :: !fixtures;
  d

let cleaned f () =
  let before = !fixtures in
  Fun.protect f ~finally:(fun () ->
      List.iter remove_tree
        (List.filter (fun d -> not (List.mem d before)) !fixtures);
      fixtures := before)

let demo () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  ok (Demo.seed n);
  n

let request ?(meth = "GET") ?(headers = []) ?(body = "") target : Http.request =
  let path, query =
    match String.index_opt target '?' with
    | Some i ->
        ( String.sub target 0 i,
          Http.parse_query
            (String.sub target (i + 1) (String.length target - i - 1)) )
    | None -> (target, [])
  in
  {
    meth;
    target;
    path;
    query;
    headers = ("host", "127.0.0.1:7420") :: headers;
    body;
  }

(* A session as the browser holds one after the launch link. *)
let session n =
  let token = Store.new_launch_token n.Node.log in
  let r = Server.handler n (request ("/launch?token=" ^ token)) in
  Alcotest.(check int) "launch redirects" 303 r.status;
  let cookie = List.assoc "Set-Cookie" r.headers in
  Alcotest.(check bool) "httponly" true (contains cookie "HttpOnly");
  Alcotest.(check bool) "strict" true (contains cookie "SameSite=Strict");
  String.sub cookie 0 (String.index cookie ';')

let call n cookie ?(meth = "GET") ?body path =
  let r =
    Server.handler n
      (request ~meth
         ~headers:[ ("cookie", cookie); ("digestif-local", "1") ]
         ?body:(Option.map Yojson.Safe.to_string body)
         ("/api/v0/" ^ path))
  in
  (r.status, if r.body = "" then `Null else Yojson.Safe.from_string r.body)

(* DIG-236: the run loop's pass after a sync (Api.keep_up), which re-opens and re-decides what a join
   or a revoke changed; a page's GET leaves that to it. *)
let keep_up n =
  match Api.keep_up n with Ok () -> () | Error e -> Alcotest.fail e

(* An envelope reaching the log outside the API, as on a running node: one a sync brings (import)
   or the node's own agent writes (write), each followed by the run loop's pass (keep_up), which
   indexes it. A page's GET answers from that index and indexes nothing (DIG-375). [Core_node]
   is the arrival alone, for a test of what a read does before the pass. *)
module Core_node = Node

module Node = struct
  include Core_node

  let write t ?key_name ?created_at ~kind body =
    let r = Core_node.write t ?key_name ?created_at ~kind body in
    if Result.is_ok r then keep_up t;
    r

  let import t sg =
    let r = Core_node.import t sg in
    if Result.is_ok r then keep_up t;
    r
end

let member name = function
  | `Assoc f -> (
      match List.assoc_opt name f with Some v -> v | None -> `Null)
  | _ -> `Null

let s name j = match member name j with `String v -> v | _ -> ""
let list = function `List l -> l | _ -> []

(* who may call *)

(* DIG-275: a second node on the machine answers on 127.0.0.1 at a port of its own, and a browser
   keeps cookies by host, not port. Its launch sets a cookie named for its port, its API reads only
   that one, so neither node's launch overwrites the other's session. *)
let second_node_cookie () =
  let n = demo () in
  Log.set_config n.Node.log Api.k_ui_url "http://127.0.0.1:7421";
  let c = session n in
  Alcotest.(check string)
    "the cookie names the port" "digestif_session_7421"
    (String.sub c 0 (String.index c '='));
  let token =
    let i = String.index c '=' in
    String.sub c (i + 1) (String.length c - i - 1)
  in
  let status cookie =
    (Server.handler n
       (request
          ~headers:[ ("digestif-local", "1"); ("cookie", cookie) ]
          "/api/v0/status"))
      .status
  in
  Alcotest.(check int) "its own cookie" 200 (status c);
  Alcotest.(check int)
    "beside the standard node's cookie" 200
    (status ("digestif_session=other; " ^ c));
  Alcotest.(check int)
    "the standard name opens nothing here" 401
    (status ("digestif_session=" ^ token))

let access () =
  let n = demo () in
  let c = session n in
  let status ?(headers = []) ?(meth = "GET") target =
    (Server.handler n (request ~meth ~headers target)).status
  in
  Alcotest.(check int)
    "no header" 403
    (status ~headers:[ ("cookie", c) ] "/api/v0/status");
  Alcotest.(check int)
    "no cookie" 401
    (status ~headers:[ ("digestif-local", "1") ] "/api/v0/status");
  Alcotest.(check int)
    "a made-up cookie" 401
    (status
       ~headers:[ ("digestif-local", "1"); ("cookie", "digestif_session=nope") ]
       "/api/v0/status");
  Alcotest.(check int)
    "both" 200
    (status
       ~headers:[ ("digestif-local", "1"); ("cookie", c) ]
       "/api/v0/status");
  Alcotest.(check int)
    "another origin" 403
    (status
       ~headers:
         [
           ("digestif-local", "1");
           ("cookie", c);
           ("origin", "https://evil.example");
         ]
       "/api/v0/status");
  Alcotest.(check int)
    "this origin" 200
    (status
       ~headers:
         [
           ("digestif-local", "1");
           ("cookie", c);
           ("origin", "http://127.0.0.1:7420");
         ]
       "/api/v0/status");
  let rebound =
    {
      (request "/api/v0/status") with
      headers = [ ("host", "evil.example:7420") ];
    }
  in
  Alcotest.(check int) "a rebound host" 403 (Server.handler n rebound).status;
  let token = Store.new_launch_token n.log in
  Alcotest.(check int) "a launch link" 303 (status ("/launch?token=" ^ token));
  Alcotest.(check int) "used twice" 403 (status ("/launch?token=" ^ token));
  (* ISS-78222: a launch lands on the page its next names, and only on a path of this origin. *)
  let lands next =
    let token = Store.new_launch_token n.log in
    let r =
      Server.handler n
        (request ("/launch?token=" ^ token ^ "&next=" ^ Http.query_encode next))
    in
    List.assoc "Location" r.headers
  in
  Alcotest.(check string)
    "lands on a message" "/feed/sha256:abc" (lands "/feed/sha256:abc");
  Alcotest.(check string)
    "with its query" "/inbox?status=new"
    (lands "/inbox?status=new");
  List.iter
    (fun next ->
      Alcotest.(check string)
        ("never off this origin: " ^ next)
        "/" (lands next))
    [
      "//evil.example/";
      "/\\evil.example";
      "https://evil.example/";
      "feed";
      "/a\nb";
      "";
    ];
  let cookie =
    List.assoc "Set-Cookie"
      (Server.handler n
         (request ("/launch?token=" ^ Store.new_launch_token n.log)))
        .headers
  in
  Alcotest.(check bool)
    "the session outlives the browser" true
    (contains cookie "Max-Age=2592000");
  Alcotest.(check (list string))
    "open takes a link the digest carried, or its path"
    [ "/feed/sha256:abc"; "/feed/sha256:abc"; "/inbox/item-1"; "/"; "/" ]
    (List.map Server.page_of
       [
         "http://127.0.0.1:7420/feed/sha256:abc";
         "/feed/sha256:abc";
         "inbox/item-1";
         "http://127.0.0.1:7420";
         "http://evil.example//x";
       ]);
  Log.set_config n.log Api.k_ui_url "http://127.0.0.1:7420";
  let url =
    Result.get_ok
      (Server.launch_url ~page:"http://127.0.0.1:7420/feed/sha256:abc" n)
  in
  Alcotest.(check bool)
    "the launch link carries the page" true
    (contains url "&next=/feed/sha256:abc");
  Alcotest.(check bool)
    "and none for the Inbox" false
    (contains (Result.get_ok (Server.launch_url n)) "next=");
  Alcotest.(check int)
    "the shell for any page" 200
    (status "/members/ed25519:x");
  Alcotest.(check int) "never a preflight" 405 (status ~meth:"OPTIONS" "/")

(* the deny layer *)

(* Every case in node/mail/test/deny_cases.json, which the phone's node/mail/webcrypto/deny.mjs runs
   too, so the machine and the phone refuse the same text by the same rule. *)
let deny () =
  let check ?(allowed = []) entries text =
    match Deny.check ~entries ~allowed text with
    | Deny.Pass -> "pass"
    | Tripped { rule; _ } -> rule
  in
  let cases =
    Yojson.Safe.from_file "../../mail/test/deny_cases.json"
    |> Yojson.Safe.Util.member "cases"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check bool) "the cases load" true (List.length cases > 50);
  List.iter
    (fun c ->
      let open Yojson.Safe.Util in
      let str k = to_string (member k c) in
      let entries =
        List.mapi
          (fun i e : Store.deny_entry ->
            {
              d_id = string_of_int i;
              d_kind = to_string (member "kind" e);
              value = to_string (member "value" e);
              created_at = "";
              trips = 0;
            })
          (to_list (member "entries" c))
      in
      let allowed = List.map to_string (to_list (member "allowed" c)) in
      let rule =
        match member "rule" c with `Null -> "pass" | r -> to_string r
      in
      Alcotest.(check string)
        (str "name") rule
        (check ~allowed entries (str "text")))
    cases;
  Alcotest.(check bool)
    "a broken pattern" true
    (Result.is_error (Deny.compile_pattern "("))

(* The deny list for the member's phone: written once, again only when the list changes, an empty
   list included, sealed to the member's own key. *)
let deny_share () =
  let n = demo () in
  let c = session n in
  let enc = ok (Node.encryption_key n) in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let shared () =
    match Deny_share.newest n (Node.fold n) ~me ~enc with
    | None -> []
    | Some p ->
        List.map
          (fun e -> Yojson.Safe.Util.(to_string (member "value" e)))
          Yojson.Safe.Util.(to_list (member "entries" p))
  in
  let listed () =
    List.map (fun (e : Store.deny_entry) -> e.value) (Store.deny_list n.log)
  in
  let first = ok (Deny_share.publish n) in
  Alcotest.(check bool) "the first pass writes it" true (first <> None);
  Alcotest.(check (list string))
    "as the machine holds it" (listed ()) (shared ());
  Alcotest.(check bool)
    "an unchanged list is not written again" true
    (ok (Deny_share.publish n) = None);
  let st, added =
    call n c ~meth:"POST"
      ~body:(`Assoc [ ("kind", `String "name"); ("value", `String "Zed Corp") ])
      "rules/deny"
  in
  Alcotest.(check int) "added" 201 st;
  Alcotest.(check bool)
    "adding an entry shares it" true
    (List.mem "Zed Corp" (shared ()));
  Alcotest.(check bool)
    "and the pass has nothing left to write" true
    (ok (Deny_share.publish n) = None);
  let st, _ = call n c ~meth:"DELETE" ("rules/deny/" ^ s "id" added) in
  Alcotest.(check int) "removed" 204 st;
  Alcotest.(check bool)
    "removing it shares the list without it" false
    (List.mem "Zed Corp" (shared ()));
  List.iter
    (fun (e : Store.deny_entry) -> Store.remove_deny n.log e.d_id)
    (Store.deny_list n.log);
  Alcotest.(check bool)
    "an emptied list is written too" true
    (ok (Deny_share.publish n) <> None);
  Alcotest.(check (list string)) "empty" [] (shared ());
  let r =
    List.find
      (fun (r : Log.row) -> r.signed.envelope.kind = "deny_list")
      (Log.all n.log)
  in
  Alcotest.(check bool)
    "sealed, never the entries in the clear" false
    (contains (Yojson.Safe.to_string (Option.get r.signed.body)) "Zed Corp")

(* the API over the demo circle *)

let api () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let st, status = call "status" in
  Alcotest.(check int) "status" 200 st;
  Alcotest.(check string) "member" "Ada Park" (s "member_name" status);
  Alcotest.(check string)
    "the circle is the root dinner's label, as the invite subject names it"
    "AI Dinner 1" (s "circle_label" status);
  Alcotest.(check string)
    "the status carries the running version, what --version prints (DIG-523)"
    (Digestif_update.Version.to_string (Digestif_update.Trust_root.version ()))
    (s "version" status);
  Alcotest.(check bool)
    "Ada has shared a note, so the navigation shows" true
    (member "first_run" status = `Bool false);
  Alcotest.(check bool)
    "one note waits" true
    (member "notes_awaiting_approval" status = `Int 1);
  let _, feed = call "feed" in
  Alcotest.(check (list string))
    "the feed is notes: no directed kinds" [ "summary" ]
    (List.sort_uniq compare (List.map (s "kind") (list feed)));
  let question =
    List.find
      (fun i ->
        s "preview" i
        = "Has anyone tried a fake clock for timer tests? Ben is stuck on the \
           same thing.")
      (list feed)
  in
  Alcotest.(check bool)
    "status counts no asks" true
    (member "open_asks" status = `Null);
  Alcotest.(check int) "the asks list is gone" 404 (fst (call "asks"));
  Alcotest.(check int) "limit" 422 (fst (call "feed?limit=0"));
  Alcotest.(check int)
    "limit one" 1
    (List.length (list (snd (call "feed?limit=1"))));
  (* compose *)
  let st, m =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "Hosting dinner 3.") ])
      "messages"
  in
  Alcotest.(check int) "posted" 201 st;
  Alcotest.(check string) "status" "posted" (s "status" m);
  Alcotest.(check string) "voice" "person" (s "voice" m);
  (match Log.find n.log (s "hash" m) with
  | Some r ->
      Alcotest.(check bool) "signed" true (Envelope.verify r.signed = Ok ())
  | None -> Alcotest.fail "not in the log");
  let st, refused =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "notes at internal.example.com") ])
      "messages"
  in
  Alcotest.(check int) "refused is created" 201 st;
  Alcotest.(check string) "refused" "refused" (s "status" refused);
  Alcotest.(check string) "rule" "deny: domain" (s "refused_rule" refused);
  Alcotest.(check bool) "no text" true (member "text" refused = `Null);
  (* A person's own post passes the code detectors, the financial ones included, and nothing else
     judges it: no model screen reads what a member writes in their own words. *)
  let _, phrase =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ( "text",
               `String
                 ("my seed is "
                 ^ String.concat " " (List.init 11 (fun _ -> "abandon"))
                 ^ " about") );
           ])
      "messages"
  in
  Alcotest.(check string)
    "a recovery phrase in a post" "detector: Recovery phrases"
    (s "refused_rule" phrase);
  let _, figures =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [ ("text", `String "Shipped the invoicing page; it totals $4,200.") ])
      "messages"
  in
  Alcotest.(check string)
    "a figure in a post is the member's call" "posted" (s "status" figures);
  Alcotest.(check int)
    "empty" 422
    (fst
       (call ~meth:"POST" ~body:(`Assoc [ ("text", `String "  ") ]) "messages"));
  Alcotest.(check int)
    "a reply to nothing" 422
    (fst
       (call ~meth:"POST"
          ~body:
            (`Assoc
               [ ("text", `String "hi"); ("reply_to", `String "sha256:00") ])
          "messages"));
  (* A reply to another member's note is a note in the circle: nothing is sealed to one member
     but an item. *)
  let st, answer =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String "Yes, a fake clock works.");
             ("reply_to", `String (s "hash" question));
           ])
      "messages"
  in
  Alcotest.(check int) "answered" 201 st;
  Alcotest.(check string) "a summary" "summary" (s "kind" answer);
  Alcotest.(check bool)
    "to no one in particular" true
    (member "recipient" answer = `Null);
  Alcotest.(check string)
    "we read our own" "Yes, a fake clock works." (s "text" answer);
  (match Log.find n.log (s "hash" answer) with
  | Some { signed = { body = Some b; _ }; _ } ->
      Alcotest.(check bool)
        "plaintext on the wire, like every note" true
        (member "sealed" b = `Null
        && member "text" b = `String "Yes, a fake clock works.")
  | _ -> Alcotest.fail "answer not in the log");
  let _, q = call ("messages/" ^ enc (s "hash" question)) in
  Alcotest.(check int)
    "both replies are listed, the refused one too" 2
    (List.length (list (member "replies" q)));
  (* ISS-85464: the reply's Feed row names the note it answers, which is its thread. *)
  Alcotest.(check string)
    "the reply's Feed row names its note" (s "hash" question)
    (s "reply_to"
       (List.find
          (fun f -> s "hash" f = s "hash" answer)
          (list (snd (call "feed")))));
  (* members *)
  let _, members = call "members" in
  let by name = List.find (fun m -> s "name" m = name) (list members) in
  Alcotest.(check (list string))
    "Active, then Paused, then Onboarding, the newest note first"
    [ "Ben Ortiz"; "Cy Lund"; "Ada Park"; "Dee Rao"; "Fay Kim" ]
    (List.map (s "name") (list members));
  Alcotest.(check (list string))
    "stages"
    [ "active"; "active"; "active"; "paused"; "onboarding" ]
    (List.map (s "stage") (list members));
  Alcotest.(check string)
    "a status note beside the time" "could_not_run"
    (s "last_status_note" (by "Cy Lund"));
  Alcotest.(check bool)
    "a member's card key, which a reply to them is sealed to" true
    (String.starts_with ~prefix:"x25519:" (s "encryption_key" (by "Ben Ortiz")));
  Alcotest.(check string)
    "Paused." "paused"
    (s "last_status_note" (by "Dee Rao"));
  Alcotest.(check bool)
    "a person's post is not a note" true
    (member "last_status_note" (by "Ben Ortiz") = `Null
    && s "last_note_at" (by "Ben Ortiz") <> "");
  Alcotest.(check bool)
    "Onboarding: no note yet" true
    (member "last_note_at" (by "Fay Kim") = `Null);
  Alcotest.(check bool)
    "no silence derived from the time" true
    (member "silence_reason" (by "Dee Rao") = `Null
    && member "last_posted_at" (by "Dee Rao") = `Null);
  Alcotest.(check int)
    "self" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("muted", `Bool true) ])
          ("members/" ^ enc (s "identity" (by "Ada Park")) ^ "/mute")));
  let st, ben =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("muted", `Bool true) ])
      ("members/" ^ enc (s "identity" (by "Ben Ortiz")) ^ "/mute")
  in
  Alcotest.(check int) "muted" 200 st;
  Alcotest.(check bool) "is muted" true (member "muted" ben = `Bool true);
  Alcotest.(check int) "a device" 1 (List.length (list (member "devices" ben)));
  (* invitees: Eve's invite is unused; Fay's was spent by her join and the first dinner's by theirs *)
  Alcotest.(check (list string))
    "an invite not yet used" [ "Eve Moss" ]
    (List.map (s "name") (list (snd (call "invitees"))));
  Alcotest.(check int) "no dinners" 404 (fst (call "dinners"));
  (* the approval contract (ISS-87805): every member reads as a member until the signer set folds *)
  Alcotest.(check (list string))
    "every member's role" [ "member" ]
    (List.sort_uniq compare (List.map (s "role") (list members)));
  Alcotest.(check string) "the member page's role" "member" (s "role" ben);
  (* brief, sources, rules *)
  Alcotest.(check int)
    "empty brief" 422
    (fst (call ~meth:"PUT" ~body:(`Assoc [ ("text", `String "") ]) "brief"));
  Alcotest.(check string)
    "brief" "I build tools."
    (s "text"
       (snd
          (call ~meth:"PUT"
             ~body:(`Assoc [ ("text", `String "I build tools.") ])
             "brief")));
  Alcotest.(check int)
    "unknown source" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("selected", `List [ `String "mail" ]) ])
          "sources"));
  Alcotest.(check int)
    "the preview note is gone" 404
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("selected", `List [ `String "git" ]) ])
          "sources/preview"));
  ignore
    (call ~meth:"PUT"
       ~body:(`Assoc [ ("selected", `List [ `String "git" ]) ])
       "sources");
  Alcotest.(check int)
    "bad pattern" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("kind", `String "pattern"); ("value", `String "(") ])
          "rules/deny"));
  Alcotest.(check int)
    "duplicate" 422
    (fst
       (call ~meth:"POST"
          ~body:
            (`Assoc
               [
                 ("kind", `String "domain");
                 ("value", `String "internal.example.com");
               ])
          "rules/deny"));
  let st, e =
    call ~meth:"POST"
      ~body:
        (`Assoc [ ("kind", `String "name"); ("value", `String "Acme Corp") ])
      "rules/deny"
  in
  Alcotest.(check int) "added" 201 st;
  Alcotest.(check int)
    "removed" 204
    (fst (call ~meth:"DELETE" ("rules/deny/" ^ s "id" e)));
  Alcotest.(check int) "gone" 404 (fst (call ("rules/deny/" ^ s "id" e)));
  let _, rules = call "rules" in
  let tripped = List.hd (list (member "deny" rules)) in
  Alcotest.(check bool) "trips counted" true (member "trips" tripped = `Int 2);
  Alcotest.(check int)
    "eight detectors" 8
    (List.length (list (member "detectors" rules)));
  (* Notes: the member approves exactly the version on the page; the send job signs it. *)
  let _, notes = call "notes" in
  let rows = list (member "notes" notes) in
  Alcotest.(check (list string))
    "newest first, every note"
    [ "waiting"; "approved"; "approved"; "approved"; "approved" ]
    (List.map (s "status") rows);
  Alcotest.(check bool)
    "no suggestion yet" true
    (member "suggest_auto_approval" notes = `Bool false);
  let id = s "id" (List.hd rows) in
  let _, page = call ("notes/" ^ id) in
  let v = member "version" page in
  Alcotest.(check bool)
    "can approve" true
    (member "can_approve" page = `Bool true);
  Alcotest.(check bool) "can edit" true (member "can_edit" page = `Bool true);
  Alcotest.(check string) "the agent's version" "agent" (s "voice" v);
  Alcotest.(check bool) "its text" true (contains (s "text" v) "local web UI");
  let st, approved =
    call ~meth:"POST"
      ~body:(`Assoc [ ("version_id", `String (s "id" v)) ])
      ("notes/" ^ id ^ "/approve")
  in
  Alcotest.(check int) "approve" 200 st;
  Alcotest.(check string) "approved" "approved" (s "status" approved);
  Alcotest.(check bool) "no Edit" true (member "can_edit" approved = `Bool false);
  Alcotest.(check bool)
    "not shared yet" true
    (member "shared_at" approved = `Null);
  Alcotest.(check int)
    "twice" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("version_id", `String (s "id" v)) ])
          ("notes/" ^ id ^ "/approve")));
  Alcotest.(check bool)
    "five unchanged in a row: the suggestion" true
    (member "suggest_auto_approval" (snd (call "notes")) = `Bool true);
  Api.send_notes n;
  let posted = Option.get (Store.Notes.find n.log id) in
  Alcotest.(check bool)
    "the send job signed it" true
    (Option.bind posted.n_posted_hash (Log.find n.log) <> None);
  Api.send_notes n;
  Alcotest.(check (option string))
    "once" posted.n_posted_hash
    (Option.get (Store.Notes.find n.log id)).n_posted_hash;
  Alcotest.(check int)
    "Not now" 204
    (fst (call ~meth:"POST" "notes/suggestion/dismiss"));
  Alcotest.(check bool)
    "restarts the count" true
    (member "suggest_auto_approval" (snd (call "notes")) = `Bool false);
  Alcotest.(check int) "unknown" 404 (fst (call "notes/sha256:00"));
  Alcotest.(check int)
    "an approve naming no version" 422
    (fst (call ~meth:"POST" ~body:(`Assoc []) ("notes/" ^ id ^ "/approve")))

(* Pairing a phone through the local API: 201 with the device row, 422 naming the wrong field, and
   the phrase never in an answer. *)
let phones () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let phrase = Phrase.generate () in
  ok (Demo.seed ~phrase n);
  let c = session n in
  Alcotest.(check string)
    "the mailing relay's phone app" "https://relay-1.example/app/"
    (s "phone_app_url" (snd (call n c "status")));
  let writes = ref 0 in
  let post body =
    let r =
      Server.handler
        ~on_write:(fun () -> incr writes)
        n
        (request ~meth:"POST"
           ~headers:[ ("cookie", c); ("digestif-local", "1") ]
           ~body:(Yojson.Safe.to_string body)
           "/api/v0/phones")
    in
    Alcotest.(check bool)
      "the phrase is never echoed" false (contains r.body phrase);
    (r.status, Yojson.Safe.from_string r.body)
  in
  let phone = Crypto.generate_signing_key () in
  let code =
    Digestif_mail.Phone.pairing_code ~ed25519:phone.pub
      ~x25519:
        (Digestif_mail.Mail_crypto.X25519.public
           (Digestif_mail.Mail_crypto.X25519.generate ()))
  in
  let form code phrase =
    `Assoc
      [ ("pairing_code", `String code); ("recovery_phrase", `String phrase) ]
  in
  let field j = match list j with e :: _ -> s "field" e | [] -> "" in
  let st, e = post (form (code ^ "x") phrase) in
  Alcotest.(check int) "bad check" 422 st;
  Alcotest.(check string) "names the code" "pairing_code" (field e);
  let st, e = post (form code (Phrase.generate ())) in
  Alcotest.(check int) "another identity" 422 st;
  Alcotest.(check string) "names the phrase" "recovery_phrase" (field e);
  let st, e = post (form code "") in
  Alcotest.(check int) "no phrase" 422 st;
  Alcotest.(check string) "names the phrase" "recovery_phrase" (field e);
  Alcotest.(check int) "nothing signed yet" 0 !writes;
  let st, d = post (form code phrase) in
  Alcotest.(check int) "paired" 201 st;
  Alcotest.(check string) "the phone's key" (Keys.public phone) (s "key" d);
  Alcotest.(check string) "role" "device" (s "role" d);
  Alcotest.(check bool) "admitted at" true (s "admitted_at" d <> "");
  Alcotest.(check int) "a sync is asked for" 1 !writes;
  let devices =
    List.map (s "key")
      (list
         (member "devices"
            (snd
               (call n c
                  ("members/"
                  ^ enc (Option.get (Log.get_config n.log Node.k_identity)))))))
  in
  Alcotest.(check bool)
    "a device of the member" true
    (List.mem (Keys.public phone) devices);
  (* Removing it: the phrase signs a revoke after every relay is read. *)
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let device_of key =
    List.find
      (fun d -> s "key" d = key)
      (list (member "devices" (snd (call n c ("members/" ^ enc me)))))
  in
  Alcotest.(check bool)
    "a phone" true
    (member "phone" (device_of (Keys.public phone)) = `Bool true);
  let own = Option.get (Log.get_config n.log Node.k_device) in
  Alcotest.(check bool)
    "this machine is not a phone" true
    (member "phone" (device_of own) = `Bool false);
  let synced = ref 0 in
  let saved = !Api.Phones.sync_first in
  (Api.Phones.sync_first := fun _ -> incr synced);
  Fun.protect
    ~finally:(fun () -> Api.Phones.sync_first := saved)
    (fun () ->
      let revoke key phrase =
        let r =
          Server.handler
            ~on_write:(fun () -> incr writes)
            n
            (request ~meth:"POST"
               ~headers:[ ("cookie", c); ("digestif-local", "1") ]
               ~body:
                 (Yojson.Safe.to_string
                    (`Assoc [ ("recovery_phrase", `String phrase) ]))
               ("/api/v0/phones/" ^ enc key ^ "/revocations"))
        in
        Alcotest.(check bool)
          "the phrase is never echoed" false (contains r.body phrase);
        (r.status, if r.body = "" then `Null else Yojson.Safe.from_string r.body)
      in
      Alcotest.(check int)
        "this machine's key is not removed here" 404
        (fst (revoke own phrase));
      let st, e = revoke (Keys.public phone) (Phrase.generate ()) in
      Alcotest.(check int) "another identity" 422 st;
      Alcotest.(check string) "names the phrase" "recovery_phrase" (field e);
      Alcotest.(check int) "nothing synced or signed" 0 !synced;
      let st, d = revoke (Keys.public phone) phrase in
      Alcotest.(check int) "removed" 200 st;
      Alcotest.(check bool) "revoked at" true (s "revoked_at" d <> "");
      Alcotest.(check int) "relays read first" 1 !synced;
      Alcotest.(check int) "a sync is asked for" 2 !writes;
      Alcotest.(check bool)
        "the member's phone reads revoked" true
        (s "revoked_at" (device_of (Keys.public phone)) <> "");
      Alcotest.(check int)
        "removed once" 422
        (fst (revoke (Keys.public phone) phrase)))

(* Stages, the clock and the status note (docs/design.md, Stages and the status note). The demo's
   Ada is Active with a note waiting whose version passed its checks. *)
let stages_and_clock () =
  let n = demo () in
  let log = n.Node.log in
  let module S = Store.Stages in
  let real = Unix.gettimeofday () in
  let ctx () : Api.ctx =
    {
      node = n;
      fold = Node.fold n;
      now = Unix.gettimeofday ();
      on_write = (fun () -> ());
      upkeep_waits = true;
    }
  in
  let c = session n in
  Alcotest.(check string)
    "status carries the stage" "active"
    (s "stage" (snd (call n c "status")));
  Alcotest.(check bool)
    "the clock has 24 hours" true
    (Api.clock n ~working:false = None);
  S.reset_clock ~now:(real -. 86401.) log;
  Alcotest.(check bool)
    "a work run going: the clock waits for it" true
    (Api.clock n ~working:true = None);
  let hash =
    match Api.clock n ~working:false with
    | Some ("waiting_for_approval", Ok h) -> h
    | _ -> Alcotest.fail "the clock sends Waiting for approval"
  in
  let body = Option.get (Option.get (Log.find log hash)).signed.body in
  Alcotest.(check (list string))
    "fixed words by name, nothing from the record"
    [ "status"; "voice"; "stage" ]
    (match body with `Assoc f -> List.map fst f | _ -> []);
  Alcotest.(check bool)
    "going out set the clock" false
    (S.clock_out log ~now:(Unix.gettimeofday ()));
  let item =
    List.find (fun j -> s "hash" j = hash) (list (snd (call n c "feed")))
  in
  Alcotest.(check string)
    "the Feed's muted line" "waiting_for_approval" (s "status_note" item);
  Alcotest.(check string)
    "the Feed's line has the node's fixed words (ISS-53999)"
    "No note from Ada today; it's waiting for Ada's approval."
    (s "status_note_words" item);
  let me =
    List.find
      (fun m -> member "is_self" m = `Bool true)
      (list (snd (call n c "members")))
  in
  Alcotest.(check string)
    "Members puts the words beside the time" "waiting_for_approval"
    (s "last_status_note" me);
  Alcotest.(check string)
    "and the words themselves"
    "No note from Ada today; it's waiting for Ada's approval."
    (s "last_status_note_words" me);
  (* The first row that holds decides it. *)
  let module N = Store.Notes in
  let waiting = List.hd (N.waiting log) in
  N.delete log ~note_id:waiting.n_id;
  Alcotest.(check string)
    "nothing written" "nothing_to_share"
    (Api.Stages.clock_status (ctx ()));
  ignore (Store.Problems.report log ~job:"write_version" ~kind:"signed_out" ());
  Alcotest.(check string)
    "the work run failed, with no reason" "could_not_run"
    (Api.Stages.clock_status (ctx ()));
  Store.Problems.resolve log ~job:"write_version" ();
  let id, _ =
    N.add log
      ~could_not_finish:("pii", real +. 3600.)
      ~status:"waiting" "Worked on: tests."
  in
  Alcotest.(check string)
    "a note none could read yet" "could_not_run"
    (Api.Stages.clock_status (ctx ()));
  N.delete log ~note_id:id;
  (* Onboarding sends nothing: no status note, no compose. *)
  S.set log "onboarding";
  S.reset_clock ~now:(real -. 90000.) log;
  Alcotest.(check bool)
    "Onboarding: the clock sends nothing" true
    (Api.clock n ~working:false = None);
  Alcotest.(check int)
    "Post to the circle opens at Active" 422
    (fst
       (call n c ~meth:"POST"
          ~body:(`Assoc [ ("text", `String "Hello.") ])
          "messages"));
  (* The first approved note going out makes the member Active, and carries it. *)
  let note, written =
    N.add log ~status:"waiting" "Worked on: the first note."
  in
  let vid = (List.hd written).N.v_id in
  N.approve log ~note_id:note ~version_id:vid ~status:"approved";
  Api.send_notes n;
  Alcotest.(check string) "Active" "active" (S.stage log);
  let posted = Option.get (Option.get (N.find log note)).n_posted_hash in
  Alcotest.(check string)
    "the first note carries Active" "active"
    (Content.stage_of (Option.get (Log.find log posted)).signed.body);
  Alcotest.(check int)
    "Post to the circle is open" 201
    (fst
       (call n c ~meth:"POST"
          ~body:(`Assoc [ ("text", `String "Hello.") ])
          "messages"))

(* Pause (docs/design.md, Pause). The demo's Ada is Active with a note waiting whose version passed
   its checks. *)
let pause () =
  let n = demo () in
  let log = n.Node.log in
  let module S = Store.Stages in
  let module P = Store.Pause in
  let module N = Store.Notes in
  let real = Unix.gettimeofday () in
  let day = 86400. in
  let c = session n in
  let envelopes () =
    match Log.rows log "SELECT COUNT(*) FROM envelopes" [] with
    | [ [| v |] ] -> Log.int v
    | _ -> 0
  in
  Alcotest.(check int) "not paused" 404 (fst (call n c "paused"));
  Alcotest.(check int)
    "Unpause while Active" 404
    (fst (call n c ~meth:"DELETE" "paused"));
  let waiting = List.hd (N.waiting log) in
  Alcotest.(check bool)
    "no banner while the note is new" true
    (member "pause_warning" (snd (call n c "status")) = `Null);
  (* Three days before a pause the banner names the note and when. *)
  P.set_readable_at log ~note_id:waiting.n_id (real -. (27.5 *. day));
  let w = member "pause_warning" (snd (call n c "status")) in
  Alcotest.(check string)
    "the banner names the note" waiting.n_id
    (s "id" (member "note" w));
  Alcotest.(check int)
    "waited days" 27
    (match member "waited_days" w with `Int d -> d | _ -> -1);
  Alcotest.(check bool)
    "when Digestif pauses" true
    (abs_float
       (Option.get (Time_fmt.to_unix (s "pauses_at" w))
       -. (real +. (2.5 *. day)))
    < 5.);
  (* Pause sends Paused at once, and the waiting note stays waiting. *)
  let before = envelopes () in
  let st, page = call n c ~meth:"POST" "paused" in
  Alcotest.(check int) "Pause" 201 st;
  Alcotest.(check string) "Paused" "paused" (S.stage log);
  Alcotest.(check string) "why" "pressed_pause" (s "reason" page);
  Alcotest.(check string)
    "the next note waits on the waiting one" waiting.n_id
    (s "id" (member "waiting_note" page));
  Alcotest.(check bool)
    "the note time" true
    (String.length (s "note_time" page) = 5);
  Alcotest.(check int) "one status note" (before + 1) (envelopes ());
  let me =
    List.find
      (fun m -> member "is_self" m = `Bool true)
      (list (snd (call n c "members")))
  in
  Alcotest.(check string) "the circle reads Paused" "paused" (s "stage" me);
  Alcotest.(check string) "the Paused note" "paused" (s "last_status_note" me);
  Alcotest.(check string)
    "the waiting note still waits" "waiting"
    (Option.get (N.find log waiting.n_id)).n_status;
  Alcotest.(check int) "the page" 200 (fst (call n c "paused"));
  Alcotest.(check int)
    "Pause from Paused" 422
    (fst (call n c ~meth:"POST" "paused"));
  Alcotest.(check bool)
    "no banner while Paused" true
    (member "pause_warning" (snd (call n c "status")) = `Null);
  Alcotest.(check bool)
    "the clock is stopped" true
    (S.reset_clock ~now:(real -. (2. *. day)) log;
     Api.clock n ~working:false = None);
  (* A note approved before the pause still goes out, and does not end Paused. *)
  let _ = N.add log ~status:"approved" "Worked on: the pause." in
  Api.send_notes n;
  Alcotest.(check string)
    "a note going out leaves Paused" "paused" (S.stage log);
  (* Unpause: Active at once, nothing sent, the clock a normal day. *)
  let before = envelopes () in
  Alcotest.(check int) "Unpause" 204 (fst (call n c ~meth:"DELETE" "paused"));
  Alcotest.(check string) "Active" "active" (S.stage log);
  Alcotest.(check int) "Unpause sends nothing" before (envelopes ());
  Alcotest.(check bool)
    "the clock has 24 hours" true
    (abs_float (S.clock_runs_out log -. (real +. day)) < 5.);
  Alcotest.(check bool)
    "the 30 days count from Unpause" true
    (member "pause_warning" (snd (call n c "status")) = `Null);
  Alcotest.(check int) "not paused" 404 (fst (call n c "paused"));
  (* A note waiting 30 days pauses an Active member on the next pass. *)
  P.set_readable_at log ~note_id:waiting.n_id (real -. (31. *. day));
  Log.set_config log "ui_unpaused_at"
    (Printf.sprintf "%.3f" (real -. (40. *. day)));
  (match Api.clock n ~working:true with
  | Some ("paused", Ok _) -> ()
  | _ -> Alcotest.fail "a note waiting 30 days pauses");
  Alcotest.(check string) "Paused" "paused" (S.stage log);
  Alcotest.(check string)
    "a note waited" "note_waited"
    (s "reason" (snd (call n c "paused")));
  (* Only from Active: Onboarding never pauses. *)
  ignore (P.unpause log ~now:real);
  S.set log "onboarding";
  P.set_readable_at log ~note_id:waiting.n_id (real -. (31. *. day));
  Log.set_config log "ui_unpaused_at"
    (Printf.sprintf "%.3f" (real -. (40. *. day)));
  Alcotest.(check bool)
    "Onboarding never pauses" true
    (P.due log ~now:real = None);
  Alcotest.(check int)
    "Pause while Onboarding" 422
    (fst (call n c ~meth:"POST" "paused"))

(* ISS-88004 (DES-85466, an invite takes effect): an invite every admin signed is put in front of the
   admin whose node wrote its dinner, as a local notice carrying the email to send, raised once,
   settled once marked sent, and settled by itself once the guest joined or it ran out. *)
let send_invite_notice () =
  let module Inv = Digestif_invite in
  let n = demo () in
  let c = session n in
  let log = n.Node.log in
  let now = Unix.gettimeofday () in
  let ptime t = Option.get (Ptime.of_float_s t) in
  let subject, body =
    Inv.Invite_email.template ~circle_label:"AI Dinner 2" ~host_name:"Mike"
      ~guest_name:"Priya Raman" ~message:"Come and see."
  in
  let record ?(state = Inv.Host_watch.Open) ?(hours = 72.) name =
    {
      Inv.Host_watch.dinner_hash = "sha256:dinner-" ^ name;
      guest_name = name;
      guest_email = String.lowercase_ascii name ^ "@example.com";
      invite_key = ok (Inv.Approved_invite.new_invite_key n);
      expires_at = ptime (now +. (hours *. 3600.));
      message = "";
      state;
      approved =
        Some
          {
            approval = "sha256:approval-" ^ name;
            role = "member";
            subject;
            body;
            relay = "https://relay.example";
            promotion = None;
          };
    }
  in
  let priya = record "Priya" in
  let gone = record ~hours:(-1.) "Late" in
  let own = { (record "Host") with approved = None } in
  ok (Inv.Host_watch.save n.dir [ own; priya; gone ]);
  let raise () = Digest_lines.raise_notices n ~now in
  let raised () =
    Log.rows log "SELECT COUNT(*) FROM ui_items WHERE subject = 'send_invite'"
      []
    |> function
    | [ [| x |] ] -> Log.int x
    | _ -> -1
  in
  raise ();
  let id =
    match Invite_notice.open_notices log with
    | [ (id, Some k) ] when k = priya.invite_key -> id
    | _ ->
        Alcotest.fail
          "one notice, for the signed invite still to be sent, and none for an \
           expired one or the host's own"
  in
  let status, j = call n c ("items/" ^ id) in
  Alcotest.(check int) "the notice reads" 200 status;
  Alcotest.(check string) "its title" "Send Priya's invite." (s "title" j);
  Alcotest.(check bool) "local" true (member "local" j = `Bool true);
  Alcotest.(check bool)
    "its detail names the guest" true
    (contains (s "detail" j) "priya@example.com");
  let email = member "invite_email" j in
  Alcotest.(check string)
    "to the guest" "Priya <priya@example.com>" (s "to" email);
  Alcotest.(check string) "the subject as signed" subject (s "subject" email);
  Alcotest.(check bool)
    "its install command and expiry filled in" false
    (contains (s "text" email) "{{");
  Alcotest.(check bool)
    "the install command" true
    (contains (s "text" email) "install.sh");
  Alcotest.(check bool)
    "a mailto: link" true
    (String.starts_with
       ~prefix:"mailto:Priya%20%3Cpriya%40example.com%3E?subject="
       (s "mailto" email));
  Alcotest.(check (option string))
    "the digest names nothing"
    (Some "An invite waits for you to send on your machine.")
    (Item.off_machine_title (Some "send_invite"));
  raise ();
  Alcotest.(check int) "raised once" 1 (raised ());
  (* Marked sent: settled, never raised again, and its email still shown. *)
  Alcotest.(check int)
    "marked sent" 200
    (fst (call n c ~meth:"POST" ("items/" ^ id ^ "/acknowledge")));
  raise ();
  Alcotest.(check int) "not raised again" 1 (raised ());
  let _, j = call n c ("items/" ^ id) in
  Alcotest.(check string) "settled" "acknowledged" (s "done" j);
  Alcotest.(check bool)
    "the email still shown" true
    (member "invite_email" j <> `Null);
  (* A second invite whose guest joins before it is marked sent is settled by itself. *)
  let ada = record "Ada" in
  ok (Inv.Host_watch.save n.dir [ own; priya; gone; ada ]);
  raise ();
  Alcotest.(check int) "the second invite's notice" 2 (raised ());
  let ada_id =
    match Invite_notice.open_notices log with
    | [ (id, _) ] -> id
    | _ -> Alcotest.fail "one open notice"
  in
  ok
    (Inv.Host_watch.save n.dir
       [
         own;
         priya;
         gone;
         {
           ada with
           state = Joined { identity_key = "ed25519:ada"; confirmed = true };
         };
       ]);
  raise ();
  Alcotest.(check int)
    "settled once the guest joined" 0
    (List.length (Invite_notice.open_notices log));
  let _, j = call n c ("items/" ^ ada_id) in
  Alcotest.(check string) "as resolved" "resolved" (s "done" j);
  (* An invite whose secret half the keystore lost says why it cannot show the email. *)
  ok (n.keystore.delete (Inv.Approved_invite.secret_name priya.invite_key));
  let _, j = call n c ("items/" ^ id) in
  Alcotest.(check bool) "no email" true (member "invite_email" j = `Null);
  Alcotest.(check bool)
    "why" true
    (contains (s "invite_email_problem" j) "secret half")

(* ISS-42319 (DES-37153, What the digest says without an ask): what the digest's "On your machine"
   said, each told once on its day and none naming what is on the machine; ISS-52614 makes each a
   notice from the node. *)
let digest_lines () =
  let n = demo () in
  let log = n.Node.log in
  let module S = Store.Stages in
  let module P = Store.Pause in
  let module N = Store.Notes in
  let module L = Digest_lines in
  let real = Unix.gettimeofday () in
  let day = 86400. in
  let texts () =
    List.map (fun (_, (l : L.line)) -> l.text) (L.notices log ~now:real)
  in
  (* ISS-52614: telling a line is raising its notice. *)
  let tell () = L.raise_notices n ~now:real in
  let has t = List.exists (fun l -> contains l t) (texts ()) in
  (* Start from nothing to tell. *)
  Log.exec log "DELETE FROM ui_problems" [];
  S.set log "paused";
  tell ();
  let undecided id at =
    Log.exec log
      "INSERT INTO ui_repositories (id, organization_id, name, status, \
       found_at, paths) VALUES (?, 'acme-labs', ?, 'undecided', ?, '[]')"
      Log.[ s id; s ("prototype-" ^ id); s (Time_fmt.of_unix at) ]
  in
  undecided "r1" (real -. 60.);
  Alcotest.(check bool)
    "one new repository" true
    (List.mem "1 new repository waits for you on your machine." (texts ()));
  Alcotest.(check (option string))
    "repositories point at the Repositories page"
    (Some "/settings/repositories/edit")
    (Item.notice_page "repositories");
  Alcotest.(check bool)
    "named by no line" false
    (List.exists (fun l -> contains l "prototype") (texts ()));
  tell ();
  Alcotest.(check bool) "told once" false (has "new repositor");
  undecided "r2" (real -. 30.);
  undecided "r3" (real -. 20.);
  Alcotest.(check bool)
    "only the new ones counted" true
    (List.mem "2 new repositories wait for you on your machine." (texts ()));
  tell ();
  (* A run that failed: a problem opened on a note's job, once, its kind kept here. *)
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 10.))
       ~job:"rules_check" ~kind:"model_unavailable" ());
  Alcotest.(check bool)
    "could not run" true
    (List.mem
       "Digestif could not run today. Open it on your machine to see why."
       (texts ()));
  Alcotest.(check bool)
    "the kind stays here" false
    (List.exists (fun l -> contains l "model") (texts ()));
  Alcotest.(check (option string))
    "could not run points at the Feed" (Some "/feed")
    (Item.notice_page "could_not_run");
  tell ();
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 5.))
       ~job:"rules_check" ~kind:"model_unavailable" ());
  Alcotest.(check bool)
    "the same problem, told once" false (has "could not run");
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 5.))
       ~job:"sync" ~kind:"relay_unreachable" ());
  Alcotest.(check bool) "a sync is not a note's job" false (has "could not run");
  (* The first note, while Onboarding. *)
  let waiting = List.hd (N.waiting log) in
  Log.set_config log N.k_first waiting.n_id;
  Alcotest.(check bool) "not while Paused" false (has "first note");
  S.set log "onboarding";
  Alcotest.(check bool)
    "first note ready" true
    (List.mem "Your first note is ready on your machine." (texts ()));
  tell ();
  Alcotest.(check bool) "first note, told once" false (has "first note");
  (* A note waiting while Active: each one told once, the first note's wording not used. *)
  S.set log "active";
  tell ();
  ignore (N.add log ~status:"waiting" "Worked on: the digest.");
  Alcotest.(check bool)
    "a note waits" true
    (List.mem "A note waits for you to approve on your machine." (texts ()));
  Alcotest.(check (option string))
    "a note ready points at the Feed" (Some "/feed")
    (Item.notice_page "note_ready");
  tell ();
  Alcotest.(check bool) "a note waiting, told once" false (has "to approve");
  ignore (N.add log ~status:"waiting" "Worked on: the feed.");
  ignore (N.add log ~status:"waiting" "Worked on: the inbox.");
  Alcotest.(check bool)
    "only the new ones counted" true
    (List.mem "2 notes wait for you to approve on your machine." (texts ()));
  tell ();
  S.set log "paused";
  ignore (N.add log ~status:"waiting" "Worked on: the pause.");
  Alcotest.(check bool) "none while Paused" false (has "to approve");
  S.set log "active";
  tell ();
  (* A pause coming: the day the banner first shows, once. *)
  List.iter
    (fun (w : N.note) ->
      P.set_readable_at log ~note_id:w.n_id (real -. (28. *. day)))
    (N.waiting log);
  Log.set_config log "ui_unpaused_at"
    (Printf.sprintf "%.3f" (real -. (40. *. day)));
  Alcotest.(check bool)
    "a pause coming" true
    (List.exists
       (fun l ->
         contains l "note has waited 28 days. Digestif pauses on"
         && contains l "unless it goes out.")
       (texts ()));
  Alcotest.(check (option string))
    "a pause coming points at the Feed" (Some "/feed")
    (Item.notice_page "pause_coming");
  Alcotest.(check bool)
    "Active is not paused" false (L.machine n ~now:real).paused;
  tell ();
  Alcotest.(check (list string)) "nothing left to tell" [] (texts ());
  S.set log "paused";
  Alcotest.(check bool) "Paused" true (L.machine n ~now:real).paused

(* ISS-50720: a feed row and a note's summary preview the first line after the note's section
   headings, so no note reads Worked on. *)
let previews () =
  let check what expected text =
    Alcotest.(check string) what expected (Note_preview.first_line text)
  in
  check "a heading on its own line" "Built the digest."
    "Worked on:\nBuilt the digest.\nLearned: x.";
  check "a heading without its colon" "Built the digest."
    "Worked on\n\nBuilt the digest.";
  check "a heading on the line of its text" "the digest."
    "Worked on: the digest.\nLearned: x.";
  check "the next heading when one is empty" "a cause."
    "Worked on:\n\nLearned: a cause.";
  check "a post that starts with a heading's words" "Learned a lot today."
    "Learned a lot today.";
  check "a plain line" "Hello." "Hello.\nmore";
  check "only headings" "Worked on:" "Worked on:\nLearned:";
  check "a markdown heading, its text on the next line" "Built the digest."
    "## Worked on\nBuilt the digest.";
  check "a bold heading on its own line" "Built the digest."
    "**Worked on:**\n\nBuilt the digest.";
  check "a bold heading with its colon outside" "Built the digest."
    "**Worked on**:\nBuilt the digest.";
  check "a bold heading on the line of its text, a plain heading after"
    "the digest." "**Worked on:** the digest.\nLearned: x.";
  check "a list under its heading" "- the fetcher's retry"
    "Worked on:\n- the fetcher's retry\n- the docs\nLearned: x.";
  (* ISS-53994: every heading form the nightly writer can produce. *)
  check "a markdown heading" "Built the digest."
    "## Worked on\n\nBuilt the digest.\n\n## Learned\nx.";
  check "a markdown heading with its colon" "Built the digest."
    "### Worked on:\nBuilt the digest.";
  check "a bold heading" "Built the digest." "**Worked on:**\nBuilt the digest.";
  check "a bold heading, colon outside" "Built the digest."
    "**Worked on**:\nBuilt the digest.";
  check "a bold heading on the line of its text" "the digest."
    "**Worked on:** the digest.\n**Learned:** x.";
  check "a bold heading, colon outside, on the line" "the digest."
    "**Worked on**: the digest.";
  check "a markdown bold heading" "Built the digest."
    "## **Worked on**\nBuilt the digest.";
  check "a heading in another case" "Built the digest."
    "WORKED ON:\r\nBuilt the digest.";
  check "a bold sentence that starts with a heading's words"
    "**Learned a lot today.**" "**Learned a lot today.**";
  check "a markdown heading that is a sentence" "## Learned a lot today."
    "## Learned a lot today.";
  check "a bullet" "- Built the digest." "Worked on:\n- Built the digest."

(* ISS-53994: the daily digest previews a note the way the Feed does. *)
let digest_gist () =
  let body text = Some (`Assoc [ ("text", `String text) ]) in
  Alcotest.(check string)
    "past the heading" "Built the digest."
    (Digestif_daily.Daily_digest.gist "summary"
       (body "Worked on:\n\nBuilt the digest.\nLearned: x."));
  Alcotest.(check string)
    "past a bold heading" "the digest."
    (Digestif_daily.Daily_digest.gist "summary"
       (body "**Worked on:** the digest."))

(* ISS-42315: the Paused ask (DES-37153, The Paused ask). A pause the node made raises it and
   appends it at once; Unpause on the machine closes it with its own decision; an Unpause read at
   sync unpauses as the Paused page does; a member's own Pause raises nothing. *)
let paused_ask () =
  let n = demo () in
  let log = n.Node.log in
  let module S = Store.Stages in
  let module P = Store.Pause in
  let module N = Store.Notes in
  let module D = Digestif_daily.Decisions in
  let real = Unix.gettimeofday () in
  let day = 86400. in
  let c = session n in
  let waiting = List.hd (N.waiting log) in
  let node_pauses () =
    P.set_readable_at log ~note_id:waiting.n_id (real -. (31. *. day));
    Log.set_config log "ui_unpaused_at"
      (Printf.sprintf "%.3f" (real -. (40. *. day)));
    match Api.clock n ~working:true with
    | Some ("paused", Ok _) -> ()
    | _ -> Alcotest.fail "a note waiting 30 days pauses"
  in
  node_pauses ();
  (* The run loop's pass indexes the ask the clock wrote. *)
  keep_up n;
  let a = Option.get (Asks.find log "paused") in
  Alcotest.(check (option string)) "a paused ask" (Some "paused") a.kind;
  Alcotest.(check string) "Unpause recommended" "unpause" a.recommended;
  Alcotest.(check string)
    "Stay paused with no answer" "stay_paused" a.on_no_answer;
  Alcotest.(check (option string)) "no deadline" None a.lapses_at;
  Alcotest.(check string) "its title" "Digestif paused. Unpause?" a.title;
  Alcotest.(check bool)
    "its words" true
    (contains a.detail "note waited 30 days, so Digestif paused on"
    && contains a.detail "No notes are written while it stays paused.");
  let hash = Option.get a.envelope in
  Alcotest.(check (list string))
    "the next pass mails it" [ "paused" ]
    (Digestif_daily.Daily_digest.carried n);
  (* ISS-52614: it reaches the Inbox as the node's choice, addressed to the member alone. *)
  let st, j = call n c ("items/" ^ enc hash) in
  Alcotest.(check int) "in the Inbox" 200 st;
  Alcotest.(check string) "a choice" "choice" (s "kind" j);
  Alcotest.(check string) "paused" "paused" (s "subject" j);
  Alcotest.(check string) "from the node" "node" (s "voice" j);
  Alcotest.(check string) "New" "new" (s "status" j);
  Alcotest.(check bool) "no deadline_at" true (member "deadline_at" j = `Null);
  Alcotest.(check string)
    "Stay paused with no pick" "stay_paused" (s "default_option" j);
  Alcotest.(check bool)
    "travels" false
    (Yojson.Safe.Util.to_bool (member "local" j));
  Alcotest.(check string)
    "an item envelope, not an ask" "item"
    (Option.get (Log.find log hash)).signed.envelope.kind;
  (* Unpause on the machine closes it with the ask's own Unpause decision, by the device key. *)
  Alcotest.(check int) "Unpause" 204 (fst (call n c ~meth:"DELETE" "paused"));
  let a = Option.get (Asks.find log "paused") in
  Alcotest.(check (option string)) "answered Unpause" (Some "unpause") a.answer;
  (match a.answered_via with
  | Some (Asks.Decision d) ->
      let r = Option.get (Log.find log d) in
      Alcotest.(check string) "a decision" "decision" r.signed.envelope.kind;
      Alcotest.(check string)
        "by the device key"
        (Keys.public (ok (Node.device_key n)))
        r.signed.envelope.author;
      let enc_key = ok (Node.encryption_key n) in
      Alcotest.(check (pair string string))
        "on the ask, Unpause" (hash, "unpause")
        (ok
           (Digestif_mail.Ask.decision_of_body ~priv:enc_key.secret
              (Option.get r.signed.body)))
  | _ -> Alcotest.fail "closed by its decision");
  Alcotest.(check string)
    "settled in the Inbox" "picked"
    (s "done" (snd (call n c ("items/" ^ enc hash))));
  Alcotest.(check bool) "nothing more to unpause" false (Api.settled_unpause n);
  (* The member's own Pause raises nothing, and the old answer does not unpause it. *)
  Alcotest.(check int) "Pause" 201 (fst (call n c ~meth:"POST" "paused"));
  Alcotest.(check (option string))
    "no new ask" (Some hash) (Option.get (Asks.find log "paused")).envelope;
  Alcotest.(check bool)
    "an old answer acts on nothing" false (Api.settled_unpause n);
  ignore (P.unpause log ~now:real);
  (* The node pauses again: the ask is raised again, and an Unpause answered elsewhere and read at
     sync unpauses, once. *)
  node_pauses ();
  (* The run loop's pass indexes the ask the clock wrote. *)
  keep_up n;
  let a = Option.get (Asks.find log "paused") in
  Alcotest.(check bool)
    "raised again" true
    (a.answer = None && a.envelope <> Some hash);
  let hash = Option.get a.envelope in
  Alcotest.(check int)
    "picked in the Inbox" 201
    (fst
       (call n c ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "unpause") ])
          ("items/" ^ enc hash ^ "/picks")));
  Alcotest.(check string) "still paused until it is read" "paused" (S.stage log);
  ignore (ok (D.settle n (Node.fold n) ~now:(Unix.gettimeofday () +. 1.)));
  Alcotest.(check bool) "Unpause read at sync" true (Api.settled_unpause n);
  Alcotest.(check string) "Active" "active" (S.stage log);
  Alcotest.(check bool)
    "the clock has 24 hours" true
    (abs_float (S.clock_runs_out log -. (Unix.gettimeofday () +. day)) < 5.);
  Alcotest.(check bool) "once" false (Api.settled_unpause n)

(* The reading agent skips status notes in code, and starts only at Active. *)
let reader_skips_status_notes () =
  let n = demo () in
  let log = n.Node.log in
  let module S = Store.Stages in
  let own = Node.own_keys n in
  Alcotest.(check bool) "what came in before is unread" true (S.unread log ~own);
  S.set_read_mark log (S.newest_order log);
  Alcotest.(check bool) "read" false (S.unread log ~own);
  let key = Crypto.generate_signing_key () in
  let import seq body =
    ok
      (Node.import n
         (Envelope.create ~key ~seq ~created_at:(Time_fmt.now ()) ~epoch:0
            ~kind:"summary" body))
  in
  ignore
    (import 1 (Content.status_body ~status:"nothing_to_share" ~stage:"active"));
  Alcotest.(check bool) "a status note costs no run" false (S.unread log ~own);
  ignore
    (import 2 (Content.summary_body ~text:"Worked on: x." ~voice:"agent" ()));
  Alcotest.(check bool) "a note starts one" true (S.unread log ~own);
  S.set log "paused";
  Alcotest.(check bool) "not while Paused" false (Behaviors.read_due log ~own);
  S.set log "active";
  Alcotest.(check bool) "at Active" true (Behaviors.read_due log ~own)

(* `digestif note` records the run's tick: waiting for the member, or approved by the agent and
   posted. A note is never refused: its checks already removed what the deny layer would trip on. *)
let note_ticks () =
  let n = demo () in
  let log = n.Node.log in
  let outcomes () =
    List.map
      (fun (t : Store.tick) -> Store.tick_outcome_name t.outcome)
      (Store.ticks log ~limit:10)
  in
  ignore (ok (Api.submit_note_text n "Worked on: internal.example.com."));
  ignore
    (ok (Api.submit_note_text ~approve:true n "Worked on: the tick record."));
  ignore (ok (Api.submit_note_text n "Worked on: the members page."));
  Alcotest.(check (list string))
    "newest first"
    [ "held"; "posted"; "held" ]
    (outcomes ())

let log_events n c id =
  let st, j = call n c ("notes/" ^ id ^ "/log") in
  Alcotest.(check int) "the Log reads" 200 st;
  List.map (s "event") (list j)

(* The check at signing is a backstop that should never fire: a trip refuses to sign and never
   edits, and the note returns to Waiting with the reason on its page, naming the part and what
   tripped, never the text. *)
let signing_backstop () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let note id = snd (call n c ("notes/" ^ id)) in
  let approve id =
    let v = s "id" (member "version" (note id)) in
    let st, _ =
      call n c ~meth:"POST"
        ~body:(`Assoc [ ("version_id", `String v) ])
        ("notes/" ^ id ^ "/approve")
    in
    Alcotest.(check int) "approved" 200 st;
    Api.send_notes n
  in
  let text =
    "Worked on: the fetcher.\nLearned: internal.example.com is slow."
  in
  (* Auto approved included: the agent approved it, and the send job refused to sign it. *)
  let id = ok (Api.submit_note_text ~approve:true n text) in
  Api.send_notes n;
  let m = note id in
  Alcotest.(check string) "back to Waiting" "waiting" (s "status" m);
  Alcotest.(check string)
    "the reason" "Not sent. A deny list entry matches Learned. Edit it."
    (s "not_sent" m);
  Alcotest.(check string)
    "the text is kept as it was" text
    (s "text" (member "version" m));
  Alcotest.(check (list string))
    "the Log"
    [ "written"; "auto_approved"; "signing_refused" ]
    (log_events n c id);
  (* Approving the same text is refused the same way. *)
  approve id;
  Alcotest.(check string) "still waiting" "waiting" (s "status" (note id));
  Alcotest.(check (list string))
    "refused again"
    [
      "written";
      "auto_approved";
      "signing_refused";
      "approved";
      "signing_refused";
    ]
    (log_events n c id);
  (* A detector is named by its type. *)
  let card =
    ok
      (Api.submit_note_text ~approve:true n
         "Worked on: x.\nStuck on: 4111 1111 1111 1111.")
  in
  Api.send_notes n;
  Alcotest.(check string)
    "a detector" "Not sent. A payment card number matches Stuck on. Edit it."
    (s "not_sent" (note card));
  (* A deny entry added while a note waited trips when it is sent. *)
  let waiting = ok (Api.submit_note_text n "Worked on: the Zephyr launch.") in
  ignore (Store.add_deny log ~kind:"name" ~value:"Zephyr" ());
  approve waiting;
  Alcotest.(check string) "waits" "waiting" (s "status" (note waiting));
  Alcotest.(check string)
    "with the reason" "Not sent. A deny list entry matches Worked on. Edit it."
    (s "not_sent" (note waiting));
  (* A clean note signs. *)
  let clean = ok (Api.submit_note_text n "Worked on: the docs.") in
  approve clean;
  Alcotest.(check string) "approved" "approved" (s "status" (note clean));
  Alcotest.(check bool)
    "and signed" true
    ((Option.get (Store.Notes.find log clean)).n_posted_hash <> None)

(* Edit: a new version both checks run on, which the member sees once they finish; Save & approve
   goes out only if they removed nothing; each checked edit updates Learnings once. *)
(* A note is approved on its message (ISS-47299): a waiting note is a message of the feed at its
   own id, awaiting approval, carrying its note; it lists its versions, is dismissed before
   approval and then never sent, and a sent note's message names the note it was sent as. Write a
   note now asks for the note writer's next pass. *)
let note_on_its_message () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let waiting_count () =
    match member "notes_awaiting_approval" (snd (call "status")) with
    | `Int i -> i
    | _ -> -1
  in
  let notes = list (member "notes" (snd (call "notes"))) in
  let waiting = s "id" (List.find (fun j -> s "status" j = "waiting") notes) in
  let feed () = list (snd (call "feed")) in
  let in_feed id = List.find_opt (fun j -> s "hash" j = id) (feed ()) in
  (match in_feed waiting with
  | Some j ->
      Alcotest.(check string)
        "the feed shows it awaiting approval" "awaiting_approval" (s "status" j)
  | None -> Alcotest.fail "a waiting note is not in the feed");
  let st, m = call ("messages/" ^ waiting) in
  Alcotest.(check int) "its message" 200 st;
  Alcotest.(check string) "awaiting" "awaiting_approval" (s "status" m);
  Alcotest.(check string) "names its note" waiting (s "note_id" m);
  Alcotest.(check string) "a summary" "summary" (s "kind" m);
  let st, versions = call ("notes/" ^ waiting ^ "/versions") in
  Alcotest.(check int) "its versions" 200 st;
  Alcotest.(check bool) "at least one" true (list versions <> []);
  let before = waiting_count () in
  let st, j = call ~meth:"POST" ("notes/" ^ waiting ^ "/dismiss") in
  Alcotest.(check int) "dismissed" 200 st;
  Alcotest.(check string) "its status" "dismissed" (s "status" j);
  Alcotest.(check int) "one fewer waits" (before - 1) (waiting_count ());
  Alcotest.(check int)
    "only a waiting note is dismissed" 422
    (fst (call ~meth:"POST" ("notes/" ^ waiting ^ "/dismiss")));
  Alcotest.(check bool) "gone from the feed" true (in_feed waiting = None);
  Alcotest.(check string)
    "its message says so" "dismissed"
    (s "status" (snd (call ("messages/" ^ waiting))));
  Alcotest.(check bool)
    "never sent" true
    (List.for_all
       (fun (x : Store.Notes.note) -> x.n_id <> waiting)
       (Store.Notes.unsent n.log));
  Alcotest.(check bool)
    "the Log says so" true
    (List.exists
       (fun e -> s "event" e = "dismissed")
       (list (snd (call ("notes/" ^ waiting ^ "/log")))));
  (match
     List.find_opt
       (fun (x : Store.Notes.note) -> x.n_posted_hash <> None)
       (Store.Notes.all n.log)
   with
  | Some sent ->
      let hash = Option.get sent.n_posted_hash in
      Alcotest.(check string)
        "a sent message names its note" sent.n_id
        (s "note_id" (snd (call ("messages/" ^ hash))));
      Alcotest.(check string)
        "the note's id opens the signed message" hash
        (s "hash" (snd (call ("messages/" ^ sent.n_id))))
  | None -> Alcotest.fail "the demo has no sent note");
  Store.clear_nightly_run n.log;
  Alcotest.(check int)
    "write a note now" 202
    (fst (call ~meth:"POST" "notes/runs"));
  Alcotest.(check bool)
    "the writer runs on the next pass" true
    (Store.nightly_run_requested n.log)

let note_edit () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let id = s "id" (List.hd (list (member "notes" (snd (call "notes"))))) in
  let v1 = member "version" (snd (call ("notes/" ^ id))) in
  let edit ?(approve = false) text =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String text);
             ("edited_version_id", `String (s "id" v1));
             ("approve", `Bool approve);
           ])
      ("notes/" ^ id ^ "/versions")
  in
  Alcotest.(check int) "empty" 422 (fst (edit "  "));
  Store.Notes.set_unchanged log 2;
  let st, page =
    edit ~approve:true "Worked on: the local web UI.\nLearned: embed the build."
  in
  Alcotest.(check int) "a new version" 201 st;
  Alcotest.(check int)
    "an edit restarts the count" 0
    (Store.Notes.unchanged log);
  Alcotest.(check string)
    "the page keeps the version being read" (s "id" v1)
    (s "id" (member "version" page));
  let v2 = s "newer_version_id" page in
  Alcotest.(check bool) "says a newer one exists" true (v2 <> "");
  Alcotest.(check bool)
    "nothing to approve while its checks run" true
    (member "can_approve" page = `Bool false);
  let newer =
    member "version" (snd (call ("notes/" ^ id ^ "?version=" ^ v2)))
  in
  Alcotest.(check string) "running" "running" (s "pii" (member "checks" newer));
  Alcotest.(check bool) "unseen" true (member "text" newer = `Null);
  Alcotest.(check (list string))
    "handed to the check behavior" [ v2 ]
    (List.map
       (fun (v : Store.Notes.version) -> v.v_id)
       (Store.Notes.due log ~now:(Unix.gettimeofday ())));
  (* A check that could not finish: unseen, and tried again in an hour. *)
  ok
    (Api.version_checked_text n ~version:v2
       (Api.Notes.Could_not_finish { check = "rules"; problem = "signed_out" }));
  Alcotest.(check (list string))
    "not due until the retry" []
    (List.map
       (fun (v : Store.Notes.version) -> v.v_id)
       (Store.Notes.due log ~now:(Unix.gettimeofday ())));
  (* Save & approve: the checks removed something, so it stays Waiting with why. *)
  let runs =
    {|[{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":1}]},{"check":"pii","removals":[]},{"check":"rules","removals":[]}]|}
  in
  ok
    (Api.version_checked_text ~checks:runs n ~version:v2
       (Api.Notes.Passed
          { text = "Worked on: the local web UI."; removed = true }));
  let page = snd (call ("notes/" ^ id)) in
  Alcotest.(check string) "waiting" "waiting" (s "status" page);
  Alcotest.(check string)
    "the member sees the result" "Worked on: the local web UI."
    (s "text" (member "version" page));
  Alcotest.(check string)
    "and why it did not go out"
    "Not sent. The Rules check removed 1 from your edit, in Learned. Approve \
     sends the text below."
    (s "not_sent" page);
  Alcotest.(check bool)
    "removed text is not kept" true
    ((Option.get (Store.Notes.version log v2)).submitted = None);
  Alcotest.(check bool)
    "approvable now" true
    (member "can_approve" page = `Bool true);
  (* Learnings once, from the checked diff. *)
  Alcotest.(check (list string))
    "its Learnings update is owed" [ v2 ]
    (List.map
       (fun (v : Store.Notes.version) -> v.v_id)
       (Store.Notes.due log ~now:(Unix.gettimeofday () +. 7200.)));
  ok (Api.learnings_from_edit n ~version:v2 "Keep the Learned part short.");
  Alcotest.(check string)
    "Learnings" "Keep the Learned part short."
    (s "text" (snd (call "learnings")));
  Alcotest.(check bool)
    "once" true
    (Result.is_error (Api.learnings_from_edit n ~version:v2 "again"));
  Alcotest.(check bool)
    "the Log" true
    (List.mem "learnings_updated" (log_events n c id));
  (* A second Save & approve the checks leave alone goes out. *)
  let _, page =
    edit ~approve:true "Worked on: the local web UI, and its tests."
  in
  let v3 = s "newer_version_id" page in
  ok
    (Api.version_checked_text n ~version:v3
       (Api.Notes.Passed
          {
            text = "Worked on: the local web UI, and its tests.";
            removed = false;
          }));
  let page = snd (call ("notes/" ^ id)) in
  Alcotest.(check string) "approved" "approved" (s "status" page);
  Alcotest.(check int)
    "3" 3
    (match member "number" (member "version" page) with `Int i -> i | _ -> 0);
  Alcotest.(check int)
    "an approved edit restarts the count" 0
    (Store.Notes.unchanged log);
  Alcotest.(check int)
    "a shared note has no Edit" 422
    (fst (edit "Worked on: more."));
  (* The member's own Learnings stand as they wrote them. *)
  let _, l =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("text", `String "  Mine.  ") ])
      "learnings"
  in
  Alcotest.(check string) "the member's edit" "Mine." (s "text" l)

(* Approval: off until the member saves it; turning it off restarts the suggestion's count. *)
let approval_setting () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  Alcotest.(check string)
    "off" "every_note_waits"
    (s "setting" (snd (call "settings/approval")));
  let put v =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("setting", `String v) ])
      "settings/approval"
  in
  Alcotest.(check int) "unknown" 422 (fst (put "sometimes"));
  let st, j = put "auto_approve" in
  Alcotest.(check int) "saved" 200 st;
  Alcotest.(check string) "on" "auto_approve" (s "setting" j);
  Alcotest.(check bool) "dated" true (s "updated_at" j <> "");
  Store.Notes.set_unchanged n.log 3;
  Alcotest.(check bool)
    "no suggestion while it is on" false
    (Store.Notes.suggest n.log);
  ignore (put "every_note_waits");
  Alcotest.(check int)
    "turning it off restarts the count" 0
    (Store.Notes.unchanged n.log)

(* `digestif note --checks`: what each run removed becomes the note's Log, by part and by what it
   broke; nothing but those fields is kept, and a shape that is not check runs is refused. *)
let note_log () =
  let n = demo () in
  let c = session n in
  let runs =
    {|[{"check":"pii","removals":[{"part":"Worked on","cause":"detector","detector":"API key or token","count":1,"text":"sk-leaked"}]},{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":2}]},{"check":"pii","removals":[]},{"check":"rules","removals":[]}]|}
  in
  let id = ok (Api.submit_note_text ~checks:runs n "Worked on: the docs.") in
  let _, j = call n c ("notes/" ^ id ^ "/log") in
  let entries = list j in
  Alcotest.(check (list string))
    "events"
    [ "written"; "checked"; "checked"; "checked"; "checked" ]
    (List.map (s "event") entries);
  let first = List.nth entries 1 in
  Alcotest.(check string) "check" "pii" (s "check" first);
  Alcotest.(check string)
    "a removal names part and type"
    {|[{"part":"Worked on","cause":"detector","detector":"API key or token","count":1}]|}
    (Yojson.Safe.to_string (member "removals" first));
  Alcotest.(check bool)
    "no text reaches the Log" false
    (contains (Yojson.Safe.to_string j) "sk-leaked");
  List.iter
    (fun bad ->
      Alcotest.(check bool)
        bad true
        (Result.is_error (Api.submit_note_text ~checks:bad n "Worked on: x.")))
    [
      "not json";
      {|{"check":"pii"}|};
      {|[{"check":"style","removals":[]}]|};
      {|[{"check":"pii","removals":[{"part":"Worked on","cause":"detector","count":1}]}]|};
      {|[{"check":"pii","removals":[{"part":"Worked on","cause":"person","count":0}]}]|};
      {|[{"check":"pii","removals":[{"part":"Worked on","cause":"gossip","count":1}]}]|};
    ];
  Alcotest.(check int) "an unknown note" 404 (fst (call n c "notes/nope/log"))

(* The passages a check removed are kept in the note's Log, on this node, and shown to the member
   on the note's page; a detector's removal keeps none, and nothing the node signs or queues for
   the relay carries them. *)
let note_log_passages () =
  let n = demo () in
  let c = session n in
  let runs =
    {|[{"check":"pii","removals":[{"part":"Worked on","cause":"person","count":1,"passages":["Met Jane Roe about the launch."]},{"part":"Worked on","cause":"detector","detector":"API key or token","count":1,"passages":["Rotated sk-leaked today."]}]},{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":1,"passages":["The Acme deal closes Friday."]}]},{"check":"pii","removals":[]},{"check":"rules","removals":[]}]|}
  in
  let id =
    ok
      (Api.submit_note_text ~checks:runs n
         "Worked on: the docs.\nLearned: retries.")
  in
  let _, j = call n c ("notes/" ^ id ^ "/log") in
  let entries = list j in
  let pii = List.nth entries 1 and rules = List.nth entries 2 in
  Alcotest.(check string)
    "the member sees what the PII check removed, and the detector keeps none"
    {|[{"part":"Worked on","cause":"person","count":1,"passages":["Met Jane Roe about the launch."]},{"part":"Worked on","cause":"detector","detector":"API key or token","count":1}]|}
    (Yojson.Safe.to_string (member "removals" pii));
  Alcotest.(check string)
    "and what the Rules check removed"
    {|[{"part":"Learned","cause":"rules","count":1,"passages":["The Acme deal closes Friday."]}]|}
    (Yojson.Safe.to_string (member "removals" rules));
  Alcotest.(check bool)
    "no secret reaches the Log" false
    (contains (Yojson.Safe.to_string j) "sk-leaked");
  List.iter
    (fun bad ->
      Alcotest.(check bool)
        bad true
        (Result.is_error (Api.submit_note_text ~checks:bad n "Worked on: x.")))
    [
      {|[{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":1,"passages":"one"}]}]|};
      {|[{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":1,"passages":[1]}]}]|};
      {|[{"check":"rules","removals":[{"part":"Learned","cause":"rules","count":1,"passages":[" "]}]}]|};
    ];
  (* Approved and sent: nothing signed or queued for the relay holds a passage. *)
  let v = member "version" (snd (call n c ("notes/" ^ id))) in
  Alcotest.(check int)
    "approve" 200
    (fst
       (call n c ~meth:"POST"
          ~body:(`Assoc [ ("version_id", `String (s "id" v)) ])
          ("notes/" ^ id ^ "/approve")));
  Api.send_notes n;
  let posted = Option.get (Store.Notes.find n.log id) in
  Alcotest.(check bool)
    "the note was signed" true
    (Option.bind posted.n_posted_hash (Log.find n.log) <> None);
  let outbound =
    List.concat_map
      (fun table ->
        List.concat_map
          (fun row -> Array.to_list (Array.map Log.text row))
          (Log.rows n.log ("SELECT * FROM " ^ table) []))
      [ "envelopes"; "ui_outbox" ]
  in
  List.iter
    (fun passage ->
      Alcotest.(check bool)
        ("not sent: " ^ passage) false
        (List.exists (fun v -> contains v passage) outbound))
    [ "Jane Roe"; "Acme deal"; "sk-leaked" ];
  Alcotest.(check bool)
    "the signed note is the checked text" true
    (List.exists (fun v -> contains v "Worked on: the docs.") outbound)

(* The held_reason column, which the backstop's reason rides in. *)
let held_reason_column () =
  let n = demo () in
  let log = n.Node.log in
  (* A data directory from before the column: init adds it. *)
  Log.exec log "ALTER TABLE ui_outbox DROP COLUMN held_reason" [];
  Store.init log;
  Alcotest.(check int)
    "the column is back" 1
    (List.length
       (List.filter
          (fun r -> Log.text r.(1) = "held_reason")
          (Log.rows log "PRAGMA table_info(ui_outbox)" [])))

(* ISS-42119: the feed, a member's recent list and a message's replies read one page out of the log,
   and answer exactly what reading every message and filtering it did. *)
(* DIG-225: a Feed thread, an Inbox thread and the member this node is are read by their key on the
   node, so a thread older than the Feed's first page still shows and nothing scans the circle. *)
let threads_by_key () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let hashes j = List.map (s "hash") (list j) in
  let feed = list (snd (call "feed?limit=200")) in
  let by_preview p = List.find (fun i -> contains (s "preview" i) p) feed in
  let ben_note = s "hash" (by_preview "a retry queue for the importer") in
  let ben_waiting =
    s "hash"
      (List.find
         (fun i ->
           s "status_note" i = "waiting_for_approval"
           && s "name" (member "author" i) = "Ben Ortiz")
         feed)
  in
  let thread key = call ("feed/threads/" ^ enc key) in
  let st, ben = thread ben_note in
  Alcotest.(check int) "a note's thread" 200 st;
  Alcotest.(check (list string))
    "the wait it ends, then the note, oldest first" [ ben_waiting; ben_note ]
    (hashes ben);
  Alcotest.(check string)
    "rows carry the Feed's status note" "waiting_for_approval"
    (s "status_note" (List.hd (list ben)));
  Alcotest.(check (list string))
    "the wait's key reads the note that settled it" [ ben_waiting; ben_note ]
    (hashes (snd (thread ben_waiting)));
  let question =
    s "hash"
      (by_preview
         "Has anyone tried a fake clock for timer tests? Ben is stuck on the \
          same thing.")
  in
  let _, answer =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String "Yes, a fake clock works.");
             ("reply_to", `String question);
           ])
      "messages"
  in
  let _, deeper =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String "And a frozen one for the CI runner.");
             ("reply_to", `String (s "hash" answer));
           ])
      "messages"
  in
  let _, q = thread question in
  Alcotest.(check string) "the note first" question (List.hd (hashes q));
  Alcotest.(check bool)
    "every reply under it, a reply's reply and the refused one too" true
    (List.length (list q) = 4
    && List.mem (s "hash" answer) (hashes q)
    && List.mem (s "hash" deeper) (hashes q));
  Alcotest.(check (list string))
    "a reply's key reads its note's thread" (hashes q)
    (hashes (snd (thread (s "hash" deeper))));
  (* Sixty posts push the question off the Feed's first page; its thread still reads whole. *)
  for i = 1 to 60 do
    ignore
      (call ~meth:"POST"
         ~body:(`Assoc [ ("text", `String (Printf.sprintf "Post %d." i)) ])
         "messages")
  done;
  Alcotest.(check bool)
    "off the first page" false
    (List.mem question (hashes (snd (call "feed?limit=50"))));
  Alcotest.(check (list string))
    "an old thread reads the same" (hashes q)
    (hashes (snd (thread question)));
  Alcotest.(check int)
    "a key with nothing under it" 404
    (fst (thread "sha256:00"));
  (* Who-am-I: one member, the one Members marks as this node's. *)
  let st, self = call "members/self" in
  Alcotest.(check int) "self" 200 st;
  Alcotest.(check bool) "is_self" true (member "is_self" self = `Bool true);
  Alcotest.(check string)
    "the member Members marks" (s "identity" self)
    (s "identity"
       (List.find
          (fun m -> member "is_self" m = `Bool true)
          (list (snd (call "members")))));
  Alcotest.(check bool)
    "with its devices, for Phones" true
    (list (member "devices" self) <> []);
  Alcotest.(check int)
    "an Inbox thread with no item" 0
    (List.length (list (snd (call "items/threads/nothing"))))

let feed_pages () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  (* Forty nights of Ada's summaries behind the demo, and her node's digests between them. *)
  let key = Result.get_ok (Node.device_key n) in
  let now = Unix.gettimeofday () in
  ignore
    (List.fold_left
       (fun (seq, prev) i ->
         let created_at =
           Time_fmt.of_unix (now -. (float_of_int (60 - i) *. 86400.))
         in
         let write (seq, prev) kind body =
           let sg =
             Envelope.create ~key ~seq ?prev ~created_at ~epoch:0 ~kind body
           in
           (seq + 1, Some (Node.store n sg))
         in
         let position =
           write (seq, prev) "digest" (`Assoc [ ("date", `String created_at) ])
         in
         write position "summary"
           (Content.summary_body ~voice:"agent" ~stage:"active"
              ~text:(Printf.sprintf "Night %d." i)
              ()))
       (Node.next_position n key) (List.init 40 Fun.id));
  let hashes l = List.map (s "hash") (list l) in
  let fold = Node.fold n in
  (* What the feed was before it paged: every message the fold believes, our refused rows and our
     notes not yet signed, newest first. *)
  let whole =
    List.map
      (fun (r : Log.row) ->
        (r.signed.envelope.created_at, r.hash, r.signed.envelope.author))
      (View.feed ~kinds:Content.feed_kinds n.log fold)
    @ List.filter_map
        (fun (o : Store.outbound) ->
          if o.status = "refused" then Some (o.o_created_at, o.o_id, "")
          else None)
        (Store.outbox n.log)
    @ List.map
        (fun (x : Store.Notes.note) -> (x.written_at, x.n_id, "note"))
        (Store.Notes.in_feed n.log ~limit:200)
    |> List.stable_sort (fun (a, _, _) (b, _, _) -> compare b a)
  in
  Alcotest.(check bool)
    "the summaries are in the feed" true
    (List.length whole > 40);
  Alcotest.(check (list string))
    "one page holds what the whole read did"
    (List.map (fun (_, h, _) -> h) whole)
    (hashes (snd (call "feed?limit=200")));
  (* Pages of seven, each before the last one's oldest, walk the same list. *)
  let rec walk before acc =
    let page =
      list
        (snd
           (call
              ("feed?limit=7"
              ^ match before with Some b -> "&before=" ^ enc b | None -> "")))
    in
    match List.rev page with
    | [] -> List.rev acc
    | oldest :: _ ->
        walk
          (Some (s "created_at" oldest))
          (List.rev_append (List.map (s "hash") page) acc)
  in
  Alcotest.(check (list string))
    "paged by before"
    (List.map (fun (_, h, _) -> h) whole)
    (walk None []);
  (* Ada's recent list is her twenty newest, read by her keys. *)
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let mine =
    List.filter
      (fun (_, _, author) ->
        author = "" || Fold.identity_of fold author = Some me)
      whole
  in
  Alcotest.(check (list string))
    "a member's recent list"
    (List.filteri (fun i _ -> i < 20) (List.map (fun (_, h, _) -> h) mine))
    (hashes (member "recent" (snd (call ("members/" ^ enc me)))));
  (* Her last note is her newest summary in the agent's voice, as reading every summary found it. *)
  let newest_note =
    Log.of_kind n.log "summary"
    |> List.filter (fun (r : Log.row) ->
        Fold.identity_of fold r.signed.envelope.author = Some me
        && Option.map Content.voice_of r.signed.body = Some "agent")
    |> List.fold_left
         (fun at (r : Log.row) -> max at r.signed.envelope.created_at)
         ""
  in
  Alcotest.(check string)
    "her last note" newest_note
    (s "last_note_at" (snd (call ("members/" ^ enc me))))

(* A log from before envelopes kept reply_to: opening it fills the column from the bodies, so a
   message's replies are found by the index. *)
let reply_to_backfill () =
  let n = demo () in
  let c = session n in
  let _, feed = call n c "feed" in
  let question =
    List.find
      (fun i -> String.starts_with ~prefix:"Has anyone tried" (s "preview" i))
      (list feed)
  in
  let _, answer =
    call n c ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String "Yes, a fake clock works.");
             ("reply_to", `String (s "hash" question));
           ])
      "messages"
  in
  let replies log =
    List.map
      (fun (r : Log.row) -> r.hash)
      (Log.replies log ~kinds:Content.feed_kinds (s "hash" question))
  in
  Alcotest.(check (list string))
    "the answer is a reply"
    [ s "hash" answer ]
    (replies n.log);
  Log.exec n.log "DROP INDEX envelopes_reply_to" [];
  Log.exec n.log "ALTER TABLE envelopes DROP COLUMN reply_to" [];
  let reopened = Log.open_ (Node.log_path n.dir) in
  Alcotest.(check (list string))
    "found again once the column is filled"
    [ s "hash" answer ]
    (replies reopened)

(* `digestif post` runs the deny layer on a summary a behavior hands it, and signs no kind the
   protocol does not name: a question to the circle is an item, never a directed envelope. *)
let post_deny () =
  let n = demo () in
  let log = n.Node.log in
  let refused_rows () =
    List.filter
      (fun (o : Store.outbound) -> o.status = "refused")
      (Store.outbox log)
  in
  let before = List.length (refused_rows ()) in
  let post kind body = Api.post_body n ~kind body in
  let signed = function Ok h -> Log.find log h <> None | Error _ -> false in
  let refused = function
    | Error (Api.Refused rule) -> rule
    | Ok _ -> "signed"
    | Error (Api.Failed e) -> "failed: " ^ e
  in
  Alcotest.(check bool)
    "a clean summary signs" true
    (signed
       (post "summary"
          (Content.summary_body ~text:"Worked on: tests." ~voice:"agent" ())));
  Alcotest.(check string)
    "a summary that trips" "deny: domain"
    (refused
       (post "summary"
          (Content.summary_body ~text:"notes at internal.example.com"
             ~voice:"agent" ())));
  List.iter
    (fun kind ->
      Alcotest.(check string)
        (kind ^ " is no kind any more")
        ("failed: " ^ kind ^ " is not a kind the protocol names")
        (refused
           (post kind
              (`Assoc [ ("to", `String "ed25519:x"); ("text", `String "hi") ]))))
    [ "question"; "answer"; "proposal"; "ask" ];
  let refusals = refused_rows () in
  Alcotest.(check int)
    "every refusal is kept" (before + 1) (List.length refusals);
  Alcotest.(check bool)
    "no refused text is kept" true
    (List.for_all (fun (o : Store.outbound) -> o.o_text = None) refusals)

(* Quiet hours on the Rules page, and what a behavior reads of them. *)
let quiet_hours_api () =
  let n = demo () in
  let c = session n in
  let put body = call n c ~meth:"PUT" ~body "rules/quiet_hours" in
  let span a b = `Assoc [ ("start", `String a); ("end", `String b) ] in
  Alcotest.(check int) "none yet" 404 (fst (call n c "rules/quiet_hours"));
  Alcotest.(check bool)
    "no quiet hours on the rules" true
    (member "quiet_hours" (snd (call n c "rules")) = `Null);
  let st, j = put (span "7pm" "07:00") in
  Alcotest.(check int) "a bad start" 422 st;
  Alcotest.(check string) "names start" "start" (s "field" (List.hd (list j)));
  Alcotest.(check int)
    "the same start and end" 422
    (fst (put (span "07:00" "07:00")));
  let st, j = put (span "22:00" "07:00") in
  Alcotest.(check int) "saved" 200 st;
  Alcotest.(check string) "start" "22:00" (s "start" j);
  Alcotest.(check string) "end" "07:00" (s "end" j);
  let q = member "quiet_hours" (snd (call n c "rules")) in
  Alcotest.(check string) "on the rules" "22:00" (s "start" q);
  (* A span holding right now says when it ends. *)
  let g = Unix.localtime (Unix.gettimeofday ()) in
  let m = (g.tm_hour * 60) + g.tm_min in
  let hhmm m =
    let m = (m + 1440) mod 1440 in
    Printf.sprintf "%02d:%02d" (m / 60) (m mod 60)
  in
  let _, j = put (span (hhmm (m - 30)) (hhmm (m + 30))) in
  Alcotest.(check bool) "active" true (member "active" j = `Bool true);
  Alcotest.(check bool) "ends_at" true (s "ends_at" j <> "");
  let _, j = put (span (hhmm (m + 60)) (hhmm (m + 120))) in
  Alcotest.(check bool) "not active" true (member "active" j = `Bool false);
  Alcotest.(check bool) "no ends_at" true (member "ends_at" j = `Null);
  Alcotest.(check int)
    "cleared" 204
    (fst (call n c ~meth:"DELETE" "rules/quiet_hours"));
  Alcotest.(check int) "gone" 404 (fst (call n c "rules/quiet_hours"))

(* One problem record (docs/design.md, One way a failure is reported): the same job and kind add to
   one open problem, the job's next success closes it, a source's problem is that source's, and the
   list puts the open ones first. *)
let problem_record () =
  let n = demo () in
  let c = session n in
  let log = n.Node.log in
  let module P = Store.Problems in
  let a =
    P.report log ~at:"2026-11-01T03:27:00Z" ~job:"write_version"
      ~kind:"signed_out" ()
  in
  let b =
    P.report log ~at:"2026-11-01T04:27:00Z" ~job:"write_version"
      ~kind:"signed_out" ()
  in
  Alcotest.(check string) "the same open problem" a.p_id b.p_id;
  Alcotest.(check int) "counted" 2 b.count;
  Alcotest.(check string) "first seen" "2026-11-01T03:27:00Z" b.first_seen_at;
  Alcotest.(check string) "last seen" "2026-11-01T04:27:00Z" b.last_seen_at;
  let other = P.report log ~job:"write_version" ~kind:"model_unavailable" () in
  Alcotest.(check bool)
    "another kind is another problem" true (other.p_id <> a.p_id);
  let git = P.report log ~job:"source" ~kind:"source_failed" ~source:"Git" () in
  ignore (P.report log ~job:"source" ~kind:"source_failed" ~source:"Athena" ());
  Alcotest.(check bool) "a source is its own" true (git.p_source = Some "Git");
  Alcotest.(check bool) "no detail unless told" true (git.p_detail = None);
  let overran =
    P.report log ~job:"source" ~kind:"source_failed" ~source:"Git"
      ~detail:"past its share of the deadline reading ~/code/big" ()
  in
  Alcotest.(check (option string))
    "the detail says where"
    (Some "past its share of the deadline reading ~/code/big") overran.p_detail;
  Alcotest.(check string)
    "the sentence names it"
    "Git could not be read: past its share of the deadline reading ~/code/big."
    (Api.Problems.sentence overran);
  let kept =
    P.report log ~job:"source" ~kind:"source_failed" ~source:"Git" ()
  in
  Alcotest.(check (option string))
    "a report with none keeps the last"
    (Some "past its share of the deadline reading ~/code/big") kept.p_detail;
  P.resolve log ~job:"source" ~source:"Git" ();
  Alcotest.(check (list string))
    "one source read: the other stays open" [ "Athena" ]
    (List.filter_map
       (fun (p : P.problem) -> if p.job = "source" then p.p_source else None)
       (P.open_ log));
  P.resolve log ~job:"write_version" ();
  Alcotest.(check bool)
    "the job's success closes both kinds" false
    (List.exists (fun (p : P.problem) -> p.job = "write_version") (P.open_ log));
  let again = P.report log ~job:"write_version" ~kind:"signed_out" () in
  Alcotest.(check bool)
    "a new failure opens a new one" true (again.p_id <> a.p_id);
  Alcotest.(check int) "counted from one" 1 again.count;
  Alcotest.check_raises "an unknown kind"
    (Invalid_argument "problem kind: oops") (fun () ->
      ignore (P.report log ~job:"sync" ~kind:"oops" ()));
  let st, j = call n c "problems?open=true" in
  Alcotest.(check int) "listed" 200 st;
  Alcotest.(check (list string))
    "open only"
    [ "write_version"; "source" ]
    (List.map (s "job") (list j));
  let first = List.hd (list j) in
  Alcotest.(check string) "its kind" "signed_out" (s "kind" first);
  Alcotest.(check bool) "not closed" true (member "closed_at" first = `Null);
  let _, all = call n c "problems" in
  Alcotest.(check int) "every problem" 5 (List.length (list all));
  Alcotest.(check bool)
    "open first" true
    (member "closed_at" (List.nth (list all) 1) = `Null
    && member "closed_at" (List.nth (list all) 2) <> `Null)

(* A check that cannot finish on what the agent wrote leaves that version unseen and unapproved: the
   note is kept, its Log says the run could not finish and when it retries, the check's problem is
   open, and the check behavior is handed the version again in an hour, never the writing. *)
let check_could_not_finish () =
  let n = demo () in
  let c = session n in
  let log = n.Node.log in
  let module N = Store.Notes in
  N.set_approval log "auto_approve";
  let id =
    ok
      (Api.submit_note_text ~approve:true
         ~could_not_finish:("rules", "signed_out") n "Shipped the importer.")
  in
  let note = Option.get (N.find log id) in
  Alcotest.(check string) "not approved" "waiting" note.n_status;
  let v = List.hd (N.versions log ~note_id:id) in
  Alcotest.(check bool) "unchecked" false (N.passed v);
  Alcotest.(check bool) "nobody reads it" true (v.v_text = None);
  let _, page = call n c ("notes/" ^ id) in
  Alcotest.(check bool)
    "no version on the page" true
    (member "version" page = `Null);
  let _, entries = call n c ("notes/" ^ id ^ "/log") in
  (match List.rev (list entries) with
  | last :: _ ->
      Alcotest.(check string) "the Log" "could_not_finish" (s "event" last);
      Alcotest.(check string) "why" "signed_out" (s "problem" last);
      Alcotest.(check bool)
        "when it retries" true
        (member "retry_at" last <> `Null)
  | [] -> Alcotest.fail "a Log");
  let open_jobs () =
    List.map
      (fun (p : Store.Problems.problem) -> (p.job, p.kind))
      (Store.Problems.open_ log)
  in
  Alcotest.(check bool)
    "the check's problem" true
    (List.mem ("rules_check", "signed_out") (open_jobs ()));
  let now = Unix.gettimeofday () in
  Alcotest.(check bool) "not due within the hour" true (N.due log ~now = []);
  Alcotest.(check (list string))
    "due an hour on" [ v.v_id ]
    (List.map (fun (x : N.version) -> x.v_id) (N.due log ~now:(now +. 3601.)));
  ok
    (Api.version_checked_text ~approve:true n ~version:v.v_id
       (Api.Notes.Passed { text = "Shipped the importer."; removed = false }));
  let note = Option.get (N.find log id) in
  Alcotest.(check string) "the agent approves it" "auto_approved" note.n_status;
  Alcotest.(check bool)
    "the problem closed" false
    (List.exists (fun (j, _) -> j = "rules_check") (open_jobs ()));
  (* Emptied by its checks, an unread note is not written. *)
  let id2 =
    ok
      (Api.submit_note_text
         ~could_not_finish:("pii", "model_unavailable")
         n "Paid the invoice.")
  in
  Alcotest.(check bool)
    "model unavailable" true
    (List.mem ("pii_check", "model_unavailable") (open_jobs ()));
  let v2 = List.hd (N.versions log ~note_id:id2) in
  ok
    (Api.version_checked_text n ~version:v2.v_id
       (Api.Notes.Passed { text = ""; removed = true }));
  Alcotest.(check bool) "no note" true (N.find log id2 = None);
  (* A check the agent's budget stopped is out of budget, on a member's edit as on a note. *)
  let id3 =
    ok
      (Api.submit_note_text ~could_not_finish:("pii", "out_of_budget") n
         "Fixed the fetcher.")
  in
  Alcotest.(check bool)
    "out of budget" true
    (List.mem ("pii_check", "out_of_budget") (open_jobs ()));
  let v3 = List.hd (N.versions log ~note_id:id3) in
  let _, entries = call n c ("notes/" ^ id3 ^ "/log") in
  (match List.rev (list entries) with
  | last :: _ ->
      Alcotest.(check string) "why" "out_of_budget" (s "problem" last)
  | [] -> Alcotest.fail "a Log");
  ok
    (Api.version_checked_text n ~version:v3.v_id
       (Api.Notes.Could_not_finish
          { check = "rules"; problem = "out_of_budget" }));
  Alcotest.(check bool)
    "the Rules check too" true
    (List.mem ("rules_check", "out_of_budget") (open_jobs ()))

let reset () =
  let n = demo () in
  let c = session n in
  ignore
    (call n c ~meth:"PUT" ~body:(`Assoc [ ("selected", `List []) ]) "sources");
  let reset_with body =
    Server.handler
      ~reset:(fun seed ->
        Result.map
          (fun member -> ok (Demo.seed ~member n))
          (Demo.seed_of_string (Option.value seed ~default:"active")))
      n
      (request ~meth:"POST"
         ~headers:[ ("cookie", c); ("digestif-local", "1") ]
         ~body "/api/v0/_reset")
  in
  Alcotest.(check int) "reset" 204 (reset_with "").status;
  Alcotest.(check int) "same session" 200 (fst (call n c "status"));
  Alcotest.(check int)
    "an unknown seed" 422 (reset_with {|{"seed":"nobody"}|}).status;
  Alcotest.(check int)
    "no reset outside a demo" 404
    (fst (call n c ~meth:"POST" "_reset"))

(* The demo's new member (Demo.New_member): the same circle, with Ada just joined. Setup has not
   started, nothing of hers has gone out, and the app is the first note's page; the seeded Ada's
   approved notes are ones that went out, so the send job has nothing of hers to sign. *)
let demo_new_member () =
  let n = demo () in
  let c = session n in
  Alcotest.(check int)
    "every approved note of the seed has gone out" 0
    (List.length (Store.Notes.unsent n.log));
  ok (Demo.seed ~member:Demo.New_member n);
  Alcotest.(check (option string))
    "setup starts at names" (Some "names")
    (Option.map Store.Setup.item_name (Store.Setup.next n.log));
  Alcotest.(check int) "no notes" 0 (List.length (Store.Notes.all n.log));
  Alcotest.(check string) "onboarding" "onboarding" (Store.Stages.stage n.log);
  let st = snd (call n c "status") in
  Alcotest.(check bool)
    "the first note's page, with no navigation" true
    (member "first_run" st = `Bool true);
  Alcotest.(check bool) "no first note yet" true (member "first_note" st = `Null)

(* Behaviors: the nightly one is due once per local date at the member's Note time, and a spawned
   behavior is handed its context on stdin and a session that ends with it. *)

let local_time ~day ~hour ~min =
  fst
    (Unix.mktime
       {
         Unix.tm_year = 126;
         tm_mon = 9;
         tm_mday = day;
         tm_hour = hour;
         tm_min = min;
         tm_sec = 0;
         tm_wday = 0;
         tm_yday = 0;
         tm_isdst = false;
       })

let nightly_due () =
  let armed = local_time ~day:28 ~hour:12 ~min:0 in
  let due ?last_date ?(armed_since = armed) ?(note_time = (3, 17)) ~day ~hour
      ~min () =
    Behaviors.nightly_due_at ~note_time ~last_date ~armed_since
      ~now:(local_time ~day ~hour ~min)
  in
  let check name want got = Alcotest.(check bool) name want got in
  check "before Note time" false (due ~day:29 ~hour:3 ~min:16 ());
  check "at Note time" true (due ~day:29 ~hour:3 ~min:17 ());
  check "an evening Note time: not in the morning" false
    (due ~note_time:(18, 30) ~day:29 ~hour:9 ~min:0 ());
  check "an evening Note time: at it" true
    (due ~note_time:(18, 30) ~day:29 ~hour:18 ~min:30 ());
  check "before 3:00" false
    (due ~last_date:"2026-10-28" ~day:29 ~hour:1 ~min:0 ());
  check "a closed laptop wakes at noon" true
    (due ~last_date:"2026-10-28" ~day:29 ~hour:12 ~min:0 ());
  check "already ran today" false
    (due ~last_date:"2026-10-29" ~day:29 ~hour:23 ~min:59 ());
  let set_up_at_10pm = local_time ~day:29 ~hour:22 ~min:0 in
  check "set up after the slot: not owed tonight" false
    (due ~armed_since:set_up_at_10pm ~day:29 ~hour:22 ~min:1 ());
  check "set up after the slot: still not owed before the next one" false
    (due ~armed_since:set_up_at_10pm ~day:30 ~hour:3 ~min:16 ());
  check "set up after the slot: due at the next one" true
    (due ~armed_since:set_up_at_10pm ~day:30 ~hour:3 ~min:17 ());
  check "set up after the slot, laptop closed through the next: due on wake"
    true
    (due ~armed_since:set_up_at_10pm ~day:30 ~hour:9 ~min:0 ())

(* The record (DES-37265, The record and where each note starts): approval moves each source to
   where the note ended, a waiting or refused note moves nothing, and a source with no point
   starts at the 24 hours before it was approved, once the first note is approved. *)
let record_points () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let module R = Store.Record in
  let key = R.source_key "claude-code" in
  let start ?(now_ms = 10_000_000_000) k = R.start n.log ~now_ms k in
  R.observe n.log ~now_ms:5_000_000_000 [ key ];
  Alcotest.(check (option int)) "first note: no start" None (start key).start_ms;
  R.set_ends n.log ~note_id:"n1"
    [ (key, { R.at_ms = 6_000_000_000; sha = None }) ];
  Alcotest.(check (option int))
    "a waiting note moves nothing" None (start key).start_ms;
  R.forget n.log ~note_id:"n1";
  R.approve n.log ~note_id:"n1";
  Alcotest.(check bool)
    "a refused note's ends are gone" true
    (R.point n.log key = None);
  Alcotest.(check bool) "but the first note is over" false (R.first_note n.log);
  Alcotest.(check (option int))
    "no point: the 24 hours before it was approved"
    (Some (5_000_000_000 - 86_400_000))
    (start key).start_ms;
  let repo = R.repository_key "github.com/a/b" in
  R.set_ends n.log ~note_id:"n2"
    [
      (key, { R.at_ms = 7_000_000_000; sha = None });
      (repo, { R.at_ms = 6_500_000_000; sha = Some "abc123" });
    ];
  R.approve n.log ~note_id:"n2";
  let st = start repo in
  Alcotest.(check (option int))
    "approved: its end" (Some 6_500_000_000) st.start_ms;
  Alcotest.(check (option string))
    "with the commit" (Some "abc123") st.start_sha;
  Alcotest.(check bool) "recorded" true st.recorded;
  Alcotest.(check (option int))
    "never seen approved: the 24 hours before now"
    (Some (10_000_000_000 - 86_400_000))
    (start (R.author_key "Ada@Example.com ")).start_ms;
  Alcotest.(check string)
    "an author's key is its email, case aside" "author:ada@example.com"
    (R.author_key "Ada@Example.com ")

(* `digestif note --ends`: a note the member must approve moves the record when it is approved; one
   the agent approves moves it at once. *)
let note_ends () =
  let n = demo () in
  let key = Store.Record.source_key "claude-code" in
  let ends at =
    ok
      (Api.parse_ends
         (Printf.sprintf {|{ "source:claude-code": { "at": "%s" } }|} at))
  in
  let at_ms at = int_of_float (Option.get (Time_fmt.to_unix at) *. 1000.) in
  let point () =
    Option.map
      (fun (p : Store.Record.point) -> p.at_ms)
      (Store.Record.point n.log key)
  in
  Alcotest.(check bool)
    "not --ends" true
    (Result.is_error (Api.parse_ends {|{ "x": { "sha": "a" } }|}));
  let waiting =
    ok
      (Api.submit_note_text
         ~ends:(ends "2026-10-29T03:00:00.000Z")
         n "Worked on: the record.")
  in
  Alcotest.(check (option int)) "waiting: nothing moves" None (point ());
  let c = session n in
  let v = s "id" (member "version" (snd (call n c ("notes/" ^ waiting)))) in
  Alcotest.(check int)
    "approve" 200
    (fst
       (call n c ~meth:"POST"
          ~body:(`Assoc [ ("version_id", `String v) ])
          ("notes/" ^ waiting ^ "/approve")));
  Alcotest.(check (option int))
    "approved: its end"
    (Some (at_ms "2026-10-29T03:00:00.000Z"))
    (point ());
  ignore
    (ok
       (Api.submit_note_text ~approve:true
          ~ends:(ends "2026-10-30T03:00:00.000Z")
          n "Worked on: the next note."));
  Alcotest.(check (option int))
    "auto approved: its end at once"
    (Some (at_ms "2026-10-30T03:00:00.000Z"))
    (point ())

(* DIG-133: `digestif note --revise` gives a note still waiting for its member the agent's revised
   version, with its own ends: approving it moves each source to where its record ends, approving
   the first version moves them to the first's. A note approved, edited or written in two versions
   is not revised. *)
let note_revise () =
  let n = demo () in
  let c = session n in
  let key = Store.Record.source_key "command-changelog" in
  let ends at =
    ok (Api.parse_ends (Printf.sprintf {|{ "%s": { "at": "%s" } }|} key at))
  in
  let at_ms at = int_of_float (Option.get (Time_fmt.to_unix at) *. 1000.) in
  let point () =
    Option.map
      (fun (p : Store.Record.point) -> p.at_ms)
      (Store.Record.point n.log key)
  in
  let approve note v =
    Alcotest.(check int)
      "approve" 200
      (fst
         (call n c ~meth:"POST"
            ~body:(`Assoc [ ("version_id", `String v) ])
            ("notes/" ^ note ^ "/approve")))
  in
  let note =
    ok
      (Api.submit_note_text
         ~ends:(ends "2026-10-29T03:00:00.000Z")
         n "Worked on: the fetcher.")
  in
  Alcotest.(check bool)
    "a revision is never approved by the agent" true
    (Result.is_error (Api.submit_note_text ~revise:note ~approve:true n "x"));
  Alcotest.(check string)
    "the same note" note
    (ok
       (Api.submit_note_text ~revise:note
          ~ends:(ends "2026-10-29T03:40:00.000Z")
          n "Worked on: the fetcher. Released 1.2."));
  let vs = Store.Notes.versions n.log ~note_id:note in
  Alcotest.(check (list (pair int string)))
    "the agent's second version"
    [ (1, "agent"); (2, "agent") ]
    (List.map (fun (v : Store.Notes.version) -> (v.number, v.v_voice)) vs);
  let v2 = List.nth vs 1 in
  Alcotest.(check string)
    "the page shows the revision" v2.v_id
    (s "id" (member "version" (snd (call n c ("notes/" ^ note)))));
  approve note v2.v_id;
  Alcotest.(check (option int))
    "approved: the revision's end"
    (Some (at_ms "2026-10-29T03:40:00.000Z"))
    (point ());
  Alcotest.(check bool)
    "an approved note is not revised" true
    (Result.is_error (Api.submit_note_text ~revise:note n "Worked on: more."));
  (* The member edits the first version after the revision and approves the edit: the first's
     ends, since its record is the one the edit was written from. *)
  let note =
    ok
      (Api.submit_note_text
         ~ends:(ends "2026-10-30T03:00:00.000Z")
         n "Worked on: the docs.")
  in
  ignore
    (ok
       (Api.submit_note_text ~revise:note
          ~ends:(ends "2026-10-30T03:40:00.000Z")
          n "Worked on: the docs. Released 1.3."));
  let first = List.hd (Store.Notes.versions n.log ~note_id:note) in
  let edit =
    Store.Notes.add_edit n.log ~note_id:note ~edited:first.v_id ~approve:false
      "Worked on: the docs, all of them."
  in
  Store.Notes.checked n.log edit.v_id ~text:"Worked on: the docs, all of them."
    ~removed:false;
  approve note edit.v_id;
  Alcotest.(check (option int))
    "an edit of the first approved: the first's end"
    (Some (at_ms "2026-10-30T03:00:00.000Z"))
    (point ());
  (* The member's edit, and a pair, are theirs: no revision passes over them. *)
  let note = ok (Api.submit_note_text n "Worked on: the tests.") in
  let v1 = List.hd (Store.Notes.versions n.log ~note_id:note) in
  ignore
    (Store.Notes.add_edit n.log ~note_id:note ~edited:v1.v_id ~approve:false
       "Worked on: the tests, all of them.");
  Alcotest.(check bool)
    "an edited note is not revised" true
    (Result.is_error (Api.submit_note_text ~revise:note n "Worked on: more."));
  let pair =
    {|{ "suggestion": "sha256:s", "prompt": "sha256:p", "text": "Worked on: B.", "checks": [] }|}
  in
  let note =
    ok (Api.submit_note_text ~prompt:"sha256:q" ~pair n "Worked on: A.")
  in
  Alcotest.(check bool)
    "a pair is not revised" true
    (Result.is_error (Api.submit_note_text ~revise:note n "Worked on: more."))

(* A member with no card reads as the name their invite gave them, not as a key. *)
let invited_names () =
  let n = demo () in
  let c =
    {
      Api.node = n;
      fold = Node.fold n;
      now = Unix.gettimeofday ();
      on_write = ignore;
      upkeep_waits = true;
    }
  in
  let identity name =
    Hashtbl.fold
      (fun id ((k : Bodies.card), _) acc ->
        if k.card_name = name then Some id else acc)
      c.fold.cards None
    |> Option.get
  in
  Alcotest.(check (option string))
    "a guest's name from the dinner that admitted them" (Some "Ben Ortiz")
    (Api.invited_name c (identity "Ben Ortiz"));
  Alcotest.(check (option string))
    "the host was no one's guest" None
    (Api.invited_name c (identity "Ada Park"));
  let ben = identity "Ben Ortiz" and ada = identity "Ada Park" in
  Hashtbl.reset c.fold.cards;
  let name id =
    Yojson.Safe.Util.(Api.member_ref c id |> member "name" |> to_string)
  in
  Alcotest.(check string) "no card: the invited name" "Ben Ortiz" (name ben);
  Alcotest.(check bool)
    "no card and no invite: a short key" true
    (String.starts_with ~prefix:"Member " (name ada))

let script dir body =
  let p = Filename.concat dir "behavior.sh" in
  Out_channel.with_open_gen [ Open_creat; Open_trunc; Open_wronly ] 0o700 p
    (fun oc -> output_string oc ("#!/bin/sh\n" ^ body));
  p

(* A behavior test's work run scans nothing: the machine under test is not the member's. *)
let no_scan ~now:_ _ = ()

let behavior_node () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  Store.set_offered n.log
    [
      {
        Store.id = "git";
        kind = "git";
        label = "Git repositories";
        paths = [ "/src/a" ];
        yields = [ "Commit subjects from the last day" ];
        selected = false;
      };
      {
        Store.id = "claude-code";
        kind = "claude_code";
        label = "Claude Code sessions";
        paths = [ "/claude" ];
        yields = [ "Session titles from the last day" ];
        selected = false;
      };
    ];
  Store.select_sources n.log [ "git" ];
  Store.Settings.set_note_time n.log "03:00";
  n

let note_time_setting () =
  let n = behavior_node () in
  Alcotest.(check (pair int int)) "saved" (3, 0) (Behaviors.note_time n.log);
  Log.exec n.log "DELETE FROM config WHERE key = ?"
    [ Log.s Store.Settings.k_note_time ];
  Alcotest.(check (pair int int))
    "none saved: the default" (7, 0)
    (Behaviors.note_time n.log)

(* ISS-65250: setup sets both hooks, and a node with no read hook gets it from its current release,
   unless the member unset it. *)
let behavior_install () =
  let n = behavior_node () in
  let module L = Digestif_update.Layout in
  let install h = Behaviors.install ~dir:n.dir n.log h in
  Alcotest.(check bool)
    "no release: not set, and said why" true
    (match install Read with Some (Error _) -> true | _ -> false);
  Alcotest.(check (option string))
    "still unset" None
    (Behaviors.executable n.log Read);
  let bin = Filename.concat (L.behaviors_in (L.release_dir n.dir "r1")) "bin" in
  Node.mkdir_p bin;
  List.iter
    (fun f ->
      let p = Filename.concat bin f in
      Out_channel.with_open_bin p (fun oc -> output_string oc "#!/bin/sh\n");
      Unix.chmod p 0o755)
    [ "nightly-hook"; "read-hook" ];
  L.point_current n.dir "r1";
  let launcher f =
    Filename.concat (L.behaviors_in (L.current_link n.dir)) ("bin/" ^ f)
  in
  (* A fresh setup. *)
  List.iter
    (fun (h, f) ->
      Alcotest.(check bool)
        ("set " ^ f) true
        (install h = Some (Ok (launcher f)));
      Alcotest.(check (option string))
        ("runs " ^ f)
        (Some (launcher f))
        (Behaviors.executable n.log h))
    [ (Nightly, "nightly-hook"); (Read, "read-hook") ];
  Alcotest.(check bool) "set once" true (install Read = None);
  (* A node set up before setup set the read hook: its nightly stays the member's. *)
  let mine = script n.dir "exit 0\n" in
  ok (Behaviors.set_executable n.log Nightly mine);
  Behaviors.unset_executable n.log Read;
  Alcotest.(check bool) "the member's unset stands" true (install Read = None);
  ok (Behaviors.set_executable n.log Read mine);
  Log.unset_config n.log (Store.k_behavior "read");
  Alcotest.(check bool)
    "upgraded with read unset" true
    (install Read = Some (Ok (launcher "read-hook")));
  Alcotest.(check bool) "nightly untouched" true (install Nightly = None);
  Alcotest.(check (option string))
    "the member's nightly" (Some mine)
    (Behaviors.executable n.log Nightly)

let behavior_spawn () =
  let n = behavior_node () in
  let out = Filename.concat n.dir "seen" in
  let exe =
    script n.dir
      (Printf.sprintf
         "cat > %s.json\n\
          printf '%%s %%s' \"$DIGESTIF_HOME\" \"$DIGESTIF_HOOK\" > %s.env\n\
          echo hello from the behavior\n"
         out out)
  in
  Alcotest.(check bool)
    "a relative path is refused" true
    (Result.is_error (Behaviors.set_executable n.log Nightly "behavior.sh"));
  ok (Behaviors.set_executable n.log Nightly exe);
  let now = local_time ~day:29 ~hour:4 ~min:0 in
  Alcotest.(check bool)
    "armed after the slot: nothing tonight" false
    (Behaviors.nightly_due n.log ~now);
  Log.set_config n.log Behaviors.k_armed_since
    (Printf.sprintf "%.0f" (local_time ~day:28 ~hour:12 ~min:0));
  let scanned = ref [] in
  let t =
    Behaviors.create ~digestif:"/bin/digestif" ~api_url:"http://127.0.0.1:7420"
      ~scan:(fun ~now _ -> scanned := now :: !scanned)
      n
  in
  Alcotest.(check bool)
    "nothing new, no read behavior" true
    (Behaviors.after_pass ~now t ~stored:3 |> List.map fst = [ Nightly ]);
  Alcotest.(check (list (float 0.)))
    "the work run scans the machine first (ISS-42314)" [ now ] !scanned;
  Alcotest.(check bool)
    "running once" true
    (Behaviors.after_pass ~now t ~stored:0 = []);
  (match Behaviors.wait_all ~clock:(fun () -> now) t with
  | [ f ] -> Alcotest.(check string) "exit" "exited 0" f.status
  | _ -> Alcotest.fail "one behavior finished");
  Alcotest.(check bool)
    "once per local date" false
    (Behaviors.nightly_due n.log ~now:(now +. 3600.));
  Alcotest.(check bool)
    "due the next day" true
    (Behaviors.nightly_due n.log ~now:(now +. 86400.));
  let ctx =
    Yojson.Safe.from_file (out ^ ".json") |> Yojson.Safe.Util.to_assoc
  in
  let str k = Yojson.Safe.Util.to_string (List.assoc k ctx) in
  Alcotest.(check string) "hook" "nightly" (str "hook");
  Alcotest.(check string) "local date" "2026-10-29" (str "local_date");
  Alcotest.(check string) "data dir" n.dir (str "data_dir");
  Alcotest.(check string) "digestif" "/bin/digestif" (str "digestif");
  let sources = Yojson.Safe.Util.(List.assoc "sources" ctx |> to_list) in
  Alcotest.(check (list string))
    "only the chosen sources" [ "git" ]
    (List.map Yojson.Safe.Util.(fun s -> member "id" s |> to_string) sources);
  Alcotest.(check bool)
    "no note approved: the first note" true
    Yojson.Safe.Util.(List.assoc "first_note" ctx |> to_bool);
  let repos =
    Yojson.Safe.Util.(List.hd sources |> member "repositories" |> to_list)
  in
  Alcotest.(check (list string))
    "no scan yet: the git source's own paths, each a repository" [ "/src/a" ]
    (List.map Yojson.Safe.Util.(fun r -> member "id" r |> to_string) repos);
  Alcotest.(check bool)
    "the first note's reach: no start" true
    Yojson.Safe.Util.(List.hd repos |> member "start" = `Null);
  Alcotest.(check bool)
    "no authors proposed yet: every author" true
    Yojson.Safe.Util.(List.hd sources |> member "authors" = `Null);
  let api = List.assoc "api" ctx in
  let cookie =
    Yojson.Safe.Util.(api |> member "headers" |> member "Cookie" |> to_string)
  in
  let token =
    let i = String.index cookie '=' in
    String.sub cookie (i + 1) (String.length cookie - i - 1)
  in
  Alcotest.(check bool)
    "the session ends with the behavior" false
    (Store.session_valid n.log token);
  Alcotest.(check string)
    "environment" (n.dir ^ " nightly")
    (In_channel.with_open_bin (out ^ ".env") In_channel.input_all);
  let log =
    In_channel.with_open_bin (Behaviors.log_path t Nightly) In_channel.input_all
  in
  Alcotest.(check bool)
    "output in the log" true
    (contains log "hello from the behavior");
  Alcotest.(check bool)
    "context file gone" false
    (Sys.file_exists (Filename.concat (Behaviors.dir t) "nightly.context.json"))

let behavior_deadline () =
  let n = behavior_node () in
  ok (Behaviors.set_executable n.log Read (script n.dir "exec sleep 60\n"));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let now = Unix.gettimeofday () in
  (* An Active member, and a note from another member not read yet. *)
  Store.Stages.set n.log "active";
  ignore
    (ok
       (Node.import n
          (Envelope.create
             ~key:(Crypto.generate_signing_key ())
             ~seq:1 ~created_at:(Time_fmt.now ()) ~epoch:0 ~kind:"summary"
             (Content.summary_body ~text:"Worked on: x." ~voice:"agent" ()))));
  Alcotest.(check bool)
    "read spawns after new envelopes" true
    (Behaviors.after_pass ~now t ~stored:1 |> List.map fst = [ Behaviors.Read ]);
  Alcotest.(check bool) "nothing finished" true (Behaviors.reap ~now t = []);
  Alcotest.(check bool)
    "a sleep past the deadline is a pause, not time spent" true
    (Behaviors.reap ~now:(now +. Behaviors.timeout Read +. 1.) t = []
    && Behaviors.busy t);
  (* Awake: the run loop reaps every few seconds. The run ended by SIGTERM can be collected by any
     reap after it, so every reap's finished runs are kept, and the case's clock is the only one
     read: a loaded machine changes when the child dies, never what the case sees. ISS-42348 *)
  let awake = ref (now +. Behaviors.timeout Read +. 1.) in
  let until = !awake +. Behaviors.timeout Read +. 5. in
  let finished = ref [] in
  while !awake < until do
    awake := !awake +. 5.;
    finished := !finished @ Behaviors.reap ~now:!awake t
  done;
  match !finished @ Behaviors.wait_all ~clock:(fun () -> !awake) t with
  | [ f ] -> Alcotest.(check string) "ended" "killed by SIGTERM" f.status
  | _ -> Alcotest.fail "one behavior finished"

(* DIG-119: a behavior's exit is seen by the watch thread, not by the run loop's next reap, which a
   long pass holds back: a read run that exited a second in is timed at a second, however late the
   reap that settles it. *)
let behavior_exit_watched () =
  let n = behavior_node () in
  ok (Behaviors.set_executable n.log Read (script n.dir "exit 1\n"));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let now = Unix.gettimeofday () in
  Store.Stages.set n.log "active";
  ignore
    (ok
       (Node.import n
          (Envelope.create
             ~key:(Crypto.generate_signing_key ())
             ~seq:1 ~created_at:(Time_fmt.now ()) ~epoch:0 ~kind:"summary"
             (Content.summary_body ~text:"Worked on: x." ~voice:"agent" ()))));
  Alcotest.(check bool)
    "read spawns" true
    (Behaviors.after_pass ~now t ~stored:1 |> List.map fst = [ Behaviors.Read ]);
  let stop = Atomic.make false in
  let watcher =
    Behaviors.watch ~every:0.02 t ~stop:(fun () -> Atomic.get stop)
  in
  let seen () =
    Behaviors.locked t (fun () ->
        List.for_all (fun (r : Behaviors.running) -> r.exited <> None) t.running)
  in
  let deadline = Unix.gettimeofday () +. 30. in
  while (not (seen ())) && Unix.gettimeofday () < deadline do
    Unix.sleepf 0.02
  done;
  Atomic.set stop true;
  Thread.join watcher;
  Alcotest.(check bool) "the watch saw it exit" true (seen ());
  (* The pass that was running all along ends now, two minutes on, and its reap settles the run. *)
  match Behaviors.reap ~now:(now +. 120.) t with
  | [ f ] ->
      Alcotest.(check string) "status" "exited 1" f.status;
      Alcotest.(check bool)
        (Printf.sprintf "timed at its exit, not the reap (%.1fs)" f.seconds)
        true (f.seconds < 30.);
      Alcotest.(check bool) "settled" false (Behaviors.busy t)
  | _ -> Alcotest.fail "one behavior finished"

(* DIG-294: a read run that exits 3 left messages past its batch. It is a success, and the read is
   due again on the next pass though nothing new arrived; the run spawned then clears it, and a run
   that exits 0 leaves nothing due. *)
let behavior_read_left_more () =
  let n = behavior_node () in
  let exit_code = Filename.concat n.dir "exit-code" in
  let write_exit c =
    Out_channel.with_open_bin exit_code (fun oc -> output_string oc c)
  in
  write_exit "3";
  ok
    (Behaviors.set_executable n.log Read
       (script n.dir (Printf.sprintf "exit $(cat %s)\n" exit_code)));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let now = Unix.gettimeofday () in
  Store.Stages.set n.log "active";
  ignore
    (ok
       (Node.import n
          (Envelope.create
             ~key:(Crypto.generate_signing_key ())
             ~seq:1 ~created_at:(Time_fmt.now ()) ~epoch:0 ~kind:"summary"
             (Content.summary_body ~text:"Worked on: x." ~voice:"agent" ()))));
  let pass () = Behaviors.after_pass ~now t ~stored:0 |> List.map fst in
  let finish () =
    match Behaviors.wait_all t with
    | [ f ] -> f.status
    | _ -> Alcotest.fail "one behavior finished"
  in
  Alcotest.(check bool) "a new note spawns a read" true (pass () = [ Read ]);
  Alcotest.(check string) "it left more" "exited 3" (finish ());
  Alcotest.(check bool)
    "a success: no read_circle problem" true
    (List.for_all
       (fun (p : Store.Problems.problem) -> p.job <> "read_circle")
       (Store.Problems.open_ n.log));
  Alcotest.(check bool)
    "nothing new arrived, and the next pass reads again" true
    (pass () = [ Read ]);
  write_exit "0";
  Alcotest.(check string) "that run left nothing" "exited 0" (finish ());
  Alcotest.(check bool) "nothing is due" true (pass () = []);
  Alcotest.(check bool)
    "a success for behavior run" true
    (Behaviors.succeeded Read "exited 3"
    && not (Behaviors.succeeded Nightly "exited 3"))

(* A nightly run that fails leaves its local date due, so the next pass tries again, up to three
   runs a date; after the third the date is over and the failure says why. A run that exits 0 ends
   the date. ISS-36640 *)
let behavior_retry () =
  let n = behavior_node () in
  let exit_code = Filename.concat n.dir "exit-code" in
  let write_exit c =
    Out_channel.with_open_bin exit_code (fun oc -> output_string oc c)
  in
  write_exit "1";
  ok
    (Behaviors.set_executable n.log Nightly
       (script n.dir (Printf.sprintf "exit $(cat %s)\n" exit_code)));
  Log.set_config n.log Behaviors.k_armed_since
    (Printf.sprintf "%.0f" (local_time ~day:28 ~hour:12 ~min:0));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let failure () =
    List.find_map
      (fun (p : Store.Problems.problem) ->
        if p.job = "write_version" then Some (p.kind, p.count) else None)
      (Store.Problems.open_ n.log)
  in
  let pass_at now =
    Alcotest.(check bool)
      "spawned" true
      (Behaviors.after_pass ~now t ~stored:0 |> List.map fst = [ Nightly ]);
    match Behaviors.wait_all ~clock:(fun () -> now) t with
    | [ f ] -> f.status
    | _ -> Alcotest.fail "one behavior finished"
  in
  let at min = local_time ~day:29 ~hour:4 ~min in
  Alcotest.(check string) "first run fails" "exited 1" (pass_at (at 0));
  Alcotest.(check bool)
    "still due: the next pass tries again" true
    (Behaviors.nightly_due n.log ~now:(at 5));
  Alcotest.(check bool)
    "each failed run is a problem in writing" true
    (failure () = Some ("failed", 1));
  Alcotest.(check string) "second run fails" "exited 1" (pass_at (at 5));
  Alcotest.(check bool)
    "still due" true
    (Behaviors.nightly_due n.log ~now:(at 10));
  Alcotest.(check string) "third run fails" "exited 1" (pass_at (at 10));
  Alcotest.(check bool)
    "three runs: the date is over" false
    (Behaviors.nightly_due n.log ~now:(at 15));
  Alcotest.(check bool)
    "one open problem, counted three times" true
    (failure () = Some ("failed", 3));
  Alcotest.(check bool)
    "due the next day" true
    (Behaviors.nightly_due n.log ~now:(local_time ~day:30 ~hour:4 ~min:0));
  (* The next date: a failure, then a run that exits 0 ends it. *)
  let next min = local_time ~day:30 ~hour:4 ~min in
  Alcotest.(check string) "fails" "exited 1" (pass_at (next 0));
  write_exit "0";
  Alcotest.(check string) "then handles the date" "exited 0" (pass_at (next 5));
  Alcotest.(check bool)
    "handled: not due again" false
    (Behaviors.nightly_due n.log ~now:(next 10));
  Alcotest.(check int)
    "the failures are forgotten" 0
    (Behaviors.failures n.log ~date:"2026-10-30");
  (* DIG-371: a run its agent's usage limit held exits 4: no try of the date, which stays due. *)
  let held min = local_time ~day:31 ~hour:4 ~min in
  let before = failure () in
  write_exit "4";
  List.iter
    (fun min ->
      Alcotest.(check string)
        "held by the usage limit" "exited 4"
        (pass_at (held min)))
    [ 0; 5; 10; 15 ];
  Alcotest.(check int)
    "no run counted" 0
    (Behaviors.failures n.log ~date:"2026-10-31");
  Alcotest.(check bool)
    "still due after more than three" true
    (Behaviors.nightly_due n.log ~now:(held 20));
  Alcotest.(check bool)
    "the node adds no problem of its own" true
    (failure () = before);
  write_exit "0";
  Alcotest.(check string) "the reset: it runs" "exited 0" (pass_at (held 20));
  Alcotest.(check bool)
    "handled" false
    (Behaviors.nightly_due n.log ~now:(held 25));
  (* Writing a note is the job's success: the problem closes. *)
  ignore (ok (Api.submit_note_text n "A note."));
  Alcotest.(check bool) "a written note closes it" true (failure () = None)

(* ISS-48141: the first note goes through the nightly's catch-up. Starting it reopens the nightly
   even when today's note was written, and it is due all of that day until a run handles it: a run
   the node's stopping ended is not a failed try, and the node's next pass runs it again. Its page
   says nothing is writing it rather than the step the run stopped at. *)
(* ISS-85467: a read run that reported a problem of its own while it ran, its agent's run failed,
   exits 0 so its batch is read again; that report stands. A run that reported nothing and exits 0
   closes the streak; one that did not exit 0 and said nothing is reported in the member's words. *)
let behavior_read_settle () =
  let n = behavior_node () in
  let log = n.log in
  let open_ () =
    List.filter
      (fun (p : Store.Problems.problem) -> p.job = "read_circle")
      (Store.Problems.open_ log)
  in
  let now = Unix.gettimeofday () in
  let run started : Behaviors.running =
    {
      hook = Read;
      pid = 0;
      started;
      date = "2026-11-13";
      session = None;
      awake = 0.;
      seen = started;
      terminated = None;
      exited = None;
    }
  in
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (now +. 1.))
       ~job:"read_circle" ~kind:"signed_out" ());
  Behaviors.settle_read ~now:(now +. 2.) log (run now) "exited 0";
  Alcotest.(check int) "the run's own report stands" 1 (List.length (open_ ()));
  Behaviors.settle_read ~now:(now +. 20.) log (run (now +. 10.)) "exited 0";
  Alcotest.(check int) "a run that read closes it" 0 (List.length (open_ ()));
  Behaviors.settle_read ~now:(now +. 40.) log
    (run (now +. 30.))
    "killed by SIGTERM";
  match open_ () with
  | [ p ] ->
      Alcotest.(check string) "failed" "failed" p.kind;
      Alcotest.(check (option string))
        "in the member's words"
        (Some "The run went past its deadline and was ended.") p.p_detail
  | l -> Alcotest.failf "one problem, got %d" (List.length l)

let behavior_stopped_first_note () =
  let n = behavior_node () in
  ok (Behaviors.set_executable n.log Nightly (script n.dir "exec sleep 30\n"));
  let c = session n in
  (* Today's note (Note time 03:00) was written and its date handled; the chat starts the first
     note in the evening, armed long after the slot. *)
  let now = Unix.gettimeofday () in
  Log.set_config n.log Behaviors.k_armed_since (Printf.sprintf "%.0f" now);
  Behaviors.handle_date n.log (Behaviors.local_date now);
  Alcotest.(check bool) "nothing owed" false (Behaviors.nightly_due n.log ~now);
  Store.Setup.start_first_note n.log;
  Store.clear_nightly_run n.log;
  Alcotest.(check bool)
    "starting it reopens the nightly" true
    (Behaviors.nightly_due n.log ~now);
  let id = Option.get (Store.Notes.first_id n.log) in
  let state () =
    s "state" (member "progress" (snd (call n c ("notes/" ^ id))))
  in
  let spawned t now =
    Behaviors.after_pass ~now t ~stored:0 |> List.map fst = [ Nightly ]
  in
  let stop t =
    let pid = (List.hd t.Behaviors.running).pid in
    Behaviors.stop_all t;
    ignore (Unix.waitpid [] pid)
  in
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  Alcotest.(check bool) "spawned" true (spawned t now);
  Alcotest.(check string) "its run is writing" "writing" (state ());
  let dir = Filename.concat n.dir "behaviors/nightly" in
  Node.mkdir_p dir;
  Out_channel.with_open_bin (Filename.concat dir "progress.json") (fun oc ->
      output_string oc {|{"step":"reading","sources":["Git repositories"]}|});
  stop t;
  Alcotest.(check string) "stopped: no reading step" "stopped" (state ());
  Alcotest.(check int)
    "not a failed try" 0
    (Behaviors.failures n.log ~date:(Behaviors.local_date now));
  Alcotest.(check bool)
    "still owed" true
    (Behaviors.nightly_due n.log ~now:(now +. 60.));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  Alcotest.(check bool)
    "the node's next pass runs it again" true
    (spawned t (now +. 60.));
  Alcotest.(check string) "writing again" "writing" (state ());
  Alcotest.(check bool)
    "once" true
    (Behaviors.after_pass ~now:(now +. 65.) t ~stored:0 = []);
  (* This run hands the note over before the node stops: nothing is owed. *)
  ignore (ok (Api.submit_note_text n "Worked on: the docs."));
  stop t;
  Alcotest.(check bool)
    "handed over: not run again" false
    (Behaviors.first_note_due n.log ~now:(now +. 120.))

(* A run asked for now that cannot start is refused, and one that comes to be unable to start
   lapses at the next pass: it neither keeps the daemon passing every few seconds nor fires later,
   unasked, once what held it clears. DIG-212 *)
let behavior_run_now_lapses () =
  let n = behavior_node () in
  ok (Behaviors.set_executable n.log Nightly (script n.dir "exec sleep 30\n"));
  let c = session n in
  let now = Unix.gettimeofday () in
  Log.set_config n.log Behaviors.k_armed_since (Printf.sprintf "%.0f" now);
  Behaviors.handle_date n.log (Behaviors.local_date now);
  Alcotest.(check bool) "nothing owed" false (Behaviors.nightly_due n.log ~now);
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let run_now () =
    let status, e = call n c ~meth:"POST" "notes/runs" in
    (status, if status = 202 then "" else s "code" (List.hd (list e)))
  in
  let requested () = Store.nightly_run_requested n.log in
  let lapses why =
    Store.request_nightly_run n.log;
    Alcotest.(check bool)
      (why ^ ": the daemon does not pass for it")
      false
      (Behaviors.nightly_run_wanted t);
    Alcotest.(check bool)
      (why ^ ": nothing runs") true
      (Behaviors.after_pass ~now t ~stored:0 = []);
    Alcotest.(check bool) (why ^ ": the request lapses") false (requested ())
  in
  let id = ok (Api.submit_note_text n "Worked on: the fetcher.") in
  Alcotest.(check (pair int string))
    "a note waits: refused" (422, "note_waiting") (run_now ());
  Alcotest.(check bool) "not asked for" false (requested ());
  lapses "a note waits";
  Alcotest.(check bool) "dismissed" true (Store.Notes.dismiss n.log ~note_id:id);
  Store.Stages.set n.log "paused";
  Alcotest.(check (pair int string))
    "paused: refused" (422, "paused") (run_now ());
  lapses "paused";
  Store.Stages.set n.log "active";
  Alcotest.(check (pair int string)) "accepted" (202, "") (run_now ());
  Alcotest.(check bool)
    "the daemon passes for it" true
    (Behaviors.nightly_run_wanted t);
  Alcotest.(check bool)
    "the pass runs it" true
    (Behaviors.after_pass ~now t ~stored:0 |> List.map fst = [ Nightly ]);
  Alcotest.(check bool) "started: no longer asked for" false (requested ());
  Alcotest.(check (pair int string))
    "a run is writing: refused" (422, "running") (run_now ());
  lapses "a run is writing";
  let pid = (List.hd t.Behaviors.running).pid in
  Behaviors.stop_all t;
  ignore (Unix.waitpid [] pid)

(* A note is written once and waits: while one waits, note time writes nothing. An edit's checks
   are the check hook's, the nightly behavior's own program run with DIGESTIF_HOOK=check, handed
   each due edit with the version it edited; handing it over holds the next try off an hour. *)
let behavior_check () =
  let n = behavior_node () in
  let out = Filename.concat n.dir "seen" in
  let exe =
    script n.dir
      (Printf.sprintf
         "cat > %s.json\nprintf '%%s' \"$DIGESTIF_HOOK\" > %s.env\n" out out)
  in
  ok (Behaviors.set_executable n.log Nightly exe);
  Log.set_config n.log Behaviors.k_armed_since
    (Printf.sprintf "%.0f" (local_time ~day:28 ~hour:12 ~min:0));
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let now = local_time ~day:29 ~hour:4 ~min:0 in
  let id = ok (Api.submit_note_text n "Worked on: the fetcher.") in
  Alcotest.(check bool) "due" true (Behaviors.nightly_due n.log ~now);
  Alcotest.(check bool)
    "but a note waits: nothing is written" true
    (Behaviors.after_pass ~now t ~stored:0 = []);
  let v1 = List.hd (Store.Notes.versions n.log ~note_id:id) in
  let v2 =
    Store.Notes.add_edit n.log ~note_id:id ~edited:v1.v_id ~approve:false
      "Worked on: the fetcher, and its tests."
  in
  Alcotest.(check bool)
    "the edit's checks" true
    (List.map fst (Behaviors.after_pass ~now t ~stored:0) = [ Check ]);
  ignore (Behaviors.wait_all ~clock:(fun () -> now) t);
  Alcotest.(check string)
    "the nightly's program as the check hook" "check"
    (In_channel.with_open_bin (out ^ ".env") In_channel.input_all);
  let ctx =
    Yojson.Safe.from_string
      (In_channel.with_open_bin (out ^ ".json") In_channel.input_all)
  in
  let edit = List.hd (list (member "edits" ctx)) in
  Alcotest.(check string) "the version" v2.v_id (s "id" edit);
  Alcotest.(check string)
    "its words" "Worked on: the fetcher, and its tests." (s "text" edit);
  Alcotest.(check string)
    "and the text it edited" "Worked on: the fetcher." (s "edited_text" edit);
  Alcotest.(check bool)
    "handed: not again within the hour" true
    (Behaviors.after_pass ~now:(now +. 60.) t ~stored:0 = []);
  Alcotest.(check bool)
    "an hour on, again" true
    (List.map fst (Behaviors.after_pass ~now:(now +. 3601.) t ~stored:0)
    = [ Check ]);
  ignore (Behaviors.wait_all ~clock:(fun () -> now) t)

(* DIG-133: a nightly run that hands over a note that waits while a command source it could not
   read stays failed keeps a source retry: within the hour, every ten minutes, the nightly's
   program runs as the revise hook, handed the note and the sources. The retry ends once the
   sources read, the note no longer waits as the agent wrote it, or the hour is out. *)
let behavior_revise () =
  let n = behavior_node () in
  let log = n.log in
  let out = Filename.concat n.dir "seen" in
  ok
    (Behaviors.set_executable log Nightly
       (script n.dir
          (Printf.sprintf
             "cat > %s.json\nprintf '%%s' \"$DIGESTIF_HOOK\" > %s.env\n" out out)));
  Store.add_command_source log ~id:"command-changelog" ~label:"Changelog"
    ~command:[ "/bin/false" ];
  Store.select_sources log [ "command-changelog" ];
  let t = Behaviors.create ~digestif:"/bin/digestif" ~scan:no_scan n in
  let now = Unix.gettimeofday () in
  let run : Behaviors.running =
    {
      hook = Nightly;
      pid = 0;
      started = now -. 5.;
      date = Behaviors.local_date now;
      session = None;
      awake = 0.;
      seen = now;
      terminated = None;
      exited = None;
    }
  in
  let fail_source () =
    ignore
      (Store.Problems.report log ~job:"source" ~kind:"source_failed"
         ~source:"Changelog" ())
  in
  let settle () =
    Behaviors.settle_nightly ~now ~say:ignore log run "exited 0"
  in
  let spawned at = List.map fst (Behaviors.after_pass ~now:at t ~stored:0) in
  let note = ok (Api.submit_note_text n "Worked on: the fetcher.") in
  settle ();
  Alcotest.(check bool)
    "every source read: no retry" true
    (Store.Revise.get log = None);
  fail_source ();
  settle ();
  Alcotest.(check bool)
    "a source failed: a retry" true
    (Store.Revise.get log <> None);
  Alcotest.(check bool) "not at once" true (spawned now = []);
  Alcotest.(check bool)
    "ten minutes on: the revise hook" true
    (spawned (now +. 601.) = [ Behaviors.Revise ]);
  ignore (Behaviors.wait_all ~clock:(fun () -> now +. 601.) t);
  Alcotest.(check string)
    "the nightly's program" "revise"
    (In_channel.with_open_bin (out ^ ".env") In_channel.input_all);
  let ctx =
    Yojson.Safe.from_string
      (In_channel.with_open_bin (out ^ ".json") In_channel.input_all)
  in
  Alcotest.(check string) "hook" "revise" (s "hook" ctx);
  Alcotest.(check string) "the note" note (s "note_id" (member "revise" ctx));
  Alcotest.(check (list string))
    "the sources it waits on" [ "Changelog" ]
    (List.map Yojson.Safe.Util.to_string
       (list (member "sources" (member "revise" ctx))));
  Alcotest.(check bool)
    "not again for ten minutes" true
    (spawned (now +. 700.) = []);
  Alcotest.(check bool)
    "then again" true
    (spawned (now +. 1202.) = [ Behaviors.Revise ]);
  ignore (Behaviors.wait_all ~clock:(fun () -> now +. 1202.) t);
  Store.Problems.resolve log ~job:"source" ~source:"Changelog" ();
  Alcotest.(check bool)
    "the source read: no more" true
    (spawned (now +. 1803.) = []);
  Alcotest.(check bool) "the retry is over" true (Store.Revise.get log = None);
  (* The hour runs out. *)
  fail_source ();
  settle ();
  Alcotest.(check bool)
    "past the hour: nothing" true
    (spawned (now +. 3601.) = []);
  Alcotest.(check bool) "and over" true (Store.Revise.get log = None);
  (* The member edits the note: theirs, not revised. *)
  settle ();
  let v1 = List.hd (Store.Notes.versions log ~note_id:note) in
  ignore
    (Store.Notes.add_edit log ~note_id:note ~edited:v1.v_id ~approve:false
       "Worked on: the fetcher, and its tests.");
  Alcotest.(check bool)
    "an edited note: no revise" true
    (not (List.mem Behaviors.Revise (spawned (now +. 601.))));
  Alcotest.(check bool) "over" true (Store.Revise.get log = None);
  ignore (Behaviors.wait_all ~clock:(fun () -> now +. 601.) t)

(* Command sources (docs/behaviors.md, Command sources): added through the API, kept across a
   rediscovery, run with --since appended, bounded, and removed. *)
let script dir name body =
  let p = Filename.concat dir name in
  Out_channel.with_open_gen [ Open_creat; Open_trunc; Open_wronly ] 0o755 p
    (fun oc -> output_string oc ("#!/bin/sh\n" ^ body ^ "\n"));
  p

let command_sources () =
  let n = demo () in
  let c = session n in
  let dir = tmpdir () in
  let good =
    script dir "activity"
      "echo 'digestif: item opened: Command sources'\necho\necho \"args: $*\""
  in
  let broken = script dir "broken" "echo partial; exit 3" in
  let add label command =
    call n c ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("label", `String label);
             ("command", `List (List.map (fun a -> `String a) command));
           ])
      "sources"
  in
  let ids j = List.map (s "id") (list j) in
  let st, j = add "Athena" [ "activity" ] in
  Alcotest.(check int) "a relative program" 422 st;
  Alcotest.(check string)
    "names command" "command"
    (s "field" (List.hd (list j)));
  Alcotest.(check int) "no label" 422 (fst (add " " [ good ]));
  Alcotest.(check int) "a directory" 422 (fst (add "Dir" [ dir ]));
  let st, j = add "Athena" [ good; "--project"; "digestif" ] in
  Alcotest.(check int) "added" 201 st;
  let athena = List.find (fun x -> s "id" x = "command-athena") (list j) in
  Alcotest.(check string) "kind" "command" (s "kind" athena);
  Alcotest.(check bool)
    "unselected" true
    (member "selected" athena = `Bool false);
  Alcotest.(check int) "a taken label" 422 (fst (add "athena" [ good ]));
  let st, j = add "Broken" [ broken ] in
  Alcotest.(check int) "a program that fails its test is not saved" 422 st;
  Alcotest.(check bool)
    "names the exit" true
    (contains (s "message" (List.hd (list j))) "exit 3");
  Store.add_command_source n.log ~id:"command-broken" ~label:"Broken"
    ~command:[ broken ];
  Alcotest.(check bool)
    "a rediscovery keeps it" true
    (List.mem "command-athena" (ids (snd (call n c "sources"))));
  let now = Unix.gettimeofday () in
  let since = Time_fmt.of_unix_local (now -. 86400.0) in
  let chosen =
    List.filter
      (fun (x : Store.source) -> String.starts_with ~prefix:"command-" x.id)
      (Store.sources n.log)
  in
  let extracted, failures = Sources.extract_with_failures ~now chosen in
  Alcotest.(check (list string))
    "one line per item, labelled, with --since appended"
    [
      "Athena: digestif: item opened: Command sources";
      "Athena: args: --project digestif --since " ^ since;
    ]
    extracted;
  Alcotest.(check (list string))
    "a non-zero exit is named" [ "Broken exited 3" ] failures;
  let slow = script dir "slow" "sleep 5" in
  (match
     Sources.command_lines ~timeout:0.3 ~since:now ~label:"Slow" [ slow ]
   with
  | Error e ->
      Alcotest.(check bool) "timed out" true (contains e "still running")
  | Ok _ -> Alcotest.fail "a hung program is ended");
  let long =
    script dir "long"
      "i=0; while [ $i -lt 250 ]; do echo \"line $i $(printf '%01100d' 0)\"; \
       i=$((i+1)); done"
  in
  (match Sources.command_lines ~since:now ~label:"Long" [ long ] with
  | Ok l ->
      Alcotest.(check int)
        "lines capped" Sources.max_command_lines (List.length l);
      Alcotest.(check bool)
        "each line clipped" true
        (List.for_all
           (fun x -> String.length x <= Sources.max_line_chars + 3)
           l)
  | Error e -> Alcotest.fail e);
  Alcotest.(check string)
    "id" "command-athena-notes"
    (Sources.command_id "Athena  Notes!");
  Alcotest.(check int)
    "a discovered source stays" 422
    (fst (call n c ~meth:"DELETE" "sources/git"));
  let st, j = call n c ~meth:"DELETE" "sources/command-athena" in
  Alcotest.(check int) "removed" 200 st;
  Alcotest.(check bool) "gone" false (List.mem "command-athena" (ids j));
  Alcotest.(check int)
    "unknown" 404
    (fst (call n c ~meth:"DELETE" "sources/command-athena"))

(* Draft for me (docs/behaviors.md, The writer): the writer, told the task, drafts a brief from the
   card and the chosen sources; nothing is saved, and with no writer there is no draft. *)
let brief_draft () =
  let n = demo () in
  let c = session n in
  let dir = tmpdir () in
  let writer = Filename.concat dir "writer" in
  Out_channel.with_open_gen [ Open_creat; Open_trunc; Open_wronly ] 0o755 writer
    (fun oc ->
      output_string oc "#!/bin/sh\necho \"task: $DIGESTIF_WRITER_TASK\"\ncat\n");
  let saved = Store.brief n.log in
  Sources.unset_writer n.log;
  Unix.putenv "DIGESTIF_WRITER" "";
  Alcotest.(check bool)
    "no writer, no drafting" true
    (member "can_draft" (snd (call n c "brief")) = `Bool false);
  Alcotest.(check int) "refused" 422 (fst (call n c ~meth:"POST" "brief/draft"));
  Unix.putenv "DIGESTIF_WRITER" writer;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "DIGESTIF_WRITER" "")
    (fun () ->
      Alcotest.(check bool)
        "a writer, drafting" true
        (member "can_draft" (snd (call n c "brief")) = `Bool true);
      Store.select_sources n.log [ "git" ];
      let st, j = call n c ~meth:"POST" "brief/draft" in
      Alcotest.(check int) "drafted" 200 st;
      let text = s "text" j in
      Alcotest.(check bool) "told the task" true (contains text "task: brief");
      Alcotest.(check bool)
        "the card's name" true
        (contains text "name: Ada Park");
      Alcotest.(check bool)
        "the chosen sources" true
        (contains text "commit: Add a retry queue to the importer");
      Alcotest.(check string)
        "nothing saved" saved.text (Store.brief n.log).text);
  (* The service has no DIGESTIF_WRITER: the writer recorded in the config is enough. *)
  Alcotest.(check bool)
    "a relative writer is refused" true
    (Result.is_error (Sources.set_writer n.log "writer"));
  Alcotest.(check bool)
    "recorded" true
    (Result.is_ok (Sources.set_writer n.log writer));
  Alcotest.(check bool)
    "the recorded writer, drafting" true
    (member "can_draft" (snd (call n c "brief")) = `Bool true);
  let st, j = call n c ~meth:"POST" "brief/draft" in
  Alcotest.(check int) "drafted from the config" 200 st;
  Alcotest.(check bool)
    "by the recorded writer" true
    (contains (s "text" j) "task: brief");
  Sources.unset_writer n.log;
  Alcotest.(check bool)
    "unset, no drafting" true
    (member "can_draft" (snd (call n c "brief")) = `Bool false)

(* The demo node has what the mock node behaves as if it had (ISS-36691): a writer for Draft for
   me and a nightly behavior, so the Playwright suite against the node reaches the node's own
   code. *)
let demo_behaviors () =
  let n = demo () in
  let c = session n in
  Unix.putenv "DIGESTIF_WRITER" "";
  Alcotest.(check bool)
    "a writer" true
    (member "can_draft" (snd (call n c "brief")) = `Bool true);
  let st, j = call n c ~meth:"POST" "brief/draft" in
  Alcotest.(check int) "drafted" 200 st;
  Alcotest.(check string)
    "from the card" "I'm Ada Park. I build developer tools." (s "text" j);
  Alcotest.(check bool)
    "a nightly behavior" true
    (Behaviors.executable n.log Nightly <> None);
  ok (Demo.seed n);
  Alcotest.(check bool)
    "a reset keeps the behavior" true
    (Behaviors.executable n.log Nightly <> None)

(* Claude Code session titles (ISS-36362): the aiTitle on a transcript's records, else an older
   transcript's summary line, else the session's first prompt in the prompt history. Every value
   is made up. *)
let write_file p lines =
  Out_channel.with_open_bin p (fun oc ->
      List.iter (fun l -> output_string oc (l ^ "\n")) lines)

let session_titles () =
  let dir = tmpdir () in
  let projects = Filename.concat dir "projects" in
  let project = Filename.concat projects "-Users-member-code-alpha" in
  Unix.mkdir projects 0o700;
  Unix.mkdir project 0o700;
  let transcript id lines =
    write_file (Filename.concat project (id ^ ".jsonl")) lines
  in
  let id n = Printf.sprintf "0000000%d-0000-4000-8000-000000000000" n in
  transcript (id 1)
    [
      {|{"type":"user","sessionId":"s1","message":{"role":"user","content":"Add a retry"}}|};
      {|{"type":"user","toolUseResult":{"title":"A tool result's title"},"message":{"role":"user","content":[{"type":"tool_result","content":"{\"aiTitle\":\"nested, not the session's\"}"}]}}|};
      {|{"type":"ai-title","aiTitle":"","sessionId":"s1"}|};
      {|{"type":"ai-title","aiTitle":"Add a retry to the fetcher","sessionId":"s1"}|};
      {|{"type":"ai-title","aiTitle":"A later title","sessionId":"s1"}|};
    ];
  transcript (id 2)
    [
      {|{"type":"user","message":{"role":"user","content":"Resume"}}|};
      {|{"type":"assistant","aiTitle":"Add a retry to the fetcher"}|};
    ];
  transcript (id 3)
    [
      {|{"type":"summary","summary":"Speed up the loader","leafUuid":"x"}|};
      {|{"type":"assistant","summary":"not a summary line"}|};
    ];
  transcript (id 4)
    [
      {|{"type":"user","toolUseResult":{"title":"A tool result's title"}}|};
      "not json";
    ];
  transcript (id 5) [ {|{"type":"user"}|} ];
  let old = Filename.concat project (id 6 ^ ".jsonl") in
  write_file old [ {|{"type":"ai-title","aiTitle":"Last week's work"}|} ];
  Unix.utimes old 1000. 1000.;
  let subagents = Filename.concat project (id 1 ^ "/subagents") in
  Node.mkdir_p subagents;
  write_file
    (Filename.concat subagents "agent-a1.jsonl")
    [ {|{"type":"ai-title","aiTitle":"A subagent's own title"}|} ];
  let history = Filename.concat dir "history.jsonl" in
  write_file history
    [
      Printf.sprintf {|{"display":"Another session's prompt","sessionId":"%s"}|}
        (id 9);
      Printf.sprintf {|{"display":"/model","sessionId":"%s"}|} (id 4);
      Printf.sprintf
        {|{"display":"Why does the build\n  fail on Linux?","timestamp":1,"project":"/p","sessionId":"%s"}|}
        (id 4);
      Printf.sprintf {|{"display":"A later prompt","sessionId":"%s"}|} (id 4);
      Printf.sprintf
        {|{"display":"Uninteresting title prompt","sessionId":"%s"}|} (id 1);
    ];
  let since = Unix.gettimeofday () -. 86400. in
  Alcotest.(check (list string))
    "aiTitle, summary, first prompt; deduped; no tool-result or subagent title"
    [
      "Add a retry to the fetcher";
      "Speed up the loader";
      "Why does the build fail on Linux?";
    ]
    (Sources.session_titles ~history ~since projects);
  Alcotest.(check (list string))
    "no history: only titled sessions"
    [ "Add a retry to the fetcher"; "Speed up the loader" ]
    (Sources.session_titles
       ~history:(Filename.concat dir "absent.jsonl")
       ~since project)

(* A session run in a project that holds financial records adds nothing when the projects directory
   is read, whichever reading of its name, or the directory its transcript was started in, can be
   seen to hold them: itself, its enclosing repository, or a folder enclosing it below home. A
   member who chose that project directory by path still reads it. *)
let session_titles_skip_financial () =
  let root = tmpdir () in
  let projects = Filename.concat root "projects" in
  Node.mkdir_p projects;
  let touch p =
    Node.mkdir_p (Filename.concat root (Filename.dirname p));
    Out_channel.with_open_bin (Filename.concat root p) ignore
  in
  let session ?cwd name title =
    let project = Filename.concat projects name in
    Node.mkdir_p project;
    write_file
      (Filename.concat project "s.jsonl")
      ((match cwd with
         | Some c ->
             [
               {|{"type":"queue-operation"}|};
               Printf.sprintf {|{"type":"user","cwd":"%s"}|}
                 (Filename.concat root c);
             ]
         | None -> [])
      @ [ Printf.sprintf {|{"type":"ai-title","aiTitle":"%s"}|} title ]);
    project
  in
  Node.mkdir_p (Filename.concat root "home/code/alpha/.git");
  touch "home/code/alpha/ledger.ts";
  touch "home/code/books/main.beancount";
  touch "home/code/nested/2026/Checking.QFX";
  Node.mkdir_p (Filename.concat root "home/code/repo/.git");
  touch "home/code/repo/main.ledger";
  Node.mkdir_p (Filename.concat root "home/code/repo/scripts");
  touch "home/code/my/app/a.ofx";
  Node.mkdir_p (Filename.concat root "home/code/my-app");
  let books = session "-home-code-books" "Top-level ledger" in
  ignore (session "-home-code-nested" "Export one level down");
  ignore (session "-home-code-repo-scripts" "Inside a repository of books");
  ignore (session "-home-code-my-app" "One reading holds them");
  ignore (session "-home-code-alpha" "Ordinary work");
  ignore (session "-home-code-gone" "A project no longer on disk");
  (* A plain folder of books, not a repository, with a session started in a subfolder. *)
  touch "home/plain/books.beancount";
  Node.mkdir_p (Filename.concat root "home/plain/scripts");
  ignore (session "-home-plain-scripts" "Subfolder of a plain folder of books");
  (* Removed since: the name decodes to nothing, and the transcript's cwd is what is judged. *)
  ignore
    (session ~cwd:"home/plain/2025" "-home-plain-2025"
       "Removed subfolder of a plain folder of books");
  ignore
    (session ~cwd:"home/code/repo/wt" "-home-code-repo-wt"
       "Removed worktree of a repository of books");
  ignore
    (session ~cwd:"home/code/old" "-home-code-old" "Removed ordinary project");
  (* Moved: the name decodes to an ordinary folder, the recorded cwd to the books. *)
  ignore
    (session ~cwd:"home/plain/scripts" "-home-code-alpha2"
       "Recorded in a folder of books");
  Node.mkdir_p (Filename.concat root "home/code/alpha2");
  (* Non-ASCII: one dash per UTF-16 code unit, as Claude Code writes the name. *)
  touch "home/caf\xc3\xa9/main.beancount";
  ignore (session "-home-caf-" "Accented folder of books");
  touch "home/\xf0\x9f\x93\x92books/main.beancount";
  ignore (session "-home---books" "Emoji folder of books");
  (* A dated folder of books beside the session's folder, under a folder directly under home whose
     name reads as finance, or under any plain folder deeper down. *)
  touch "home/Finance/2025/main.beancount";
  Node.mkdir_p (Filename.concat root "home/Finance/tools");
  ignore (session "-home-Finance-tools" "Beside a dated folder of books");
  touch "home/docs/personal/2025/Checking.qif";
  Node.mkdir_p (Filename.concat root "home/docs/personal/scripts");
  ignore
    (session "-home-docs-personal-scripts" "Beside books deeper below home");
  (* Not a folder of books: a repository's fixture beside the session's folder, a fixture two levels
     down inside the session's own repository, and records one level down in a folder directly
     under home whose name does not read as finance. *)
  Node.mkdir_p (Filename.concat root "home/work/team/ofxparse/.git");
  touch "home/work/team/ofxparse/sample.ofx";
  Node.mkdir_p (Filename.concat root "home/work/team/app");
  ignore (session "-home-work-team-app" "Beside a repository with a fixture");
  Node.mkdir_p (Filename.concat root "home/work/mono/.git");
  touch "home/work/mono/pkgs/fixtures/a.ofx";
  Node.mkdir_p (Filename.concat root "home/work/mono/pkgs/app");
  ignore
    (session "-home-work-mono-pkgs-app" "Inside a repository with a fixture");
  touch "home/work/old/Statement.ofx";
  Node.mkdir_p (Filename.concat root "home/work/site");
  ignore (session "-home-work-site" "Beside an export directly under home");
  (* Home's own top level and its direct folders do not enclose a project. *)
  touch "home/stray.ofx";
  touch "home/Downloads/Statement.QFX";
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" (Filename.concat root "home");
  let since = Unix.gettimeofday () -. 86400. in
  let history = Filename.concat root "absent.jsonl" in
  let titles =
    Fun.protect
      ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
      (fun () -> Sources.session_titles ~root ~history ~since projects)
  in
  Alcotest.(check (list string))
    "only the projects holding no financial records"
    [
      "Ordinary work";
      "A project no longer on disk";
      "Removed ordinary project";
      "Inside a repository with a fixture";
      "Beside an export directly under home";
      "Beside a repository with a fixture";
    ]
    titles;
  Alcotest.(check (list string))
    "chosen by path" [ "Top-level ledger" ]
    (Sources.session_titles ~root ~history ~since books)

(* A project whose books were seen once keeps being skipped after its folder of books is moved or
   deleted, since nothing left on disk encloses its path with records: the verdict is remembered in
   the project directory (Sources.financial_mark), also for a project with no session in the
   window. A project whose folder is still there and no longer holds books is read again. *)
let session_titles_remember_financial () =
  let root = tmpdir () in
  let projects = Filename.concat root "projects" in
  let at p = Filename.concat root p in
  let touch p =
    Node.mkdir_p (Filename.dirname (at p));
    Out_channel.with_open_bin (at p) ignore
  in
  let session ?(file = "s.jsonl") ~cwd name title =
    let project = Filename.concat projects name in
    Node.mkdir_p project;
    let f = Filename.concat project file in
    write_file f
      [
        Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at cwd);
        Printf.sprintf {|{"type":"ai-title","aiTitle":"%s"}|} title;
      ];
    f
  in
  let rm_rf p =
    ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; at p ]))
  in
  touch "home/books/main.beancount";
  Node.mkdir_p (at "home/books/tools");
  ignore
    (session ~cwd:"home/books/tools" "-home-books-tools" "Moved folder of books");
  Node.mkdir_p (at "home/acct/.git");
  touch "home/acct/main.ledger";
  ignore (session ~cwd:"home/acct" "-home-acct" "Deleted repository of books");
  touch "home/kept/main.beancount";
  ignore
    (session ~cwd:"home/kept" "-home-kept" "Books taken out of a kept folder");
  Node.mkdir_p (at "home/code/app");
  ignore (session ~cwd:"home/code/app" "-home-code-app" "Ordinary work");
  touch "home/ledgers/main.beancount";
  let quiet =
    session ~cwd:"home/ledgers" "-home-ledgers" "An older session of the books"
  in
  let old = Unix.gettimeofday () -. (3. *. 86400.) in
  Unix.utimes quiet old old;
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" (at "home");
  let titles () =
    let since = Unix.gettimeofday () -. 86400. in
    Fun.protect
      ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
      (fun () ->
        Unix.putenv "HOME" (at "home");
        Sources.session_titles ~root ~history:(at "absent.jsonl") ~since
          projects)
  in
  Alcotest.(check (list string))
    "while the books are there" [ "Ordinary work" ] (titles ());
  Alcotest.(check bool)
    "the verdict of a project with no session in the window is recorded" true
    (Sys.file_exists
       (Filename.concat
          (Filename.concat projects "-home-ledgers")
          Sources.financial_mark));
  Node.mkdir_p (at "home/Documents");
  Sys.rename (at "home/books") (at "home/Documents/books");
  rm_rf "home/acct";
  Sys.remove (at "home/kept/main.beancount");
  ignore
    (session ~file:"s2.jsonl" ~cwd:"home/ledgers" "-home-ledgers"
       "Started before its books were deleted");
  rm_rf "home/ledgers";
  Alcotest.(check (list string))
    "after the books were moved or deleted"
    [ "Books taken out of a kept folder"; "Ordinary work" ]
    (List.sort compare (titles ()));
  Alcotest.(check bool)
    "a project read again forgets its verdict" false
    (Sys.file_exists
       (Filename.concat
          (Filename.concat projects "-home-kept")
          Sources.financial_mark))

let reason_name = function
  | Sources.Cap -> "cap"
  | Listing_time -> "listing time"
  | Read_error -> "read error"
  | Permission -> "permission"
  | Reading_deadline -> "reading deadline"

let verdict_name = function
  | Sources.Financial -> "financial"
  | Clean -> "clean"
  | Unjudged -> "unjudged"

(* DIG-349: the temp root, entry cap, give-up and time rules of the behaviors reader (DIG-295,
   DIG-361). The fixtures sit under the default temp folder, so each judging names its own temp
   roots. A decoding through the real root streams the folders it meets and keeps only the children
   that can match, so the size of the temp folder does not change what these cases judge. *)
let judging_rules () =
  let root = fixture () in
  let at p = Filename.concat root p in
  let touch p =
    Node.mkdir_p (Filename.dirname (at p));
    Out_channel.with_open_bin (at p) ignore
  in
  let gave = ref [] and listed = ref [] in
  let judging ?(temp_roots = []) ?(max_entries = 5) () =
    {
      (Sources.default_judging ()) with
      Sources.temp_roots;
      max_entries;
      gave_up = (fun _ d -> gave := d :: !gave);
      on_listing = (fun d -> listed := d :: !listed);
    }
  in
  let fin ?(j = judging ()) p =
    Sources.financial_path ~judging:j ~memo:(Hashtbl.create 8) p
  in
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" (at "home");
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      (* A path under a temp root is judged by itself and its repository. *)
      touch "home/scratch/proj/books.beancount";
      let j = judging ~temp_roots:[ at "home/scratch" ] () in
      Alcotest.(check bool)
        "books inside a path under a temp root are seen" true
        (fin ~j (at "home/scratch/proj"));
      listed := [];
      Alcotest.(check bool)
        "a temp root itself is not financial" false
        (fin ~j (at "home/scratch"));
      Alcotest.(check (list string)) "and is not listed" [] !listed;
      (* Only the walk above a temp root is skipped. *)
      touch "home/tmpbooks/main.beancount";
      Node.mkdir_p (at "home/tmpbooks/work/app");
      Alcotest.(check bool)
        "books above the path are seen without a root" true
        (fin (at "home/tmpbooks/work/app"));
      listed := [];
      Alcotest.(check bool)
        "a root between the path and the books stops the walk" false
        (fin
           ~j:(judging ~temp_roots:[ at "home/tmpbooks/work" ] ())
           (at "home/tmpbooks/work/app"));
      Alcotest.(check bool)
        "nothing above the root was listed" false
        (List.mem (at "home/tmpbooks") !listed);
      (* A root that is the home directory or encloses it is no root. *)
      let h = at "home" in
      let roots = Sources.system_temp_roots () in
      Alcotest.(check bool)
        "no default root encloses the home directory" false
        (List.exists (fun r -> Sources.under_any h [ r ]) roots);
      let tmpdir_was = Filename.get_temp_dir_name () in
      Fun.protect
        ~finally:(fun () -> Filename.set_temp_dir_name tmpdir_was)
        (fun () ->
          Filename.set_temp_dir_name h;
          Alcotest.(check bool)
            "a TMPDIR set to the home directory is dropped" false
            (List.mem h (Sources.system_temp_roots ()));
          Filename.set_temp_dir_name (Filename.dirname h);
          Alcotest.(check bool)
            "and one that encloses it" false
            (List.mem (Filename.dirname h) (Sources.system_temp_roots ())));
      (* A folder over the cap cannot be judged: raised, logged, not memoised as no books. *)
      for i = 1 to 8 do
        touch (Printf.sprintf "home/big/f%d.txt" i)
      done;
      Node.mkdir_p (at "home/big/app");
      let memo = Hashtbl.create 8 in
      gave := [];
      let j = judging () in
      let capped () =
        match Sources.financial_path ~judging:j ~memo (at "home/big/app") with
        | _ -> false
        | exception Sources.Cannot_judge (d, _) -> d = at "home/big"
      in
      Alcotest.(check bool) "over the cap cannot be judged" true (capped ());
      Alcotest.(check bool) "and again, never as no books" true (capped ());
      Alcotest.(check (list string))
        "the folder that gave up is logged once"
        [ at "home/big" ]
        !gave;
      Alcotest.(check bool)
        "no verdict of false was kept for it" false
        (Hashtbl.fold
           (fun k v bad ->
             bad || ((not v) && Re.execp (Re.compile (Re.str "home/big")) k))
           memo false);
      (* A listing that fails part way cannot be judged either. *)
      let calls = ref 0 in
      let flaky =
        {
          (judging ~max_entries:100 ()) with
          Sources.readdir =
            (fun h ->
              incr calls;
              if !calls > 3 then
                raise (Unix.Unix_error (Unix.EIO, "readdir", ""))
              else Unix.readdir h);
        }
      in
      Alcotest.(check bool)
        "a read error part way cannot be judged" true
        (match fin ~j:flaky (at "home/big") with
        | _ -> false
        | exception Sources.Cannot_judge _ -> true);
      (* A listing over its time cannot be judged. *)
      Alcotest.(check bool)
        "out of time cannot be judged" true
        (match
           fin
             ~j:{ (judging ~max_entries:100 ()) with listing_seconds = -1. }
             (at "home/big")
         with
        | _ -> false
        | exception Sources.Cannot_judge _ -> true);
      (* The whole reading has one deadline: once it is spent, nothing more is judged, and it is
         told once. *)
      touch "home/real/books/main.beancount";
      let now = ref 0. in
      let timed =
        {
          (judging ~max_entries:100 ()) with
          Sources.clock = (fun () -> !now);
          deadline = ref 50.;
        }
      in
      let projects = at "projects" in
      let session ?(dir = projects) ?(file = "s0.jsonl") ?(title = "T") name cwd
          =
        let project = Filename.concat dir name in
        Node.mkdir_p project;
        write_file
          (Filename.concat project file)
          [
            Printf.sprintf {|{"type":"user","cwd":"%s"}|} cwd;
            Printf.sprintf {|{"type":"ai-title","aiTitle":"%s"}|} title;
          ];
        project
      in
      let mark p = Sys.file_exists (Filename.concat p Sources.financial_mark) in
      let timed_project = session "-timed" (at "home/real/books") in
      let memo = Hashtbl.create 8 and cache = Hashtbl.create 8 in
      gave := [];
      now := 60.;
      Alcotest.(check string)
        "a project past the reading's deadline is skipped" "unjudged"
        (verdict_name
           (Sources.financial_project ~judging:timed ~root ~cache ~memo
              timed_project
              [ Filename.concat timed_project "s0.jsonl" ]));
      Alcotest.(check bool) "with no mark" false (mark timed_project);
      ignore
        (Sources.financial_project ~judging:timed ~root ~cache ~memo
           timed_project
           [ Filename.concat timed_project "s0.jsonl" ]);
      Alcotest.(check int) "and told once" 1 (List.length !gave);
      now := 10.;
      Alcotest.(check string)
        "the same project inside the deadline is judged" "financial"
        (verdict_name
           (Sources.financial_project ~judging:timed ~root ~cache
              ~memo:(Hashtbl.create 8) timed_project
              [ Filename.concat timed_project "s0.jsonl" ]));
      Alcotest.(check bool) "and marked" true (mark timed_project);
      (* Through the projects directory. *)
      Node.mkdir_p (at "projects");
      let since = Unix.gettimeofday () -. 86400. in
      let titles ?(dir = projects) ?(j = judging ()) () =
        Sources.session_titles ~root ~history:(at "absent.jsonl") ~judging:j
          ~since dir
      in
      let capped_project =
        session ~title:"Capped" "-capped" (at "home/big/app")
      in
      let mixed = session ~title:"Mixed" "-mixed" (at "home/big/app") in
      ignore (session ~file:"s1.jsonl" "-mixed" (at "home/real/books"));
      Sys.remove (Filename.concat timed_project Sources.financial_mark);
      Sys.remove (Filename.concat timed_project "s0.jsonl");
      let read = titles () in
      Alcotest.(check bool)
        "the project that cannot be judged is not read" false
        (List.mem "Capped" read);
      Alcotest.(check bool)
        "the financial project is not read" false (List.mem "Mixed" read);
      Alcotest.(check bool)
        "a project that cannot be judged gets no mark" false
        (mark capped_project);
      Alcotest.(check bool)
        "books on another path of the project still mark it" true (mark mixed);
      (* A mark already there survives a project that cannot be judged. *)
      let marked = session "-marked" (at "home/big/app") in
      Sources.remember_financial ~memo:(Hashtbl.create 8) (judging ()) marked;
      ignore (titles ());
      Alcotest.(check bool) "an existing mark survives" true (mark marked);
      (* An idle project that cannot be judged writes no mark. *)
      let idle = session "-idle" (at "home/big/app") in
      let old = Unix.gettimeofday () -. (3. *. 86400.) in
      Unix.utimes (Filename.concat idle "s0.jsonl") old old;
      ignore (titles ());
      Alcotest.(check bool) "an idle project gets no mark" false (mark idle);
      (* Skipped in one run, read in the next once the folder is small. *)
      let later = session ~title:"Read later" "-later" (at "home/big/app") in
      ignore later;
      Sys.remove (Filename.concat marked Sources.financial_mark);
      Alcotest.(check bool)
        "skipped while its folder is over the cap" false
        (List.mem "Read later" (titles ()));
      Alcotest.(check bool)
        "read in the next run once the cap allows" true
        (List.mem "Read later" (titles ~j:(judging ~max_entries:100 ()) ()));
      (* A project named under a temp root is skipped by its name, never decoded or opened. *)
      let other = at "projects2" in
      Node.mkdir_p (at "home/scratch/trap");
      touch "home/scratch/trap/books.beancount";
      let trap_name = Sources.encode_segment (at "home/scratch/trap") in
      let trap = session ~dir:other trap_name (at "home/scratch/trap") in
      listed := [];
      let j = judging ~max_entries:5000 ~temp_roots:[ at "home/scratch" ] () in
      Alcotest.(check (list string))
        "it is not read" [] (titles ~dir:other ~j ());
      Alcotest.(check bool)
        "and the root it names was not listed" false
        (List.mem (at "home/scratch") !listed);
      Alcotest.(check bool)
        "nor the folder under it" false
        (List.mem (at "home/scratch/trap") !listed);
      Alcotest.(check bool) "no mark either" false (mark trap);
      (* A look-alike folder beside the root is not under it. *)
      Node.mkdir_p (at "home/scratch-two/app");
      ignore
        (session ~dir:other ~title:"Beside the root"
           (Sources.encode_segment "/home/scratch-two/app")
           (at "home/scratch-two/app"));
      Alcotest.(check (list string))
        "a look-alike sibling is read" [ "Beside the root" ]
        (titles ~dir:other ~j ()))

(* DIG-349: what cannot be judged is never "no books". A folder that refuses to open, a decoding
   that meets a folder past the cap, a verdict with no decoding, and a reading out of time. *)
let judging_fail_closed () =
  let root = fixture () in
  let at p = Filename.concat root p in
  let touch p =
    Node.mkdir_p (Filename.dirname (at p));
    Out_channel.with_open_bin (at p) ignore
  in
  let gave = ref [] and listed = ref [] in
  let judging ?(temp_roots = []) ?(max_entries = 5) ?(max_streamed = 100) () =
    {
      (Sources.default_judging ()) with
      Sources.temp_roots;
      max_entries;
      max_streamed;
      gave_up = (fun r d -> gave := (reason_name r, d) :: !gave);
      on_listing = (fun d -> listed := d :: !listed);
    }
  in
  let cannot f =
    match f () with _ -> false | exception Sources.Cannot_judge _ -> true
  in
  (* A folder that refuses to open is not an empty one. *)
  let refusing err =
    {
      (judging ()) with
      Sources.opendir = (fun _ -> raise (Unix.Unix_error (err, "opendir", "")));
    }
  in
  let entries j =
    Sources.read_entries ~memo:(Hashtbl.create 8) j (at "folder")
  in
  Alcotest.(check bool)
    "no permission to open cannot be judged" true
    (cannot (fun () -> entries (refusing Unix.EACCES)));
  Alcotest.(check (list (pair string string)))
    "and says why"
    [ ("permission", at "folder") ]
    !gave;
  Alcotest.(check bool)
    "an operation not permitted too" true
    (cannot (fun () -> entries (refusing Unix.EPERM)));
  Alcotest.(check (list string))
    "a folder that is not there is empty" []
    (entries (refusing Unix.ENOENT));
  Alcotest.(check (list string))
    "and one that is not a folder" []
    (entries (refusing Unix.ENOTDIR));
  Alcotest.(check bool)
    "any other failure to open cannot be judged" true
    (cannot (fun () -> entries (refusing Unix.EIO)));
  (* A decoding is a lookup. The temp root past the cap is never listed, and the project beside
     it that the name also reads as is found. *)
  let decode ?(memo = Hashtbl.create 8) ~j sub name =
    Sources.decode_project_dir ~root:(at sub) ~memo ~judging:j name
  in
  for i = 1 to 8 do
    touch (Printf.sprintf "s1/tmp/f%d" i)
  done;
  Node.mkdir_p (at "s1/tmp-scratch/x");
  listed := [];
  Alcotest.(check (list string))
    "a name under a temp root past the cap reads as the folder beside it"
    [ at "s1/tmp-scratch/x" ]
    (decode ~j:(judging ~temp_roots:[ at "s1/tmp" ] ()) "s1" "-tmp-scratch-x");
  Alcotest.(check bool)
    "the temp root was never listed" false
    (List.mem (at "s1/tmp") !listed);
  (* A level past the cap still decodes, by streaming only the children that can match. *)
  for i = 1 to 8 do
    touch (Printf.sprintf "home/s2/wide/decoy%d" i)
  done;
  Node.mkdir_p (at "home/s2/wide/proj/x");
  Alcotest.(check (list string))
    "a folder past the cap decodes"
    [ at "home/s2/wide/proj/x" ]
    (decode ~j:(judging ()) "home/s2" "-wide-proj-x");
  (* Matches past the cap cannot be judged. *)
  List.iter
    (fun n -> Node.mkdir_p (at ("s3/many/" ^ n)))
    [ "x.a"; "x_a"; "x a"; "x,a"; "x;a"; "x:a" ];
  gave := [];
  Alcotest.(check bool)
    "more matches than the cap cannot be judged" true
    (cannot (fun () -> decode ~j:(judging ()) "s3" "-many-x-a"));
  Alcotest.(check (list (pair string string)))
    "and says so"
    [ ("cap", at "s3/many") ]
    !gave;
  (* A folder streamed past the ceiling cannot be judged, and later names do not stream it again. *)
  let memo = Hashtbl.create 8 in
  let j = judging ~max_streamed:3 () in
  gave := [];
  listed := [];
  Alcotest.(check bool)
    "past the ceiling cannot be judged" true
    (cannot (fun () -> decode ~memo ~j "home/s2" "-wide-proj-x"));
  Alcotest.(check bool)
    "and a later name gives up at once" true
    (cannot (fun () -> decode ~memo ~j "home/s2" "-wide-other"));
  Alcotest.(check int)
    "the folder was listed once" 1
    (List.length (List.filter (( = ) (at "home/s2/wide")) !listed));
  Alcotest.(check int) "and logged once" 1 (List.length !gave);
  (* One branch that cannot be judged does not end the others. *)
  for i = 1 to 8 do
    touch (Printf.sprintf "s5/m/n%d" i)
  done;
  Node.mkdir_p (at "s5/m-n");
  let j = judging ~max_streamed:5 () in
  Alcotest.(check (list string))
    "the other branch is found"
    [ at "s5/m-n" ]
    (decode ~j "s5" "-m-n");
  Alcotest.(check bool)
    "none found raises" true
    (cannot (fun () -> decode ~j "s5" "-m-zzz"));
  (* The verdict of a project whose name cannot be decoded: the paths its transcripts name that
     judge clean do not stand in for it. Books seen on one still count. *)
  touch "home/proj/main.go";
  touch "home/ledger/main.beancount";
  let projects = at "projects" in
  let project ?(file = "s0.jsonl") name cwd =
    let dir = Filename.concat projects name in
    Node.mkdir_p dir;
    write_file (Filename.concat dir file)
      [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} cwd ];
    dir
  in
  let mark d = Sys.file_exists (Filename.concat d Sources.financial_mark) in
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" (at "home");
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      let verdict ?(j = judging ~max_streamed:3 ()) d =
        verdict_name
          (Sources.financial_project ~judging:j ~root:(at "home/s2")
             ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) d
             [ Filename.concat d "s0.jsonl" ])
      in
      let clean = project "-wide-proj-x" (at "home/proj") in
      Alcotest.(check string)
        "a clean cwd does not stand in for a name that cannot be decoded"
        "unjudged" (verdict clean);
      Alcotest.(check bool) "and gets no mark" false (mark clean);
      Alcotest.(check string)
        "the same project with a name that decodes is clean" "clean"
        (verdict ~j:(judging ~max_entries:20 ()) clean);
      let books = project "-wide-proj-y" (at "home/ledger") in
      Alcotest.(check string)
        "books on a cwd count whatever the decoding did" "financial"
        (verdict books);
      Alcotest.(check bool) "and mark it" true (mark books);
      let gone = project "-wide-proj-z" (at "home/gone") in
      Sources.remember_financial ~memo:(Hashtbl.create 8) (judging ()) gone;
      Alcotest.(check string)
        "a marked project with its path gone stays skipped" "financial"
        (verdict gone);
      let kept = project "-wide-proj-w" (at "home/proj") in
      Sources.remember_financial ~memo:(Hashtbl.create 8) (judging ()) kept;
      Alcotest.(check string)
        "a marked project that cannot be judged keeps its mark and is unjudged"
        "unjudged" (verdict kept);
      Alcotest.(check bool) "mark kept" true (mark kept));
  (* The reading's time is spent on the projects with sessions first, then on the idle ones. *)
  let now = ref 0. in
  let tick_open path =
    now := !now +. 1.;
    Unix.opendir path
  in
  let timed reading_seconds =
    {
      (judging ~max_entries:100 ()) with
      Sources.clock = (fun () -> !now);
      opendir = tick_open;
      reading_seconds;
      deadline = ref infinity;
    }
  in
  let projects2 = at "projects2" in
  let session ~title name cwd =
    let dir = Filename.concat projects2 name in
    Node.mkdir_p dir;
    write_file
      (Filename.concat dir "s0.jsonl")
      [
        Printf.sprintf {|{"type":"user","cwd":"%s"}|} cwd;
        Printf.sprintf {|{"type":"ai-title","aiTitle":"%s"}|} title;
      ];
    dir
  in
  Node.mkdir_p (at "home2/idle");
  Node.mkdir_p (at "home2/active");
  let idle = session ~title:"Idle" "-a-idle" (at "home2/idle") in
  ignore (session ~title:"Active" "-b-active" (at "home2/active"));
  let old = Unix.gettimeofday () -. (3. *. 86400.) in
  Unix.utimes (Filename.concat idle "s0.jsonl") old old;
  Unix.putenv "HOME" (at "home2");
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      let titles j =
        Sources.session_titles ~root:(at "nowhere") ~history:(at "absent.jsonl")
          ~judging:j
          ~since:(Unix.gettimeofday () -. 86400.)
          projects2
      in
      (* Measure what the active project alone costs. *)
      now := 0.;
      let j = timed 1000. in
      ignore (titles j);
      let cost = !now in
      Alcotest.(check bool) "judging costs something" true (cost > 2.);
      (* A budget that covers the active project and not both. *)
      now := 0.;
      let j = timed (cost -. 1.) in
      gave := [];
      let read = titles j in
      Alcotest.(check bool)
        "the project with a session is judged before the idle one" true
        (List.mem "Active" read);
      Alcotest.(check int)
        "the reading was told once as out of time" 1
        (List.length (List.filter (fun (r, _) -> r = "reading deadline") !gave));
      Alcotest.(check string)
        "the idle project is unjudged" "unjudged"
        (verdict_name
           (Sources.note_financial ~judging:j ~root:(at "nowhere")
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) idle));
      Alcotest.(check bool)
        "and has no mark" false
        (Sys.file_exists (Filename.concat idle Sources.financial_mark)));
  (* A folder that refuses to open leaves the project unread, and the member is told. *)
  if Unix.geteuid () <> 0 then (
    Node.mkdir_p (at "home3/locked");
    let projects3 = at "projects3" in
    Node.mkdir_p (Filename.concat projects3 "-locked");
    write_file
      (Filename.concat projects3 "-locked/s0.jsonl")
      [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "home3/locked") ];
    Unix.chmod (at "home3/locked") 0o000;
    Unix.putenv "HOME" (at "home3");
    Fun.protect
      ~finally:(fun () ->
        Unix.chmod (at "home3/locked") 0o700;
        Unix.putenv "HOME" (Option.value saved ~default:""))
      (fun () ->
        let source : Store.source =
          {
            id = "claude_code";
            kind = "claude_code";
            label = "Claude Code";
            paths = [ projects3 ];
            yields = [];
            selected = true;
          }
        in
        let extracted, failures = Sources.extract_with_failures [ source ] in
        Alcotest.(check (list string)) "nothing of it is read" [] extracted;
        Alcotest.(check (list string))
          "and the member is told"
          [
            "1 project not read: could not be judged, ~/locked (permission \
             denied)";
          ]
          failures;
        Alcotest.(check bool)
          "with no mark" false
          (mark (Filename.concat projects3 "-locked"));
        (* ISS-81609: the same failure, carried as the folder and why for the node's notice. *)
        let r = Sources.extract_reading [ source ] in
        Alcotest.(check int) "one project unjudged" 1 r.unjudged;
        Alcotest.(check bool)
          "carried as the folder and why" true
          (r.skipped = [ (at "home3/locked", Sources.Permission) ]);
        let t = Skipped.of_reading r in
        Alcotest.(check bool)
          "told as no access" true
          (t.folders = [ (at "home3/locked", Skipped.No_access) ]);
        Alcotest.(check bool)
          "the lines the writer is given name none of it" false
          (List.exists (fun l -> contains l "locked") r.lines)))

(* DIG-349 round three: a sibling that cannot be judged does not hide books beside it, a judging
   give-up does not stop a decoding, a path that cannot be looked at is not gone, the failure line
   names its folders, the reading's time begins with the first project, and a decoding given up in
   part is not a verdict. *)
let judging_round_three () =
  let root = fixture () in
  let at p = Filename.concat root p in
  let touch p =
    Node.mkdir_p (Filename.dirname (at p));
    Out_channel.with_open_bin (at p) ignore
  in
  let gave = ref [] in
  let judging ?(max_entries = 5) ?(opendir = Unix.opendir) () =
    {
      (Sources.default_judging ()) with
      Sources.temp_roots = [];
      max_entries;
      max_streamed = 100;
      opendir;
      gave_up = (fun r d -> gave := (reason_name r, d) :: !gave);
    }
  in
  let cannot f =
    match f () with _ -> false | exception Sources.Cannot_judge _ -> true
  in
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" root;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      (* R1. A sibling over the cap, sorted first, does not hide the books beside it. *)
      for i = 1 to 8 do
        touch (Printf.sprintf "r1/a_big/f%d.txt" i)
      done;
      touch "r1/b_books/main.beancount";
      Alcotest.(check bool)
        "books beside a capped sibling are seen" true
        (Sources.holds_financial_records_exn ~judging:(judging ())
           ~memo:(Hashtbl.create 8) (at "r1"));
      Alcotest.(check bool)
        "and the capped sibling was told" true
        (List.mem ("cap", at "r1/a_big") !gave);
      (* An unreadable sibling too. *)
      touch "r1u/a_locked/x.txt";
      touch "r1u/b_books/main.beancount";
      let refuse_a d =
        if d = at "r1u/a_locked" then
          raise (Unix.Unix_error (Unix.EACCES, "opendir", d))
        else Unix.opendir d
      in
      Alcotest.(check bool)
        "books beside an unreadable sibling are seen" true
        (Sources.holds_financial_records_exn
           ~judging:(judging ~opendir:refuse_a ())
           ~memo:(Hashtbl.create 8) (at "r1u"));
      (* With no books beside it, the sibling that cannot be judged is still raised. *)
      touch "r1n/a_locked/x.txt";
      touch "r1n/b_plain/readme.txt";
      let refuse_n d =
        if d = at "r1n/a_locked" then
          raise (Unix.Unix_error (Unix.EACCES, "opendir", d))
        else Unix.opendir d
      in
      Alcotest.(check bool)
        "no books seen and a sibling not judged is not an answer" true
        (cannot (fun () ->
             Sources.holds_financial_records_exn
               ~judging:(judging ~opendir:refuse_n ())
               ~memo:(Hashtbl.create 8) (at "r1n")));
      (* The verdict and the mark. *)
      let project = at "proj" in
      Node.mkdir_p project;
      write_file
        (Filename.concat project "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "r1") ];
      let cache = Hashtbl.create 8 in
      Alcotest.(check string)
        "a capped sibling beside books is a financial project" "financial"
        (verdict_name
           (Sources.financial_project ~judging:(judging ()) ~root ~cache
              ~memo:(Hashtbl.create 8) project
              [ Filename.concat project "s.jsonl" ]));
      Alcotest.(check bool)
        "and the mark is written" true
        (Sys.file_exists (Filename.concat project Sources.financial_mark));
      (* R2. A listing that judging gave up on is still decoded through. *)
      for i = 1 to 8 do
        touch (Printf.sprintf "big/f%d.txt" i)
      done;
      Node.mkdir_p (at "big/p1");
      Node.mkdir_p (at "big/p2");
      let j = judging () and memo = Hashtbl.create 8 in
      Alcotest.(check bool)
        "a project in the big folder cannot be judged" true
        (cannot (fun () ->
             Sources.financial_path ~judging:j ~memo (at "big/p1")));
      Alcotest.(check (list string))
        "a second project under it still decodes"
        [ at "big/p2" ]
        (Sources.decode_project_dir ~root ~memo ~judging:j "-big-p2");
      let p2 = at "projs/-big-p2" in
      Node.mkdir_p p2;
      Alcotest.(check string)
        "and it is unjudged, since the big folder cannot be" "unjudged"
        (verdict_name
           (Sources.note_financial ~judging:j ~root ~cache:(Hashtbl.create 8)
              ~memo p2));
      Alcotest.(check bool)
        "with no mark" false
        (Sys.file_exists (Filename.concat p2 Sources.financial_mark));
      (* R4. A path that cannot be looked at is not gone. *)
      if Unix.geteuid () <> 0 then (
        touch "locked/child/x.txt";
        Unix.chmod (at "locked") 0o000;
        Fun.protect
          ~finally:(fun () -> Unix.chmod (at "locked") 0o700)
          (fun () ->
            gave := [];
            Alcotest.(check bool)
              "a path that cannot be stat'ed cannot be judged" true
              (cannot (fun () ->
                   Sources.financial_path ~judging:(judging ())
                     ~memo:(Hashtbl.create 8) (at "locked/child")));
            Alcotest.(check (list (pair string string)))
              "and says why"
              [ ("permission", at "locked/child") ]
              !gave;
            let p = at "proj4" in
            Node.mkdir_p p;
            write_file
              (Filename.concat p "s.jsonl")
              [
                Printf.sprintf {|{"type":"user","cwd":"%s"}|}
                  (at "locked/child");
              ];
            Alcotest.(check string)
              "its project is unjudged" "unjudged"
              (verdict_name
                 (Sources.financial_project ~judging:(judging ()) ~root
                    ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) p
                    [ Filename.concat p "s.jsonl" ]));
            Alcotest.(check bool)
              "with no mark" false
              (Sys.file_exists (Filename.concat p Sources.financial_mark))));
      Alcotest.(check bool)
        "a path that is not there is gone, not unjudged" false
        (Sources.stat_dir ~memo:(Hashtbl.create 8) (judging ()) (at "nothing"));
      Alcotest.(check bool)
        "so is one with a file in the way" false
        (Sources.stat_dir ~memo:(Hashtbl.create 8) (judging ())
           (at "r1u/a_locked/x.txt/y"));
      (* R5. The failure line. *)
      Alcotest.(check string)
        "one project, in the singular, with its folder and why"
        "1 project not read: could not be judged, /a/b (too many entries)"
        (Sources.unjudged_failure 1 [ ("/a/b", Sources.Cap) ]);
      Alcotest.(check string)
        "several projects name at most three distinct folders, oldest first"
        "5 projects not read: could not be judged, /a (too many entries), /b \
         (permission denied), /c (too slow to list)"
        (Sources.unjudged_failure 5
           [
             ("/d", Sources.Read_error);
             ("/c", Sources.Listing_time);
             ("/b", Sources.Permission);
             ("/b", Sources.Permission);
             ("/a", Sources.Cap);
           ]);
      (* R6. The reading's time begins with the first project judged. *)
      let now = ref 100. in
      let j =
        {
          (judging ()) with
          Sources.clock = (fun () -> !now);
          reading_seconds = 300.;
        }
      in
      Alcotest.(check bool) "not begun at first" true (!(j.deadline) = infinity);
      let own = at "own" in
      Node.mkdir_p own;
      write_file (Filename.concat own "s.jsonl") [ "{}" ];
      ignore (Sources.session_files ~root ~judging:j own);
      Alcotest.(check bool)
        "a project directory's own transcripts begin nothing" true
        (!(j.deadline) = infinity);
      now := 130.;
      Node.mkdir_p (at "many/-x");
      ignore (Sources.session_files ~root ~judging:j (at "many"));
      Alcotest.(check (float 0.001))
        "the first project directory begins it" 430. !(j.deadline);
      now := 200.;
      ignore (Sources.session_files ~root ~judging:j (at "many"));
      Alcotest.(check (float 0.001)) "and it begins once" 430. !(j.deadline);
      (* R7. A decoding given up in part is not a verdict. *)
      Node.mkdir_p (at "split/a/b");
      Node.mkdir_p (at "split/a-b");
      let refuse_a d =
        if d = at "split/a" then
          raise (Unix.Unix_error (Unix.EACCES, "opendir", d))
        else Unix.opendir d
      in
      let j7 = judging ~max_entries:100 ~opendir:refuse_a () in
      let split_root = at "split" in
      let paths, partial =
        Sources.decode_judged ~root:split_root ~judging:j7 "-a-b"
      in
      Alcotest.(check (pair (list string) (list string)))
        "one branch found a path, another was given up, and why"
        ([ at "split/a-b" ], [ "permission" ])
        (paths, List.map reason_name partial);
      Alcotest.(check (list string))
        "the lookup alone still returns what it found"
        [ at "split/a-b" ]
        (Sources.decode_project_dir ~root:split_root ~judging:j7 "-a-b");
      Unix.putenv "HOME" split_root;
      let idle = at "idle7/-a-b" in
      Node.mkdir_p idle;
      Alcotest.(check string)
        "an idle project is unjudged" "unjudged"
        (verdict_name
           (Sources.note_financial ~judging:j7 ~root:split_root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) idle));
      Alcotest.(check bool)
        "with no mark" false
        (Sys.file_exists (Filename.concat idle Sources.financial_mark));
      let bare = at "bare7/-a-b" in
      Node.mkdir_p bare;
      write_file (Filename.concat bare "s.jsonl") [ {|{"type":"user"}|} ];
      Alcotest.(check string)
        "a project with no transcript path is unjudged too" "unjudged"
        (verdict_name
           (Sources.financial_project ~judging:j7 ~root:split_root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) bare
              [ Filename.concat bare "s.jsonl" ]));
      Alcotest.(check bool)
        "with no mark" false
        (Sys.file_exists (Filename.concat bare Sources.financial_mark));
      let named = at "named7/-a-b" in
      Node.mkdir_p named;
      write_file
        (Filename.concat named "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "split/a-b") ];
      Alcotest.(check string)
        "a transcript's own path does not stand in for a branch refused for \
         permission"
        "unjudged"
        (verdict_name
           (Sources.financial_project ~judging:j7 ~root:split_root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) named
              [ Filename.concat named "s.jsonl" ]));
      Alcotest.(check bool)
        "with no mark" false
        (Sys.file_exists (Filename.concat named Sources.financial_mark));
      (* A branch too big to stream is covered by the transcript's path. *)
      for i = 1 to 7 do
        touch (Printf.sprintf "split/a/f%d.txt" i)
      done;
      let jcap =
        { (judging ~max_entries:100 ()) with Sources.max_streamed = 5 }
      in
      let capped = at "capped7/-a-b" in
      Node.mkdir_p capped;
      write_file
        (Filename.concat capped "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "split/a-b") ];
      Alcotest.(check string)
        "a transcript's own path stands in for a branch over the cap" "clean"
        (verdict_name
           (Sources.financial_project ~judging:jcap ~root:split_root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) capped
              [ Filename.concat capped "s.jsonl" ]));
      let capped_bare = at "capped7b/-a-b" in
      Node.mkdir_p capped_bare;
      Alcotest.(check string)
        "and with no transcript path the project is not judged" "unjudged"
        (verdict_name
           (Sources.note_financial ~judging:jcap ~root:split_root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) capped_bare));
      (* ISS-80554. Books on the branch over the cap, beside a clean look-alike the transcript names:
         the mark the books wrote stays, and so does the skip. *)
      for i = 1 to 7 do
        touch (Printf.sprintf "split9/a/f%d.txt" i)
      done;
      touch "split9/a/b/main.beancount";
      Node.mkdir_p (at "split9/a-b");
      let split9 = at "split9" in
      Unix.putenv "HOME" split9;
      let kept = at "kept9/-a-b" in
      Node.mkdir_p kept;
      write_file
        (Filename.concat kept "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "split9/a-b") ];
      write_file (Filename.concat kept Sources.financial_mark) [ "marked" ];
      Alcotest.(check string)
        "a marked project with a branch over the cap stays financial"
        "financial"
        (verdict_name
           (Sources.financial_project ~judging:jcap ~root:split9
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) kept
              [ Filename.concat kept "s.jsonl" ]));
      Alcotest.(check bool)
        "and keeps its mark" true
        (Sys.file_exists (Filename.concat kept Sources.financial_mark));
      Unix.putenv "HOME" split_root;
      (* The mark. A mark that cannot be stat'ed is cannot-judge, never overwritten or removed. *)
      let marked_proj dir =
        Node.mkdir_p dir;
        Unix.symlink
          (Filename.concat dir ".digestif-financial")
          (Filename.concat dir ".digestif-financial")
      in
      let loop = at "loop8" in
      marked_proj loop;
      Alcotest.(check bool)
        "a mark that is a symlink loop cannot be judged" true
        (cannot (fun () ->
             Sources.stat_exists ~memo:(Hashtbl.create 8) (judging ())
               (Filename.concat loop Sources.financial_mark)));
      write_file
        (Filename.concat loop "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "r1n/b_plain") ];
      Alcotest.(check string)
        "a project whose mark cannot be stat'ed is unjudged, even with clean \
         paths"
        "unjudged"
        (verdict_name
           (Sources.financial_project ~judging:(judging ()) ~root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) loop
              [ Filename.concat loop "s.jsonl" ]));
      Alcotest.(check bool)
        "and the mark is still the same link" true
        (Unix.readlink (Filename.concat loop Sources.financial_mark)
        = Filename.concat loop Sources.financial_mark);
      Alcotest.(check string)
        "an idle one too" "unjudged"
        (verdict_name
           (Sources.note_financial ~judging:(judging ()) ~root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) loop));
      (* Books seen with such a mark: still financial, and the mark is left as it is. *)
      let books_loop = at "loop9" in
      marked_proj books_loop;
      write_file
        (Filename.concat books_loop "s.jsonl")
        [ Printf.sprintf {|{"type":"user","cwd":"%s"}|} (at "r1") ];
      Alcotest.(check string)
        "books seen are financial all the same" "financial"
        (verdict_name
           (Sources.financial_project ~judging:(judging ()) ~root
              ~cache:(Hashtbl.create 8) ~memo:(Hashtbl.create 8) books_loop
              [ Filename.concat books_loop "s.jsonl" ]));
      Alcotest.(check bool)
        "and the link was not written over" true
        (Unix.readlink (Filename.concat books_loop Sources.financial_mark)
        = Filename.concat books_loop Sources.financial_mark);
      (* S5: a folder that refused to open is not opened again by a decoding. *)
      let opens = ref 0 in
      let refusing_once d =
        if d = at "split/a" then (
          incr opens;
          raise (Unix.Unix_error (Unix.EACCES, "opendir", d)))
        else Unix.opendir d
      in
      let jr = judging ~max_entries:100 ~opendir:refusing_once () in
      let memo = Hashtbl.create 8 and cache = Hashtbl.create 8 in
      ignore
        (Sources.decode_judged ~root:split_root ~memo ~cache ~judging:jr "-a-b");
      ignore
        (Sources.decode_judged ~root:split_root ~memo ~cache:(Hashtbl.create 8)
           ~judging:jr "-a-b");
      Alcotest.(check int) "it is opened once" 1 !opens;
      Unix.putenv "HOME" root)

(* A project under the home directory is judged, and its books seen, when the home directory is
   itself under a system temp root, as it is for these fixtures: the root is dropped, so the
   project is not skipped by its name. *)
let judging_home_under_temp () =
  let root = fixture () in
  let at p = Filename.concat root p in
  Node.mkdir_p (at "home/code/books");
  Out_channel.with_open_bin (at "home/code/books/main.beancount") ignore;
  Node.mkdir_p (at "home/code/app");
  let projects = at "projects" in
  let session name cwd title =
    let project = Filename.concat projects name in
    Node.mkdir_p project;
    write_file
      (Filename.concat project "s.jsonl")
      [
        Printf.sprintf {|{"type":"user","cwd":"%s"}|} cwd;
        Printf.sprintf {|{"type":"ai-title","aiTitle":"%s"}|} title;
      ];
    project
  in
  let books =
    session
      (Sources.encode_segment "/code/books")
      (at "home/code/books") "Books"
  in
  ignore
    (session (Sources.encode_segment "/code/app") (at "home/code/app") "App");
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" (at "home");
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      let titles =
        Sources.session_titles ~root:(at "home") ~history:(at "absent.jsonl")
          ~since:(Unix.gettimeofday () -. 86400.)
          projects
      in
      Alcotest.(check (list string))
        "the project with books is not read, the other is" [ "App" ] titles;
      Alcotest.(check bool)
        "the books were judged, not skipped by name" true
        (Sys.file_exists (Filename.concat books Sources.financial_mark)))

(* Every case in node/web/test/sessions_cases.json, which behaviors/test/sessions-cases.test.ts runs
   against the behaviors reader too: each folder layout is built under a fresh fixture, its one
   project read by session_files from the real root, and the project's verdict and mark asserted.
   The fixtures sit under the system temp folder, so the judging names no system temp roots and
   streams every folder on the way down whatever its size. *)
let sessions_corpus_case ~max_entries c =
  let open Yojson.Safe.Util in
  let strs k =
    match member k c with `Null -> [] | l -> List.map to_string (to_list l)
  in
  let base = fixture () in
  let at p = if p = "." then base else Filename.concat base p in
  let locked = List.map at (strs "unreadable") in
  let slow = List.map at (strs "slow") in
  let home = at "h" in
  let saved = Sys.getenv_opt "HOME" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun d -> Unix.chmod d 0o700) locked;
      Unix.putenv "HOME" (Option.value saved ~default:""))
    (fun () ->
      Node.mkdir_p home;
      List.iter (fun d -> Node.mkdir_p (at d)) (strs "dirs");
      List.iter
        (fun f ->
          Node.mkdir_p (Filename.dirname (at f));
          Out_channel.with_open_bin (at f) ignore)
        (strs "files");
      (match member "crowded" c with
      | `Null -> ()
      | l ->
          List.iter
            (fun x ->
              let d = at (to_string (member "dir" x)) in
              Node.mkdir_p d;
              for i = 0 to to_int (member "entries" x) - 1 do
                Out_channel.with_open_bin
                  (Filename.concat d (Printf.sprintf "e%d.txt" i))
                  ignore
              done)
            (to_list l));
      List.iter Node.mkdir_p slow;
      (match member "symlinks" c with
      | `Null -> ()
      | l ->
          List.iter
            (fun x ->
              let p = at (to_string (member "path" x)) in
              Node.mkdir_p (Filename.dirname p);
              Unix.symlink (to_string (member "to" x)) p)
            (to_list l));
      let projects = Filename.concat home ".claude/projects" in
      let name = Sources.encode_segment (at (to_string (member "project" c))) in
      let dir = Filename.concat projects name in
      Node.mkdir_p dir;
      let cwd =
        match member "cwd" c with
        | `Null -> ""
        | v ->
            Printf.sprintf {|,"cwd":%s|}
              (Yojson.Safe.to_string (`String (at (to_string v))))
      in
      write_file
        (Filename.concat dir "s.jsonl")
        [
          Printf.sprintf
            {|{"type":"user","message":{"role":"user","content":"A prompt"}%s}|}
            cwd;
        ];
      let mark = Filename.concat dir Sources.financial_mark in
      if member "marked" c = `Bool true then write_file mark [ "marked" ];
      List.iter (fun d -> Unix.chmod d 0o000) locked;
      Unix.putenv "HOME" home;
      (* A slow folder's listing outlasts the limit: the clock moves past it on every entry read. *)
      let now = ref 0. and slow_handles = ref [] in
      let j =
        {
          (Sources.default_judging ()) with
          Sources.temp_roots = List.map at (strs "temp_roots");
          system_roots = [];
          factory_roots = Sources.factory_roots ();
          max_entries;
          max_streamed = max_int;
          clock = (fun () -> !now);
          opendir =
            (fun d ->
              let h = Unix.opendir d in
              if List.mem d slow then slow_handles := h :: !slow_handles;
              h);
          readdir =
            (fun h ->
              if List.memq h !slow_handles then
                now := !now +. (5. *. Sources.max_listing_seconds);
              Unix.readdir h);
          gave_up = (fun _ _ -> ());
          on_deadline = ignore;
        }
      in
      let files =
        Sources.session_files ~root:"/" ~since:0. ~judging:j projects
      in
      let verdict =
        if files <> [] then "read"
        else if
          Sources.skipped_by_name ~also:j.factory_roots ~memo:(Hashtbl.create 8)
            j name
        then "skipped"
        else if !(j.unjudged) > 0 then "cannot_judge"
        else "financial"
      in
      (verdict, Sys.file_exists mark))

let sessions_corpus () =
  let open Yojson.Safe.Util in
  let corpus = Yojson.Safe.from_file "sessions_cases.json" in
  let cases = to_list (member "cases" corpus) in
  let max_entries = to_int (member "max_entries" corpus) in
  Alcotest.(check bool) "the cases load" true (List.length cases >= 20);
  List.iter
    (fun c ->
      let name = to_string (member "name" c) in
      if Unix.getuid () = 0 && member "unreadable" c <> `Null then ()
      else
        Alcotest.(check (pair string bool))
          name
          (to_string (member "verdict" c), to_bool (member "mark" c))
          (sessions_corpus_case ~max_entries c))
    cases

(* A folder capped in an earlier listing of the reading that then refuses to open is given up for
   the refusal, not the cap, every time a decoding meets it: a cap beside a resolved branch can be
   excused by a transcript's path, a refusal never is. *)
let judging_refusal_keeps_its_reason () =
  let root = fixture () in
  let x = Filename.concat root "x" in
  Node.mkdir_p (Filename.concat x "y");
  for i = 0 to 7 do
    Out_channel.with_open_bin
      (Filename.concat x (Printf.sprintf "e%d.txt" i))
      ignore
  done;
  let opens = ref 0 in
  let j =
    {
      (Sources.default_judging ()) with
      Sources.temp_roots = [];
      system_roots = [];
      max_entries = 5;
      opendir =
        (fun d ->
          if d = x then (
            incr opens;
            if !opens > 1 then
              raise (Unix.Unix_error (Unix.EACCES, "opendir", d)));
          Unix.opendir d);
      gave_up = (fun _ _ -> ());
    }
  in
  let memo = Hashtbl.create 8 in
  let capped =
    try
      ignore (Sources.read_entries ~memo j x);
      None
    with Sources.Cannot_judge (_, why) -> Some why
  in
  Alcotest.(check bool) "the listing is capped" true (capped = Some Sources.Cap);
  let decode () =
    snd
      (Sources.decode_judged ~root ~memo ~cache:(Hashtbl.create 8) ~judging:j
         "-x-y")
  in
  Alcotest.(check bool)
    "the refusal is the reason" true
    (decode () = [ Sources.Permission ]);
  Alcotest.(check bool)
    "and still the reason when the folder is not opened again" true
    (decode () = [ Sources.Permission ]);
  Alcotest.(check int) "it is opened once after the cap" 2 !opens

(* A clone that cannot be judged is not offered, and nothing is stored for it, so the next scan
   reads it again. *)
let machine_scan_cannot_judge () =
  let home = fixture () in
  let d = Filename.concat home "code/app" in
  Node.mkdir_p (Filename.concat d ".git");
  write_file
    (Filename.concat d ".git/config")
    [ {|[remote "origin"]|}; "\turl = https://github.com/o/app.git" ];
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
      Store.init n.log;
      let check_none what (repos, found, _) =
        Alcotest.(check int)
          (what ^ ": it is not offered")
          0 (List.length repos);
        Alcotest.(check int) (what ^ ": nor found") 0 (List.length found);
        Alcotest.(check bool)
          (what ^ ": and no row is stored for it")
          false
          (Hashtbl.mem (Store.Scan_index.clones n.log) d)
      in
      (* The handling of a clone the reader gives up on. *)
      let read_clone ~stamp:_ dir =
        raise (Sources.Cannot_judge (dir, Sources.Read_error))
      in
      check_none "injected" (Machine_scan.discover_indexed ~read_clone n.log);
      (* Through the default reader: a folder over a small cap cannot be judged. *)
      for i = 1 to 8 do
        write_file (Filename.concat d (Printf.sprintf "f%d.txt" i)) [ "x" ]
      done;
      let judging = { (Sources.default_judging ()) with max_entries = 5 } in
      check_none "default reader" (Machine_scan.discover_indexed ~judging n.log);
      (* Read once the folder is within the cap. *)
      let repos, _, _ =
        Machine_scan.discover_indexed
          ~judging:{ (Sources.default_judging ()) with max_entries = 100 }
          n.log
      in
      Alcotest.(check int)
        "and offered once it can be judged" 1 (List.length repos))

(* A project directory's name decodes to the paths it can name that exist. *)
let project_dirs () =
  let root = fixture () in
  let mk p = Node.mkdir_p (Filename.concat root p) in
  mk "Users/member/code/my-app/.git";
  mk "Users/member/code/my/app";
  mk "Users/member/.hidden/tool";
  mk "Users/member/src/other";
  let decode n =
    Sources.decode_project_dir ~root n
    |> List.map (fun p ->
        String.sub p (String.length root) (String.length p - String.length root))
  in
  Alcotest.(check (list string))
    "an ambiguous dash: every existing reading"
    [ "/Users/member/code/my/app"; "/Users/member/code/my-app" ]
    (decode "-Users-member-code-my-app");
  Alcotest.(check (list string))
    "a dot is a dash too"
    [ "/Users/member/.hidden/tool" ]
    (decode "-Users-member--hidden-tool");
  Alcotest.(check (list string))
    "a path that does not exist" []
    (decode "-Users-member-code-gone");
  Alcotest.(check (list string)) "not a path" [] (decode "notapath");
  Alcotest.(check (list string))
    "one dash per UTF-16 code unit"
    [ "caf-"; "--x"; "a-b"; "-" ]
    (List.map Sources.encode_segment
       [ "caf\xc3\xa9"; "\xf0\x9f\x93\x92x"; "a\xffb"; "\xe2\x82\xac" ]);
  let home = fixture () in
  let repo = Filename.concat home "Claude/Projects/fetcher" in
  Node.mkdir_p (Filename.concat repo ".git");
  Node.mkdir_p (Filename.concat home "Claude/Projects/notes");
  List.iter
    (fun p ->
      Node.mkdir_p
        (Filename.concat home
           (".claude/projects/" ^ Sources.encode_segment ("/" ^ p))))
    [ "Claude/Projects/fetcher"; "Claude/Projects/notes"; "Claude/gone" ];
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  let repos =
    Fun.protect
      ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
      (Sources.discover_repos ~root:home)
  in
  Alcotest.(check (list string))
    "a repository Claude Code worked in, outside the usual folders" [ repo ]
    repos;
  (* A repository holding a person's books is never proposed, whether the ledger is at its top or
     one level down, and whatever case its suffix is in. *)
  let books = Filename.concat home "code/books" in
  let exports = Filename.concat home "code/exports" in
  let app = Filename.concat home "code/payments-app" in
  List.iter
    (fun d -> Node.mkdir_p (Filename.concat d ".git"))
    [ books; exports; app ];
  Out_channel.with_open_bin (Filename.concat books "main.beancount") ignore;
  Node.mkdir_p (Filename.concat exports "2026");
  Out_channel.with_open_bin (Filename.concat exports "2026/Checking.QFX") ignore;
  Out_channel.with_open_bin (Filename.concat app "ledger.ts") ignore;
  Unix.putenv "HOME" home;
  let repos =
    Fun.protect
      ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
      (Sources.discover_repos ~root:home)
  in
  Alcotest.(check (list string))
    "books are never proposed; software that handles money is"
    (List.sort compare [ app; repo ])
    (List.sort compare repos)

(* Every discovered repository is offered, however many there are and wherever its name sorts, and
   the read skips a repository whose HEAD has not moved in the window. *)
let many_repos () =
  let home = tmpdir () in
  let code = Filename.concat home "code" in
  for i = 0 to 44 do
    Node.mkdir_p (Filename.concat code (Printf.sprintf "a%02d/.git" i))
  done;
  let git repo args =
    let cmd =
      String.concat " "
        ([
           "git";
           "-C";
           Filename.quote repo;
           "-c";
           "user.name=t";
           "-c";
           "user.email=t@example.com";
         ]
        @ List.map Filename.quote args)
      ^ " >/dev/null 2>&1"
    in
    Alcotest.(check int) ("git " ^ String.concat " " args) 0 (Sys.command cmd)
  in
  let real name subject =
    let repo = Filename.concat code name in
    Node.mkdir_p repo;
    git repo [ "init"; "-q" ];
    git repo [ "commit"; "-q"; "--allow-empty"; "-m"; subject ];
    repo
  in
  let quiet = real "quiet" "Committed today, HEAD untouched since" in
  let active = real "zz-active" "Ship the active repo" in
  let reflog = Filename.concat quiet ".git/logs/HEAD" in
  let old = Unix.gettimeofday () -. (3. *. 86400.) in
  Unix.utimes reflog old old;
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  let repos =
    Fun.protect
      ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
      Sources.discover_repos
  in
  Alcotest.(check int) "every repository is kept" 47 (List.length repos);
  Alcotest.(check (option string))
    "the one that sorts last is among them" (Some active)
    (List.nth_opt repos (List.length repos - 1));
  Alcotest.(check (list string))
    "only the repository whose HEAD moved is read"
    [ "commit: Ship the active repo" ]
    (Sources.extract [ Sources.git_source repos ])

(* The member experience's operations (DES-37265): each is routed, and a row not yet built answers
   501 not_built naming its issue rather than 404, so the UI can tell the two apart. *)
(* ISS-87810 (DES-85466, A signer-set change): GET /signers answers the set the update state holds,
   each key's revocation and the halt; this machine's admin, named by signer.json's public_key,
   reads as one and gets Invites halted while a revoked key is in the set, settled once it lifts. *)
let signers_and_the_halt () =
  let module U = Digestif_update in
  let n = demo () in
  let c = session n in
  let release n =
    Crypto.signing_key_of_seed_exn (String.make 32 (Char.chr n))
  in
  let a = release 1 and b = release 2 and d = release 3 in
  let signer name k : U.Release.signer = { name; key = Keys.public k } in
  let path = U.Schedule.state_path n.Node.dir in
  let save signers revoked =
    U.State.save path { (U.State.initial ()) with trust = { signers; revoked } }
  in
  save [ signer "Ann" a; signer "Bo" b ] [];
  let st, j = call n c "signers" in
  Alcotest.(check int) "signers" 200 st;
  Alcotest.(check (list string))
    "the folded set" [ "Ann"; "Bo" ]
    (List.map (s "name") (list (member "signers" j)));
  Alcotest.(check bool) "not halted" false (member "halted" j = `Bool true);
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let role () = s "role" (snd (call n c ("members/" ^ me))) in
  Alcotest.(check string) "no signer.json: a member" "member" (role ());
  let config = Filename.concat (Sys.getenv "XDG_CONFIG_HOME") "digestif" in
  (try Unix.mkdir config 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let signer_json = Filename.concat config "signer.json" in
  Out_channel.with_open_bin signer_json (fun oc ->
      Printf.fprintf oc {|{ "key_command": "true", "public_key": %S }|}
        (Keys.public a));
  Fun.protect
    ~finally:(fun () -> Sys.remove signer_json)
    (fun () ->
      Alcotest.(check string)
        "this machine's key is in the set: admin" "admin" (role ());
      let j = snd (call n c "signers") in
      Alcotest.(check bool)
        "the set ties Ann's key to this member" true
        (List.exists
           (fun k -> s "name" k = "Ann" && member "member" k <> `Null)
           (list (member "signers" j)));
      let halted () =
        Log.rows n.log
          "SELECT title, done FROM ui_items WHERE subject = 'invites_halted'" []
        |> List.map (function
          | [| t; d |] -> (Log.text t, Log.text_opt d <> None)
          | _ -> ("", false))
      in
      let now = Unix.gettimeofday () in
      Digest_lines.raise_notices n ~now;
      Alcotest.(check int) "no halt, no notice" 0 (List.length (halted ()));
      save [ signer "Ann" a; signer "Bo" b ] [ Keys.public b ];
      let j = snd (call n c "signers") in
      Alcotest.(check bool) "halted" true (member "halted" j = `Bool true);
      Alcotest.(check bool)
        "Bo reads revoked" true
        (List.exists
           (fun k -> s "name" k = "Bo" && member "revoked" k = `Bool true)
           (list (member "signers" j)));
      Digest_lines.raise_notices n ~now;
      Digest_lines.raise_notices n ~now;
      Alcotest.(check (list (pair string bool)))
        "one Invites halted notice, open"
        [ ("Invites halted: Bo's key is revoked", false) ]
        (halted ());
      save [ signer "Ann" a; signer "Dee" d ] [ Keys.public b ];
      Digest_lines.raise_notices n ~now;
      Alcotest.(check (list (pair string bool)))
        "settled once the set without Bo is adopted"
        [ ("Invites halted: Bo's key is revoked", true) ]
        (halted ()))

let member_experience_routes () =
  let n = demo () in
  let c = session n in
  Alcotest.(check int)
    "ISS-52609's Inbox is built: an unknown item is not found" 404
    (fst (call n c "items/i1"));
  Alcotest.(check int)
    "ISS-52611's Inbox agent is built: a node with no agent has none" 404
    (fst (call n c "settings/inbox_agent"));
  Alcotest.(check int)
    "ISS-38782's Notes are built: an unknown note is not found" 404
    (fst (call n c "notes/n1"));
  (* The signer set (DES-85466) is built (ISS-87810), as are the approvals. *)
  Alcotest.(check int)
    "ISS-87810's signer set is built" 200
    (fst (call n c "signers"));
  Alcotest.(check int)
    "ISS-38777's Log is built: an unknown note is not found" 404
    (fst (call n c "notes/n1/log"));
  Alcotest.(check int)
    "ISS-38783's problem record is built" 200
    (fst (call n c "problems?open=true"));
  Alcotest.(check int)
    "ISS-38778's repositories are built" 200
    (fst (call n c "organizations"));
  (* What is built already answers as before. *)
  let st, deny = call n c "rules/deny" in
  Alcotest.(check int) "deny list" 200 st;
  Alcotest.(check int)
    "the deny list is the one the rules carry"
    (List.length (list (member "deny" (snd (call n c "rules")))))
    (List.length (list deny));
  Alcotest.(check int) "status" 200 (fst (call n c "status"));
  let st, members = call n c "members" in
  Alcotest.(check int) "members" 200 st;
  Alcotest.(check bool) "members listed" true (list members <> []);
  Alcotest.(check bool) "feed listed" true (list (snd (call n c "feed")) <> [])

(* The setup chat's subcommands (docs/design.md, The setup chat and the first note). *)
let fresh () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  ignore (ok (Node.init n ~phrase:(Phrase.generate ())));
  n

let next n = Option.map Store.Setup.item_name (Store.Setup.next n.Node.log)

let refused what = function
  | Error (_ : string) -> ()
  | Ok _ -> Alcotest.fail (what ^ " should be refused")

(* The optional Inbox step (ISS-80140): next after the brief, never holding back the first note,
   saved into the config Settings, Inbox agent saves, and reported by setup found. *)
let setup_chat_inbox n dir =
  let step () =
    match Setup_chat.found n ~invited_name:None with
    | `Assoc f -> List.assoc "inbox" f
    | _ -> Alcotest.fail "found is an object"
  in
  Alcotest.(check (option string)) "then the Inbox step" (Some "inbox") (next n);
  Alcotest.(check bool)
    "not reached" true
    (member "step" (step ()) = `String "not_reached");
  ignore (ok (Setup_chat.ready_for_first_note n));
  refused "an empty prompt" (Setup_chat.save_inbox n "  ");
  refused "no agent to read under it" (Setup_chat.save_inbox n "File work.");
  Alcotest.(check (option string))
    "a refusal saves nothing" (Some "inbox") (next n);
  let claude = Filename.concat dir "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let prompts =
    Filename.concat (Filename.concat n.dir "good") "behaviors/prompts"
  in
  Node.mkdir_p prompts;
  let default = "Read what reaches me.\n" in
  Out_channel.with_open_bin (Filename.concat prompts "inbox.md") (fun oc ->
      output_string oc default);
  Alcotest.(check bool)
    "the prompt it reads under now" true
    (member "prompt" (step ()) = `String default
    && member "is_default" (step ()) = `Bool true);
  (* A filing command is tested without filing: worked or the error, never the output. *)
  let probe = script dir "probe" "echo secret queue\nexit 0" in
  let broken = script dir "broken" "echo not signed in >&2\nexit 4" in
  (match Setup_chat.check_filing [ probe; "list" ] with
  | Ok line ->
      Alcotest.(check string) "worked" "Worked. Nothing was filed." line
  | Error e -> Alcotest.fail e);
  (match Setup_chat.check_filing [ broken ] with
  | Error e ->
      Alcotest.(check bool)
        "the error and its exit" true
        (contains e "not signed in" && contains e "exit 4")
  | Ok _ -> Alcotest.fail "a broken filing command is caught");
  refused "a program by its name" (Setup_chat.check_filing [ "gh" ]);
  ignore (ok (Setup_chat.skip_inbox n));
  Alcotest.(check bool)
    "skipped" true
    (member "step" (step ()) = `String "skipped");
  Alcotest.(check (option string))
    "skipping keeps the default" (Some default)
    (Log.get_config n.log Api.Inbox_agent.k_prompt);
  Alcotest.(check (option string))
    "a skipped step is not asked again" (Some "first_note") (next n);
  let mine =
    default ^ "File good ideas with gh issue create --repo acme/app.\n"
  in
  ignore (ok (Setup_chat.save_inbox n mine));
  Alcotest.(check bool) "done" true (member "step" (step ()) = `String "done");
  Alcotest.(check (option string))
    "the config Settings saves" (Some mine)
    (Log.get_config n.log Api.Inbox_agent.k_prompt);
  Alcotest.(check bool)
    "theirs now" true
    (member "is_default" (step ()) = `Bool false)

let setup_chat () =
  let n = fresh () in
  let dir = tmpdir () in
  Log.set_config n.log Sources.k_fixed "1";
  Store.set_offered n.log
    [
      Sources.git_source [ "/home/x/code/app" ];
      Sources.claude_source [ "/home/x/.claude/projects" ];
    ];
  let found_next () =
    match Setup_chat.found n ~invited_name:(Some "Dana Ruiz") with
    | `Assoc f -> (List.assoc "next" f, List.assoc "names" f)
    | _ -> Alcotest.fail "found is an object"
  in
  Alcotest.(check (option string)) "names first" (Some "names") (next n);
  (match found_next () with
  | `String "names", `Assoc names ->
      Alcotest.(check bool)
        "the invite's name is proposed" true
        (List.assoc "member_name" names = `String "Dana Ruiz")
  | _ -> Alcotest.fail "found says names next");
  refused "the first note before the names" (Setup_chat.start_first_note n);
  refused "reading before the sources are saved"
    (Setup_chat.read n ~now:(Unix.gettimeofday ()));
  refused "an empty name"
    (Setup_chat.save_names n ~name:" " ~agent_name:"Wren"
       ~email:"dana@example.com");
  refused "no digest email"
    (Setup_chat.save_names n ~name:"Dana Ruiz" ~agent_name:"Wren" ~email:" ");
  refused "not an address"
    (Setup_chat.save_names n ~name:"Dana Ruiz" ~agent_name:"Wren"
       ~email:"dana example.com");
  Alcotest.(check (option string))
    "a refusal saves nothing" (Some "names") (next n);
  ignore
    (ok
       (Setup_chat.save_names n ~name:"Dana Ruiz" ~agent_name:"Wren"
          ~email:" dana@example.com "));
  Alcotest.(check (option string))
    "the digest email, trimmed" (Some "dana@example.com")
    (Digestif_daily.Daily_digest.email n);
  Alcotest.(check (option string)) "then sources" (Some "sources") (next n);
  refused "no sources" (Setup_chat.save_sources n ~all:false ~ids:[]);
  refused "an unknown source"
    (Setup_chat.save_sources n ~all:false ~ids:[ "mail" ]);
  refused "still reading nothing"
    (Setup_chat.read n ~now:(Unix.gettimeofday ()));
  ignore (ok (Setup_chat.save_sources n ~all:true ~ids:[]));
  Alcotest.(check (option string)) "then the brief" (Some "brief") (next n);
  (* A command source: the test answers a count or the error and never the output. *)
  let good = script dir "good" "echo secret line\necho another" in
  let bad = script dir "bad" "echo no such thing >&2\nexit 2" in
  let now = Unix.gettimeofday () in
  (match Setup_chat.add_command n ~now ~label:"Athena" ~command:[ bad ] with
  | Error e ->
      Alcotest.(check bool) "the error" true (contains e "no such thing");
      Alcotest.(check bool) "its exit" true (contains e "exit 2")
  | Ok _ -> Alcotest.fail "a failing command is not saved");
  Alcotest.(check bool)
    "nothing saved" false
    (List.exists
       (fun (x : Store.source) -> x.id = "command-athena")
       (Store.sources n.log));
  (match Setup_chat.add_command n ~now ~label:"Athena" ~command:[ good ] with
  | Ok line ->
      Alcotest.(check string) "a line count" "Worked, 2 lines. Saved." line;
      Alcotest.(check bool) "no output" false (contains line "secret")
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "saved and chosen" true
    (List.exists
       (fun (x : Store.source) -> x.id = "command-athena" && x.selected)
       (Store.sources n.log));
  ignore (ok (Setup_chat.read n ~now));
  (* Rules and the deny list, from the chat. *)
  Alcotest.(check string)
    "says so" "Saved as a rule: Never mention customer names."
    (ok (Setup_chat.add_rule n "Never mention customer names."));
  Alcotest.(check bool)
    "in Rules" true
    (contains (Store.rules n.log).text "Never mention customer names.");
  Alcotest.(check string)
    "says so" "Added to your deny list: Northwind."
    (ok (Setup_chat.add_deny n ~kind:"name" "Northwind"));
  Alcotest.(check bool)
    "on the deny list" true
    (List.exists
       (fun (e : Store.deny_entry) -> e.value = "Northwind")
       (Store.deny_list n.log));
  refused "a kind that is not one" (Setup_chat.add_deny n ~kind:"x" "y");
  refused "an empty brief" (Setup_chat.save_brief n "  ");
  ignore (ok (Setup_chat.save_brief n "Backend engineer."));
  setup_chat_inbox n dir;
  Alcotest.(check (option string))
    "then the first note" (Some "first_note") (next n);
  ignore (ok (Setup_chat.start_first_note n));
  Alcotest.(check (option string)) "nothing left" None (next n);
  Alcotest.(check bool)
    "the node is told" true
    (Store.nightly_run_requested n.log);
  Store.clear_nightly_run n.log;
  ignore (ok (Setup_chat.start_first_note n));
  Alcotest.(check bool) "started once" false (Store.nightly_run_requested n.log);
  let last ~browser ~phrase_shown =
    Setup_chat.last_words ~cli:"~/.local/bin/digestif" ~browser ~host:"h"
      ~phrase_shown
  in
  (match last ~browser:true ~phrase_shown:true with
  | [ first; close; phrase ] ->
      Alcotest.(check bool)
        "setup is done, and the note is approved in the browser" true
        (contains first "Setup is done" && contains first "approve");
      Alcotest.(check string)
        "one plain line: close now, the service writes it, how to open it later"
        "You can close this window now: the Digestif service on this machine \
         writes the note in the background, not this chat. To open Digestif \
         later: ~/.local/bin/digestif open"
        close;
      Alcotest.(check bool)
        "the phrase shown is named" true
        (contains phrase "recovery phrase is still in this window")
  | _ -> Alcotest.fail "three last lines");
  (match last ~browser:true ~phrase_shown:false with
  | [ _; close ] ->
      Alcotest.(check bool)
        "no phrase shown: none is claimed" false (contains close "phrase");
      Alcotest.(check bool)
        "the window can close at once" true
        (contains close "close this window now" && contains close "service")
  | _ -> Alcotest.fail "two last lines");
  match last ~browser:false ~phrase_shown:false with
  | [ _; tunnel; close ] ->
      Alcotest.(check bool)
        "no browser: a link and the tunnel" true
        (contains tunnel "~/.local/bin/digestif open --print"
        && contains tunnel "ssh -L 7420:127.0.0.1:7420 h");
      Alcotest.(check bool) "no phrase claimed" false (contains close "phrase")
  | _ -> Alcotest.fail "three last lines"

let setup_prompt () =
  let p =
    Setup_chat.prompt
      ~text:"run {{digestif}} setup found.\n{{always_on_rules}}\n"
      ~rule:"Never touch money.\n" ~digestif:"/x/digestif"
  in
  Alcotest.(check string)
    "both filled in" "run /x/digestif setup found.\nNever touch money.\n" p

(* The first note is a note page from the setup chat starting it: status.first_note names it, its
   page shows the run's progress until the hand-over fills it, and Notes lists it only then. *)
let first_note_states () =
  let n = fresh () in
  let c = session n in
  let status () = snd (call n c "status") in
  let first_run () = member "first_run" (status ()) = `Bool true in
  Alcotest.(check bool) "hidden from the start" true (first_run ());
  Alcotest.(check bool)
    "no first note yet" true
    (member "first_note" (status ()) = `Null);
  Store.Setup.start_first_note n.log;
  let id = s "id" (member "first_note" (status ())) in
  Alcotest.(check bool) "it has a page" true (id <> "");
  Alcotest.(check bool)
    "setup is done, so the navigation opens" false (first_run ());
  let page () =
    let st, j = call n c ("notes/" ^ id) in
    Alcotest.(check int) "the note page" 200 st;
    j
  in
  let progress () = member "progress" (page ()) in
  let state () = s "state" (progress ()) in
  Alcotest.(check string) "writing" "writing" (state ());
  Alcotest.(check bool)
    "no version yet" true
    (member "version" (page ()) = `Null);
  Alcotest.(check bool)
    "nothing to edit" true
    (member "can_edit" (page ()) = `Bool false);
  let notes () =
    match member "notes" (snd (call n c "notes")) with `List l -> l | _ -> []
  in
  Alcotest.(check int) "Notes lists no row yet" 0 (List.length (notes ()));
  Alcotest.(check int)
    "nothing waits for the member" 0
    (match member "notes_awaiting_approval" (status ()) with
    | `Int i -> i
    | _ -> -1);
  Alcotest.(check bool)
    "the run is not held by it" true
    (Store.Notes.waiting n.log = []);
  let dir = Filename.concat n.dir "behaviors/nightly" in
  Node.mkdir_p dir;
  Out_channel.with_open_bin (Filename.concat dir "progress.json") (fun oc ->
      output_string oc {|{"step":"reading","sources":["Git repositories"]}|});
  Alcotest.(check string) "its step" "reading" (s "step" (progress ()));
  Alcotest.(check bool)
    "its sources" true
    (member "sources" (progress ()) = `List [ `String "Git repositories" ]);
  let later = Time_fmt.of_unix (Unix.gettimeofday () +. 5.) in
  Store.add_tick n.log ~at:later Store.Quiet;
  Alcotest.(check string) "nothing found" "no_activity" (state ());
  Alcotest.(check bool)
    "Notes says so" true
    (member "no_activity" (snd (call n c "notes")) = `Bool true);
  ignore
    (Store.Problems.report n.log
       ~at:(Time_fmt.of_unix (Unix.gettimeofday () +. 6.))
       ~job:"write_version" ~kind:"signed_out" ());
  Alcotest.(check string) "says why" "failed" (state ());
  Alcotest.(check bool)
    "a message" true
    (contains (s "message" (progress ())) "signed out");
  (* The hand-over fills the same row. *)
  let handed = ok (Api.submit_note_text n "Worked on: the docs.") in
  Alcotest.(check string) "the same note" id handed;
  Alcotest.(check bool) "no progress" true (member "progress" (page ()) = `Null);
  Alcotest.(check string)
    "its text" "Worked on: the docs."
    (s "text" (member "version" (page ())));
  Alcotest.(check int) "Notes lists it" 1 (List.length (notes ()));
  Alcotest.(check bool) "open before it goes out" false (first_run ());
  Alcotest.(check string)
    "status still names it" id
    (s "id" (member "first_note" (status ())))

(* A member whose node never ran the setup chat (it created the circle) and holds notes waiting
   for approval, none of them shared: setup is done, so the navigation is open. ISS-47299 *)
let first_run_creator () =
  let n = fresh () in
  let c = session n in
  let first_run () =
    member "first_run" (snd (call n c "status")) = `Bool true
  in
  Alcotest.(check bool) "a fresh node is in setup" true (first_run ());
  Alcotest.(check bool) "setup is open" false (Store.Setup.finished n.log);
  ignore (ok (Api.submit_note_text n "Worked on: the relay."));
  ignore (ok (Api.submit_note_text n "Worked on: the docs."));
  Alcotest.(check bool)
    "never started through the chat" true
    (Store.Setup.first_note_started n.log = None);
  Alcotest.(check bool) "setup is done" true (Store.Setup.finished n.log);
  Alcotest.(check bool) "the navigation is open" false (first_run ())

(* A first note the checks emptied keeps its row for the next note time to fill. *)
let first_note_emptied () =
  let n = fresh () in
  let c = session n in
  Store.Setup.start_first_note n.log;
  let id = Option.get (Store.Notes.first_id n.log) in
  let handed =
    ok
      (Api.submit_note_text
         ~could_not_finish:("pii", "model_unavailable")
         n "Worked on: x.")
  in
  Alcotest.(check string) "the same note" id handed;
  Store.Notes.delete n.log ~note_id:id;
  Alcotest.(check bool) "the row stays" true (Store.Notes.pending n.log <> None);
  Alcotest.(check int)
    "the page is still there" 200
    (fst (call n c ("notes/" ^ id)));
  let again = ok (Api.submit_note_text n "Worked on: y.") in
  Alcotest.(check string) "the next run fills it" id again;
  let later = ok (Api.submit_note_text n "Worked on: z.") in
  Alcotest.(check bool) "a later note is a new row" true (later <> id)

(* ISS-38778: repositories and commit authors (DES-37265, Repositories). *)

let remotes () =
  let check url expected =
    Alcotest.(check (pair string (list string)))
      url expected
      (Repo_scan.parse_remote url)
  in
  check "https://github.com/Example-Co/Loader.git"
    ("github.com", [ "Example-Co"; "Loader" ]);
  check "git@github.com:example-co/loader.git"
    ("github.com", [ "example-co"; "loader" ]);
  check "ssh://git@GitLab.example.com:2222/group/sub/app"
    ("gitlab.example.com", [ "group"; "sub"; "app" ]);
  check "https://user:secret@github.com/a/b" ("github.com", [ "a"; "b" ]);
  check "/srv/git/thing.git" ("", [ "srv"; "git"; "thing" ]);
  check "file:///srv/git/thing.git" ("", [ "srv"; "git"; "thing" ]);
  let entries =
    Repo_scan.config_entries
      "[core]\n\
       \tbare = false\n\
       [remote \"upstream\"]\n\
       \turl = https://x/u/a\n\
       [remote \"origin\"]\n\
       \turl = git@github.com:o/a.git\n\
       [user]\n\
       \temail = me@example.com\n"
  in
  Alcotest.(check (option string))
    "origin wins" (Some "git@github.com:o/a.git")
    (Repo_scan.remote_url entries);
  Alcotest.(check (option (pair string (option string))))
    "configured user"
    (Some ("me@example.com", None))
    (Repo_scan.user_of entries)

let fresh_log () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  n.log

(* ISS-65273: every relay and the release channel failing together is this machine offline, which
   raises nothing; a relay failing while another relay or the channel answers is the relay's. *)
let sync_health () =
  let module H = Sync_health in
  let module P = Store.Problems in
  let log = fresh_log () in
  let sync_open () =
    List.filter (fun (p : P.problem) -> p.job = "sync") (P.open_ log)
  in
  let down = Some "https://relay.example: could not resolve host" in
  let asked = ref 0 in
  let channel up () =
    incr asked;
    up
  in
  let offline =
    H.judge ~relay_errors:[ down; down ] ~channel_reachable:(channel false)
  in
  Alcotest.(check bool)
    "every relay and the channel down" true (offline = H.Offline);
  H.settle log offline;
  Alcotest.(check int) "offline raises nothing" 0 (List.length (sync_open ()));
  let one_down =
    H.judge ~relay_errors:[ down; None ] ~channel_reachable:(channel false)
  in
  Alcotest.(check bool)
    "one relay down, another up" true
    (one_down = H.Relay_unreachable);
  Alcotest.(check int)
    "the channel is asked only when every relay failed" 1 !asked;
  H.settle log one_down;
  Alcotest.(check (list string))
    "one relay down raises it" [ "relay_unreachable" ]
    (List.map (fun (p : P.problem) -> p.kind) (sync_open ()));
  Alcotest.(check bool)
    "every relay down, the channel up" true
    (H.judge ~relay_errors:[ down; down ] ~channel_reachable:(channel true)
    = H.Relay_unreachable);
  H.settle log H.Offline;
  Alcotest.(check int)
    "offline leaves an open problem open" 1
    (List.length (sync_open ()));
  let reached =
    H.judge ~relay_errors:[ None; None ] ~channel_reachable:(channel false)
  in
  Alcotest.(check bool)
    "every relay reached" true
    (reached = H.Reached_every_relay);
  H.settle log reached;
  Alcotest.(check int)
    "reaching every relay closes it" 0
    (List.length (sync_open ()))

(* A title is read from a transcript's head, never the whole file: a transcript of the last day can
   run to tens of megabytes. ISS-40885 *)
let transcript_head_bounded () =
  let dir = tmpdir () in
  let filler n =
    Printf.sprintf {|{"type":"assistant","message":"%s"}|} (String.make n 'x')
  in
  let titled = Filename.concat dir "titled.jsonl" in
  write_file titled
    ([ {|{"type":"ai-title","aiTitle":"Speed up Settings"}|} ]
    @ List.init 10 (fun _ -> filler 400));
  let head = Option.get (Sources.transcript_head ~max_bytes:1000 titled) in
  Alcotest.(check bool) "at most the bound" true (String.length head <= 1000);
  Alcotest.(check bool)
    "cut back to a whole line" true
    (List.for_all
       (fun l -> l = "" || l.[String.length l - 1] = '}')
       (String.split_on_char '\n' head));
  Alcotest.(check (option string))
    "the title in the head" (Some "Speed up Settings") (Sources.ai_title head);
  let late = Filename.concat dir "late.jsonl" in
  write_file late
    (List.init 10 (fun _ -> filler 400)
    @ [ {|{"type":"ai-title","aiTitle":"Past the bound"}|} ]);
  Alcotest.(check (option string))
    "a title past the bound is not read" None
    (Sources.ai_title
       (Option.get (Sources.transcript_head ~max_bytes:1000 late)));
  let small = Filename.concat dir "small.jsonl" in
  write_file small [ {|{"type":"ai-title","aiTitle":"Short"}|} ];
  Alcotest.(check (option string))
    "a short file is read whole" (Some "Short")
    (Option.bind
       (Sources.transcript_head ~max_bytes:1000 small)
       Sources.ai_title);
  Alcotest.(check (option string))
    "an absent file" None
    (Sources.transcript_head (Filename.concat dir "absent.jsonl"))

(* Settings reads what the machine offers from the stored scan: a read scans only when the node
   never has, and the pass rescans once the scan is older than Machine_scan.max_age. One discovery
   feeds both the sources and the repositories. ISS-40885 *)
let machine_scan_stored () =
  let home = tmpdir () in
  let clone name =
    let d = Filename.concat home ("code/" ^ name) in
    Node.mkdir_p (Filename.concat d ".git");
    d
  in
  let app = clone "app" in
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let n = fresh () in
      let c = session n in
      let git_paths () =
        match
          List.find_opt
            (fun x -> s "id" x = "git")
            (list (snd (call n c "sources")))
        with
        | Some g ->
            List.map Yojson.Safe.Util.to_string (list (member "paths" g))
        | None -> []
      in
      let repo_names () =
        List.map (s "name") (list (snd (call n c "repositories")))
        |> List.sort compare
      in
      Alcotest.(check (list string))
        "the first read scans"
        [ Sources.tilde app ]
        (git_paths ());
      Alcotest.(check (list string))
        "one scan, both lists" [ "app" ] (repo_names ());
      Alcotest.(check (list int))
        "a repository counts its clones" [ 1 ]
        (List.map
           (fun r -> Yojson.Safe.Util.to_int (member "clone_count" r))
           (list (snd (call n c "repositories"))));
      Alcotest.(check (list string))
        "a repository names one clone's path, with ~"
        [ Sources.tilde app ]
        (List.map (s "path") (list (snd (call n c "repositories"))));
      let web = clone "web" in
      Alcotest.(check (list string))
        "a later read rescans nothing"
        [ Sources.tilde app ]
        (git_paths ());
      Alcotest.(check (list string))
        "nor do the repositories" [ "app" ] (repo_names ());
      let at = Option.get (Machine_scan.scanned_at n.log) in
      Alcotest.(check bool)
        "a fresh scan is kept" false
        (Machine_scan.refresh_if_stale
           ~now:(at +. Machine_scan.max_age -. 1.)
           n.log);
      Alcotest.(check bool)
        "an old one is retaken" true
        (Machine_scan.refresh_if_stale ~now:(at +. Machine_scan.max_age) n.log);
      Alcotest.(check (list string))
        "the rescan shows the new clone"
        (List.sort compare [ Sources.tilde app; Sources.tilde web ])
        (List.sort compare (git_paths ()));
      Alcotest.(check (list string))
        "in both lists" [ "app"; "web" ] (repo_names ()));
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let log = n.log in
  Log.set_config log Sources.k_fixed "1";
  let discovered = ref 0 in
  let discover () =
    incr discovered;
    []
  in
  Machine_scan.ensure ~discover ~now:0. n;
  Machine_scan.ensure ~discover ~spawn:(fun f -> f log) ~now:1e9 n;
  Alcotest.(check bool)
    "a node set by hand is never scanned" false
    (Machine_scan.refresh_if_stale ~discover ~now:1e9 log);
  Alcotest.(check int) "discovery never ran" 0 !discovered

(* Discovery reads the disk and runs git with the store unheld: while a clone is read, another
   connection to the log takes the write lock at once, so a request answering during a scan never
   waits for it, let alone answers BUSY. What the scan read is still stored. ISS-48148 *)
let machine_scan_holds_no_lock () =
  let home = tmpdir () in
  let d = Filename.concat home "code/app" in
  Node.mkdir_p (Filename.concat d ".git");
  write_file
    (Filename.concat d ".git/config")
    [ {|[remote "origin"]|}; "\turl = https://github.com/o/app.git" ];
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
      Store.init n.log;
      let other = Log.open_ (Node.log_path n.dir) in
      Fun.protect
        ~finally:(fun () -> Log.close other)
        (fun () ->
          Sqlite3.busy_timeout other.db 0;
          let during = ref [] in
          let read_clone ~stamp dir =
            during :=
              Sqlite3.exec other.db "BEGIN IMMEDIATE; COMMIT;" :: !during;
            Machine_scan.read_clone ~stamp dir
          in
          let repos, found, _ =
            Machine_scan.discover_indexed ~read_clone n.log
          in
          Alcotest.(check (list string))
            "another connection writes while a clone is read" [ "OK" ]
            (List.map Sqlite3.Rc.to_string !during);
          Alcotest.(check int) "the clone is found" 1 (List.length found);
          Alcotest.(check int) "and offered" 1 (List.length repos);
          Alcotest.(check bool)
            "and stored in the index" true
            (Hashtbl.mem (Store.Scan_index.clones n.log) d)))

(* The machine scan rereads only what changed since the last one: an unchanged clone or Claude Code
   project is answered from the index, and a clone whose remote moved, that gained books in one of
   its folders, or that is gone is read again. ISS-41944 *)
let machine_scan_incremental () =
  let home = fixture () in
  let old = Unix.gettimeofday () -. 86400. in
  let rec settle p =
    Unix.utimes p old old;
    if Sys.is_directory p then
      Array.iter (fun c -> settle (Filename.concat p c)) (Sys.readdir p)
  in
  let config d url =
    write_file
      (Filename.concat d ".git/config")
      [ {|[remote "origin"]|}; "\turl = " ^ url ]
  in
  let clone name =
    let d = Filename.concat home ("code/" ^ name) in
    Node.mkdir_p (Filename.concat d ".git");
    Node.mkdir_p (Filename.concat d "docs");
    config d ("https://github.com/o/" ^ name ^ ".git");
    d
  in
  let app = clone "app" and web = clone "web" and api = clone "api" in
  let projects = Filename.concat home ".claude/projects" in
  (* The project's name is the clone's path from the home, which is the decoding's root. *)
  let from_home d =
    String.sub d (String.length home) (String.length d - String.length home)
  in
  Node.mkdir_p
    (Filename.concat projects (Sources.encode_segment (from_home app)));
  settle home;
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let log = fresh_log () in
      let pass () =
        Option.get (Machine_scan.scan_stats ~root:home ~now:1000. log)
      in
      let names () =
        Store.Repositories.repositories log ~limit:50
        |> List.map (fun (r : Store.Repositories.repository) -> r.r_id)
        |> List.sort compare
      in
      let first = pass () in
      Alcotest.(check (pair int int))
        "the first pass reads every clone and project" (3, 1)
        (first.clones_read, first.projects_read);
      let again = pass () in
      Alcotest.(check (list int))
        "an unchanged machine rereads nothing" [ 0; 3; 0; 1 ]
        [
          again.clones_read;
          again.clones_kept;
          again.projects_read;
          again.projects_kept;
        ];
      config web "https://github.com/o/www.git";
      write_file (Filename.concat api "docs/books.beancount") [ "; books" ];
      let changed = pass () in
      Alcotest.(check (pair int int))
        "a moved remote and new books are reread, the rest kept" (2, 1)
        (changed.clones_read, changed.clones_kept);
      Alcotest.(check (list string))
        "the remote's new repository is found, the clone with books is not \
         offered"
        [
          "github.com/o/api";
          "github.com/o/app";
          "github.com/o/web";
          "github.com/o/www";
        ]
        (names ());
      let git_paths =
        List.concat_map
          (fun (s : Store.source) -> if s.id = "git" then s.paths else [])
          (Store.sources log)
      in
      Alcotest.(check (list string))
        "the git source offers the clones without books"
        [ Sources.tilde app; Sources.tilde web ]
        (List.sort compare git_paths);
      let rec rm p =
        if Sys.is_directory p then begin
          Array.iter (fun c -> rm (Filename.concat p c)) (Sys.readdir p);
          Unix.rmdir p
        end
        else Sys.remove p
      in
      rm app;
      let gone = pass () in
      Alcotest.(check (list int))
        "a clone that is gone leaves the index, and its project is reread"
        [ 0; 2; 1 ]
        [ gone.clones_read; gone.clones_kept; gone.projects_read ];
      Alcotest.(check int)
        "the index holds the two left" 2
        (List.length (Log.rows log "SELECT path FROM ui_scan_clones" [])))

(* The notes, members and deny lists read one page at a time: walking them a row at a time by
   cursor reads exactly the list in its order, and a limit out of range or a cursor the node does
   not hold answers 422 (the Inbox's own paging: inbox_delivery_and_statuses). ISS-41988 *)
let list_pages () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let rows ~key path =
    let j = snd (call path) in
    match key with Some k -> list (member k j) | None -> list j
  in
  let walk ?key ~id path =
    let sep = if String.contains path '?' then "&" else "?" in
    let rec go cursor acc =
      let page =
        rows ~key
          (path ^ sep ^ "limit=1"
          ^ match cursor with Some c -> "&cursor=" ^ enc c | None -> "")
      in
      match page with
      | [] -> List.rev acc
      | [ r ] -> go (Some (s id r)) (s id r :: acc)
      | _ -> Alcotest.failf "%s answered more than its limit" path
    in
    go None []
  in
  let add value =
    ignore
      (call ~meth:"POST"
         ~body:(`Assoc [ ("kind", `String "name"); ("value", `String value) ])
         "rules/deny")
  in
  add "Yan";
  List.iter
    (fun (path, key, id) ->
      let full = List.map (s id) (rows ~key path) in
      Alcotest.(check bool)
        (path ^ " has rows to page")
        true
        (List.length full > 1);
      Alcotest.(check (list string))
        (path ^ " by cursor") full (walk ?key ~id path);
      Alcotest.(check int)
        (path ^ ": limit 0") 422
        (fst
           (call
              (path
              ^ (if String.contains path '?' then "&" else "?")
              ^ "limit=0")));
      Alcotest.(check int)
        (path ^ ": an unknown cursor")
        422
        (fst
           (call
              (path
              ^ (if String.contains path '?' then "&" else "?")
              ^ "cursor=nope"))))
    [
      ("notes", Some "notes", "id");
      ("members", None, "identity");
      ("rules/deny", None, "id");
    ];
  add "Zed";
  Alcotest.(check string)
    "an entry added since is on the last page" "Zed"
    (s "value"
       (List.nth
          (rows ~key:None "rules/deny")
          (List.length (rows ~key:None "rules/deny") - 1)))

(* A data directory from before the lists read by cursor gains each row's sort key once, and its
   pages read in the order they always did. ISS-41944 *)
let sort_keys_backfilled () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  let log = n.log in
  List.iter
    (fun sql -> Log.exec log sql [])
    [
      "CREATE TABLE ui_organizations (id TEXT PRIMARY KEY, name TEXT NOT NULL, \
       choice TEXT NOT NULL, found_at TEXT NOT NULL)";
      "CREATE TABLE ui_repositories (id TEXT PRIMARY KEY, organization_id TEXT \
       NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL, found_at TEXT NOT \
       NULL, paths TEXT NOT NULL)";
      "INSERT INTO ui_organizations VALUES ('github.com/zed', 'Zed', 'all', \
       'x'), ('github.com/acme', 'acme', 'all', 'x')";
      "INSERT INTO ui_repositories VALUES ('github.com/zed/b', \
       'github.com/zed', 'b', 'approved', 'x', '[]'), ('github.com/acme/Web', \
       'github.com/acme', 'Web', 'approved', 'x', '[]'), \
       ('github.com/acme/api', 'github.com/acme', 'api', 'approved', 'x', \
       '[]')";
    ];
  Store.init log;
  let module R = Store.Repositories in
  Alcotest.(check (list string))
    "organizations by name, case aside" [ "acme"; "Zed" ]
    (List.map (fun (o : R.organization) -> o.o_name) (R.organizations log));
  let ids l = List.map (fun (r : R.repository) -> r.r_id) l in
  Alcotest.(check (list string))
    "repositories by organization, then name"
    [ "github.com/acme/api"; "github.com/acme/Web"; "github.com/zed/b" ]
    (ids (R.repositories log ~limit:10));
  Alcotest.(check (list string))
    "and after a cursor" [ "github.com/zed/b" ]
    (ids (R.repositories log ~after:"github.com/acme/Web" ~limit:10))

(* A node running digestif ui with no digestif run daemon has no pass to rescan it, so a page's read
   retakes a scan older than Machine_scan.read_max_age, in the background: the read answers from
   the stored scan and the next one sees the clone made since. ISS-41767 *)
let machine_scan_read_rescans () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let found = ref [ "~/code/app" ] in
  let discovered = ref 0 in
  let discover () =
    incr discovered;
    List.map Sources.untilde !found
  in
  let spawned = ref [] in
  let spawn f = spawned := f :: !spawned in
  let run_spawned () =
    List.iter (fun f -> f n.log) !spawned;
    spawned := []
  in
  Machine_scan.ensure ~discover ~spawn ~now:1000. n;
  Alcotest.(check int)
    "a node that never scanned scans in the read" 1 !discovered;
  Alcotest.(check int) "and spawns nothing" 0 (List.length !spawned);
  found := [ "~/code/app"; "~/code/web" ];
  Machine_scan.ensure ~discover ~spawn
    ~now:(1000. +. Machine_scan.read_max_age -. 1.)
    n;
  Alcotest.(check int)
    "a scan younger than a day is read as it stands" 0 (List.length !spawned);
  let at = 1000. +. Machine_scan.read_max_age in
  Machine_scan.ensure ~discover ~spawn ~now:at n;
  Alcotest.(check int)
    "an older one is retaken in the background" 1 (List.length !spawned);
  Alcotest.(check int) "not in the read" 1 !discovered;
  run_spawned ();
  Alcotest.(check int) "the background rescan discovers" 2 !discovered;
  Alcotest.(check (option (float 0.001)))
    "and records when" (Some at)
    (Machine_scan.scanned_at n.log);
  let paths =
    List.concat_map (fun (s : Store.source) -> s.paths) (Store.sources n.log)
  in
  Alcotest.(check bool)
    "the clone made since is offered" true
    (List.exists (fun p -> Filename.basename p = "web") paths);
  Alcotest.(check bool)
    "a background thread opens its own connection and scans" true
    (match
       Machine_scan.in_background ~running:(Atomic.make false) ~dir:n.dir
         (fun log -> Machine_scan.scan ~discover ~now:(at +. 5.) log)
     with
    | Some th ->
        Thread.join th;
        Machine_scan.scanned_at n.log = Some (at +. 5.)
    | None -> false)

let found ?(org = "github.com/o") ?(org_name = "o") ?(path = "") name :
    Store.Repositories.found =
  {
    f_id = org ^ "/" ^ name;
    f_name = name;
    f_org_id = org;
    f_org_name = org_name;
    f_path = (if path = "" then "~/code/" ^ name else path);
  }

let statuses log =
  Store.Repositories.repositories log ~limit:200 ~offset:0
  |> List.map (fun (r : Store.Repositories.repository) -> (r.r_name, r.status))

let repository_choices () =
  let module R = Store.Repositories in
  let log = fresh_log () in
  R.apply_scan log ~at:"2026-01-01T00:00:00Z"
    [
      found "a";
      found "b";
      found ~path:"~/work/a" "a";
      found ~org:"github.com/p" ~org_name:"p" "c";
    ];
  Alcotest.(check (list (pair string string)))
    "everything the first scan finds starts approved"
    [ ("a", "approved"); ("b", "approved"); ("c", "approved") ]
    (statuses log);
  Alcotest.(check (list string))
    "every clone of one remote is one repository" [ "~/code/a"; "~/work/a" ]
    (Option.get (R.repository log "github.com/o/a")).r_paths;
  Alcotest.(check (list (pair string string)))
    "under All with new ones automatic"
    [ ("o", "all_automatic"); ("p", "all_automatic") ]
    (List.map
       (fun (o : R.organization) -> (o.o_name, o.choice))
       (R.organizations log));
  (* Unchecking under All declines it and keeps the choice. *)
  R.set_status log "github.com/o/b" "declined";
  Alcotest.(check string)
    "the choice is kept" "all_automatic"
    (Option.get (R.organization log "github.com/o")).choice;
  (* Under All with new ones automatic a later repository is approved; under All and Chosen it is
     undecided; an organization first seen later is Chosen. *)
  R.set_choice log "github.com/p" "chosen";
  R.apply_scan log ~at:"2026-02-01T00:00:00Z"
    [
      found "d";
      found ~org:"github.com/p" ~org_name:"p" "e";
      found ~org:"github.com/q" ~org_name:"q" "f";
    ];
  Alcotest.(check (list (pair string string)))
    "a later repository takes its organization's choice"
    [
      ("a", "approved");
      ("b", "declined");
      ("d", "approved");
      ("c", "approved");
      ("e", "undecided");
      ("f", "undecided");
    ]
    (statuses log);
  Alcotest.(check string)
    "a later organization is Chosen" "chosen"
    (Option.get (R.organization log "github.com/q")).choice;
  (* All approves what is undecided and leaves what is declined. *)
  R.set_choice log "github.com/o" "chosen";
  R.set_status log "github.com/o/d" "undecided";
  R.set_choice log "github.com/o" "all";
  Alcotest.(check (list (pair string string)))
    "All approves every repository not declined"
    [ ("a", "approved"); ("b", "declined"); ("d", "approved") ]
    (statuses log |> List.filter (fun (n, _) -> List.mem n [ "a"; "b"; "d" ]));
  Alcotest.(check (list string))
    "only approved clones are read"
    [ "~/code/a"; "~/work/a"; "~/code/d"; "~/code/c" ]
    (R.approved_paths log);
  (* A rescan keeps every status. *)
  R.apply_scan log ~at:"2026-03-01T00:00:00Z" [ found "b" ];
  Alcotest.(check string)
    "declined stays declined" "declined"
    (Option.get (R.repository log "github.com/o/b")).status;
  (* Search matches a repository's or its organization's name; a page is a page. *)
  let names ?q ?status ?organization_id ~limit ~offset () =
    R.repositories log ?q ?status ?organization_id ~limit ~offset
    |> List.map (fun (r : R.repository) -> r.r_name)
  in
  Alcotest.(check (list string))
    "search by organization" [ "f" ]
    (names ~q:"Q" ~limit:50 ~offset:0 ());
  Alcotest.(check (list string))
    "status filter" [ "e"; "f" ]
    (names ~status:"undecided" ~limit:50 ~offset:0 ());
  Alcotest.(check (list string))
    "pagination" [ "d"; "c" ]
    (names ~limit:2 ~offset:2 ())

(* Repositories waiting undecided raise no ask: New repositories is the node's local notice in the
   Inbox (Digest_lines), and the ask store holds only the node's own choices. *)
let repositories_raise_no_ask () =
  let module R = Store.Repositories in
  let log = fresh_log () in
  let q = found ~org:"github.com/q" ~org_name:"q" in
  R.apply_scan log ~at:"2026-02-01T00:00:00Z" [ found "a"; q "c"; q "d" ];
  R.set_status log "github.com/q/c" "declined";
  R.set_choice log "github.com/q" "chosen";
  Alcotest.(check (list string))
    "no ask for the repositories that wait" []
    (List.map (fun (x : Asks.t) -> x.key) (Asks.list ~all:true log))

(* ISS-42314: a repository found after setup records how it turned up, a new clone of a remote or
   a new remote on a folder already scanned, and its last own commit; setup's carry neither. *)
let repository_found_by () =
  let module R = Store.Repositories in
  let log = fresh_log () in
  R.apply_scan log ~at:"2026-01-01T00:00:00Z"
    [ found "a"; found ~path:"~/code/moved" "b" ];
  let r id = Option.get (R.repository log id) in
  Alcotest.(check (option string))
    "setup's repository: no found_by" None (r "github.com/o/a").found_by;
  R.apply_scan log ~at:"2026-02-01T00:00:00Z"
    [
      found "a";
      found ~path:"~/work/a" "a";
      found ~org:"github.com/q" ~org_name:"q" "c";
      found ~org:"github.com/q" ~org_name:"q" ~path:"~/code/moved" "d";
    ];
  Alcotest.(check (option string))
    "a known repository's new clone changes nothing" None
    (r "github.com/o/a").found_by;
  Alcotest.(check int)
    "but it counts the clone" 2
    (List.length (r "github.com/o/a").r_paths);
  Alcotest.(check (option string))
    "a new clone of a new remote" (Some "new_clone")
    (r "github.com/q/c").found_by;
  Alcotest.(check (option string))
    "a folder already scanned under another remote" (Some "new_remote")
    (r "github.com/q/d").found_by;
  Alcotest.(check string)
    "found when the scan ran" "2026-02-01T00:00:00Z"
    (r "github.com/q/d").found_at;
  Alcotest.(check string)
    "stored by its organization's choice" "undecided"
    (r "github.com/q/c").status;
  Alcotest.(check (option string))
    "no own commit read yet" None (r "github.com/q/c").last_own_commit_at;
  R.set_last_own_commit log "github.com/q/c" (Some "2026-01-15T09:00:00.000Z");
  Alcotest.(check (option string))
    "the last own commit is stored" (Some "2026-01-15T09:00:00.000Z")
    (r "github.com/q/c").last_own_commit_at

(* ISS-42314 (DES-37153): a repository found after setup and approved later starts at the 24 hours
   before it was found, not before it was approved, so waiting to answer costs no work. *)
let record_start_found () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let module R = Store.Record in
  let repo = R.repository_key "github.com/q/c" in
  let found_ms = 4_000_000_000 in
  Alcotest.(check (option int))
    "first note: no start, found or not" None
    (R.start n.log ~found_ms ~now_ms:10_000_000_000 repo).start_ms;
  Store.set_config n.log R.k_first_approved "2026-01-01T00:00:00Z";
  R.observe n.log ~now_ms:9_000_000_000 [ repo ];
  Alcotest.(check (option int))
    "found later: the 24 hours before it was found"
    (Some (found_ms - R.fresh_ms))
    (R.start n.log ~found_ms ~now_ms:10_000_000_000 repo).start_ms;
  Alcotest.(check (option int))
    "setup's: the 24 hours before it was approved"
    (Some (9_000_000_000 - R.fresh_ms))
    (R.start n.log ~now_ms:10_000_000_000 repo).start_ms;
  R.set_ends n.log ~note_id:"n1"
    [ (repo, { R.at_ms = 9_500_000_000; sha = Some "abc" }) ];
  R.approve n.log ~note_id:"n1";
  Alcotest.(check (option int))
    "a point wins over both" (Some 9_500_000_000)
    (R.start n.log ~found_ms ~now_ms:10_000_000_000 repo).start_ms

(* ISS-42314: the scan a work run starts with stores a repository cloned since the last scan, by
   its organization's choice, and reads the author date of the member's own newest commit there and
   nothing of anyone else's; the repositories API serves the where-and-how fields. *)
let work_run_scan () =
  let home = tmpdir () in
  let git repo args =
    Alcotest.(check int)
      (String.concat " " args) 0
      (Sys.command
         (String.concat " "
            (List.map Filename.quote ("git" :: "-C" :: repo :: args))
         ^ " >/dev/null 2>&1"))
  in
  let clone ?remote name =
    let d = Filename.concat home ("code/" ^ name) in
    Node.mkdir_p d;
    git d [ "init"; "-q" ];
    Option.iter (fun r -> git d [ "remote"; "add"; "origin"; r ]) remote;
    d
  in
  let commit repo ~who ~at =
    git repo
      [
        "-c";
        "user.email=" ^ who;
        "-c";
        "user.name=" ^ who;
        "commit";
        "-q";
        "--allow-empty";
        "--date=@" ^ string_of_int at;
        "-m";
        who;
      ]
  in
  let _app = clone ~remote:"git@github.com:me/app.git" "app" in
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let module R = Store.Repositories in
      let n = fresh () in
      let global () = Some ("me@example.com", Some "Me") in
      let now = Unix.gettimeofday () in
      ignore (Machine_scan.work_run_scan ~global ~now n.log);
      Alcotest.(check (list (pair string string)))
        "setup approves what it finds"
        [ ("app", "approved") ]
        (statuses n.log);
      let lib = clone ~remote:"https://github.com/acme/lib.git" "lib" in
      commit lib ~who:"me@example.com" ~at:1_700_000_000;
      commit lib ~who:"someone@example.com" ~at:1_750_000_000;
      let other = clone ~remote:"https://github.com/acme/other.git" "other" in
      commit other ~who:"someone@example.com" ~at:1_750_000_000;
      (* The stored scan is fresh: the pass would not rescan, the work run does. *)
      Alcotest.(check bool)
        "the pass keeps a fresh scan" false
        (Machine_scan.refresh_if_stale ~now:(now +. 1.) n.log);
      ignore (Machine_scan.work_run_scan ~global ~now:(now +. 2.) n.log);
      let lib_r = Option.get (R.repository n.log "github.com/acme/lib") in
      Alcotest.(check string)
        "a new organization's: undecided" "undecided" lib_r.status;
      Alcotest.(check (option string))
        "a new clone" (Some "new_clone") lib_r.found_by;
      Alcotest.(check string)
        "found at the work run"
        (Time_fmt.of_unix (now +. 2.))
        lib_r.found_at;
      Alcotest.(check (option string))
        "the member's own newest commit, not a newer one of anyone else's"
        (Some (Time_fmt.of_unix 1_700_000_000.))
        lib_r.last_own_commit_at;
      Alcotest.(check (option string))
        "no own commit: none" None
        (Option.get (R.repository n.log "github.com/acme/other"))
          .last_own_commit_at;
      (* Once the member owns the list, it is whose commits count. *)
      R.propose_authors n.log [ ("someone@example.com", None, "yours") ];
      ignore (Machine_scan.work_run_scan ~global ~now:(now +. 3.) n.log);
      Alcotest.(check (option string))
        "the owned list decides whose commits are the member's"
        (Some (Time_fmt.of_unix 1_750_000_000.))
        (Option.get (R.repository n.log "github.com/acme/other"))
          .last_own_commit_at;
      (* ISS-48149: a HEAD already read is not asked again, nor is a second clone on it, and the
         reading stops at its budget, leaving what it did not reach as it was for the next scan. *)
      let own ?own_budget at =
        (Option.get
           (Machine_scan.work_run_scan ?own_budget ~global ~now:at n.log))
          .own
      in
      let lib2 = Filename.concat home "code/lib2" in
      git home [ "clone"; "-q"; lib; lib2 ];
      git lib2
        [ "remote"; "set-url"; "origin"; "https://github.com/acme/lib.git" ];
      let o = own (now +. 4.) in
      Alcotest.(check (triple int int int))
        "unmoved HEADs, a second clone on one: nothing asked" (0, 2, 0)
        (o.heads_read, o.heads_kept, o.heads_left);
      commit lib ~who:"someone@example.com" ~at:1_760_000_000;
      let o = own ~own_budget:0. (now +. 5.) in
      Alcotest.(check (triple int int int))
        "no budget: the moved HEAD is left" (0, 2, 1)
        (o.heads_read, o.heads_kept, o.heads_left);
      Alcotest.(check (option string))
        "a repository with a HEAD left keeps its answer"
        (Some (Time_fmt.of_unix 1_750_000_000.))
        (Option.get (R.repository n.log "github.com/acme/lib"))
          .last_own_commit_at;
      let o = own (now +. 6.) in
      Alcotest.(check (triple int int int))
        "the next scan reads it" (1, 2, 0)
        (o.heads_read, o.heads_kept, o.heads_left);
      Alcotest.(check (option string))
        "the newest over the repository's clones"
        (Some (Time_fmt.of_unix 1_760_000_000.))
        (Option.get (R.repository n.log "github.com/acme/lib"))
          .last_own_commit_at;
      let c = session n in
      let repos = list (snd (call n c "repositories?status=undecided")) in
      let lib_j = List.find (fun r -> s "name" r = "lib") repos in
      Alcotest.(check string)
        "served: found_by" "new_clone" (s "found_by" lib_j);
      Alcotest.(check bool)
        "served: last_own_commit_at" true
        (member "last_own_commit_at" lib_j <> `Null);
      let app_j =
        List.find
          (fun r -> s "name" r = "app")
          (list (snd (call n c "repositories")))
      in
      Alcotest.(check bool)
        "setup's repository carries no found_by" true
        (member "found_by" app_j = `Null))

let commit_authors_owned () =
  let module R = Store.Repositories in
  let log = fresh_log () in
  R.propose_authors log
    [
      ("Me@Example.com", Some "Me", "yours");
      ("bot@example.com", None, "your_fleet");
    ];
  Alcotest.(check (list (pair string bool)))
    "the proposal enters once, as the scan's"
    [ ("me@example.com", false); ("bot@example.com", false) ]
    (List.map (fun (a : R.author) -> (a.email, a.member_set)) (R.authors log));
  let bot = Option.get (R.author_by_email log "bot@example.com") in
  R.remove_author log bot.a_id;
  let me = Option.get (R.author_by_email log "me@example.com") in
  R.label_author log me.a_id "your_fleet";
  R.propose_authors log
    [
      ("me@example.com", Some "Me", "yours");
      ("bot@example.com", None, "your_fleet");
      ("new@example.com", None, "yours");
    ];
  Alcotest.(check (list (triple string string bool)))
    "a later scan never adds, removes or relabels"
    [ ("me@example.com", "your_fleet", true) ]
    (List.map
       (fun (a : R.author) -> (a.email, a.label, a.member_set))
       (R.authors log));
  Alcotest.(check bool)
    "an email already an author is refused" true
    (R.add_author log ~email:" ME@example.com" ~name:None ~label:"yours"
    = Error `Duplicate)

(* The configured users are Yours and frequent committers Your fleet, read from real clones. *)
let author_proposal () =
  let home = tmpdir () in
  let repo = Filename.concat home "code/app" in
  Node.mkdir_p repo;
  let git args =
    Alcotest.(check int)
      (String.concat " " args) 0
      (Sys.command
         (String.concat " "
            (List.map Filename.quote ("git" :: "-C" :: repo :: args))
         ^ " >/dev/null 2>&1"))
  in
  git [ "init"; "-q" ];
  git [ "config"; "user.email"; "me@example.com" ];
  git [ "config"; "user.name"; "Me" ];
  git [ "remote"; "add"; "origin"; "git@github.com:Example-Co/App.git" ];
  let commit who n =
    for i = 1 to n do
      git
        [
          "-c";
          "user.email=" ^ who;
          "-c";
          "user.name=" ^ who;
          "commit";
          "-q";
          "--allow-empty";
          "-m";
          Printf.sprintf "%s %d" who i;
        ]
    done
  in
  commit "bot@example.com" 10;
  commit "rare@example.com" 2;
  let proposals =
    Repo_scan.propose_authors ~global:None ~now:(Unix.gettimeofday ()) [ repo ]
  in
  Alcotest.(check (list (triple string (option string) string)))
    "configured users and frequent committers"
    [
      ("me@example.com", Some "Me", "yours");
      ("bot@example.com", Some "bot@example.com", "your_fleet");
    ]
    proposals;
  let f = Repo_scan.found_of_clone repo in
  Alcotest.(check (list string))
    "the remote names the repository and organization"
    [
      "github.com/example-co/app"; "App"; "github.com/example-co"; "Example-Co";
    ]
    [ f.f_id; f.f_name; f.f_org_id; f.f_org_name ]

(* DIG-237: a git that never answers (a clone on a mount that hangs) is killed at the proposal's
   deadline and counts nothing, and the read that asks for the proposal waits at most its own bound,
   answering from the store while the proposal is still being read. *)
let author_proposal_bounded () =
  let module R = Store.Repositories in
  let bin = tmpdir () in
  let git = Filename.concat bin "git" in
  Out_channel.with_open_bin git (fun oc ->
      output_string oc "#!/bin/sh\nexec sleep 60\n");
  Unix.chmod git 0o755;
  let n = fresh () in
  let repo = tmpdir () in
  R.apply_scan n.log ~at:"2026-01-01T00:00:00Z" [ found ~path:repo "hung" ];
  let path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (bin ^ ":" ^ path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" path)
    (fun () ->
      let t = Unix.gettimeofday () in
      let proposals =
        Machine_scan.author_proposal ~global:None ~budget:1.
          ~now:(Unix.gettimeofday ()) n.log
      in
      let took = Unix.gettimeofday () -. t in
      Alcotest.(check (list (triple string (option string) string)))
        "a git that never answers counts nothing" [] proposals;
      Alcotest.(check bool)
        (Printf.sprintf "within the deadline (%.1fs)" took)
        true (took < 10.))

let author_proposal_off_request () =
  let module R = Store.Repositories in
  let n = fresh () in
  let proposal ~now:_ _ =
    Thread.delay 0.5;
    [ ("me@example.com", Some "Me", "yours") ]
  in
  let t = Unix.gettimeofday () in
  Machine_scan.propose_authors ~wait:0.05 ~proposal ~now:t n;
  let took = Unix.gettimeofday () -. t in
  Alcotest.(check bool)
    (Printf.sprintf "the read answers at its bound (%.2fs)" took)
    true (took < 0.4);
  Alcotest.(check bool)
    "not proposed while it is read" false (R.authors_proposed n.log);
  let until = Unix.gettimeofday () +. 10. in
  while (not (R.authors_proposed n.log)) && Unix.gettimeofday () < until do
    Thread.delay 0.02
  done;
  Alcotest.(check (list string))
    "stored once read" [ "me@example.com" ]
    (List.map (fun (a : R.author) -> a.email) (R.authors n.log));
  let asked = ref false in
  Machine_scan.propose_authors
    ~proposal:(fun ~now:_ _ ->
      asked := true;
      [])
    ~now:t n;
  Alcotest.(check bool) "and never read again" false !asked

let repositories_api () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let st, orgs = call "organizations" in
  Alcotest.(check int) "organizations" 200 st;
  Alcotest.(check (list (pair string string)))
    "each organization's choice"
    [
      ("acme-labs", "chosen");
      ("ada-park", "all_automatic");
      ("dotfiles", "all_automatic");
      ("example-co", "all");
    ]
    (List.map (fun o -> (s "name" o, s "choice" o)) (list orgs));
  let st, repos = call "repositories?status=undecided" in
  Alcotest.(check int) "repositories" 200 st;
  Alcotest.(check (list string))
    "status filter" [ "prototype" ]
    (List.map (s "name") (list repos));
  Alcotest.(check int) "bad status" 422 (fst (call "repositories?status=maybe"));
  Alcotest.(check int) "bad limit" 422 (fst (call "repositories?limit=500"));
  let _, page = call "repositories?limit=2&offset=1&q=example" in
  Alcotest.(check (list string))
    "search and a page" [ "loader"; "web" ]
    (List.map (s "name") (list page));
  (* ISS-41944: a cursor is the last row of the page before, and paging by it reads every row once,
     in the list's order. *)
  let rec walk path cursor =
    let q = match cursor with None -> "" | Some id -> "&cursor=" ^ enc id in
    let st, l = call (path ^ q) in
    Alcotest.(check int) (path ^ q) 200 st;
    match list l with
    | [] -> []
    | rows ->
        rows @ walk path (Some (s "id" (List.nth rows (List.length rows - 1))))
  in
  let ids l = List.map (s "id") l in
  Alcotest.(check (list string))
    "repositories by cursor, two at a time"
    (ids (list (snd (call "repositories?limit=200"))))
    (ids (walk "repositories?limit=2" None));
  Alcotest.(check (list string))
    "under a search"
    (ids (list (snd (call "repositories?limit=200&q=example"))))
    (ids (walk "repositories?limit=1&q=example" None));
  Alcotest.(check (list string))
    "organizations by cursor, one at a time"
    (ids (list orgs))
    (ids (walk "organizations?limit=1" None));
  Alcotest.(check (list string))
    "sources by cursor"
    (ids (list (snd (call "sources"))))
    (ids (walk "sources?limit=1" None));
  List.iter
    (fun path -> Alcotest.(check int) path 422 (fst (call path)))
    [
      "repositories?cursor=nope";
      "organizations?cursor=nope";
      "sources?cursor=nope";
      "organizations?limit=0";
      "sources?limit=201";
    ];
  let counts path =
    let st, l = call path in
    Alcotest.(check int) path 200 st;
    List.map
      (fun o -> (s "status" o, Yojson.Safe.Util.(member "count" o |> to_int)))
      (list l)
  in
  Alcotest.(check (list (pair string int)))
    "counts by status, a zero included"
    [ ("approved", 4); ("declined", 1); ("undecided", 1) ]
    (counts "repositories/counts");
  Alcotest.(check (list (pair string int)))
    "counts follow the search"
    [ ("approved", 2); ("declined", 1); ("undecided", 0) ]
    (counts "repositories/counts?q=example");
  Alcotest.(check (list (pair string int)))
    "counts follow the organization"
    [ ("approved", 0); ("declined", 0); ("undecided", 1) ]
    (counts
       ("repositories/counts?organization_id=" ^ enc "github.com/acme-labs"));
  let st, org =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("choice", `String "all_automatic") ])
      ("organizations/" ^ enc "github.com/acme-labs")
  in
  Alcotest.(check int) "choose All" 200 st;
  Alcotest.(check string) "the choice" "all_automatic" (s "choice" org);
  let _, r =
    call ~meth:"GET"
      ("repositories?organization_id=" ^ enc "github.com/acme-labs")
  in
  Alcotest.(check (list string))
    "All approves what was undecided" [ "approved" ]
    (List.map (s "status") (list r));
  Alcotest.(check int)
    "unknown choice" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("choice", `String "every_pr") ])
          ("organizations/" ^ enc "github.com/acme-labs")));
  Alcotest.(check int)
    "unknown organization" 404
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("choice", `String "all") ])
          "organizations/nope"));
  let st, r =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("status", `String "declined") ])
      ("repositories/" ^ enc "github.com/ada-park/side-project")
  in
  Alcotest.(check int) "uncheck" 200 st;
  Alcotest.(check string) "declined" "declined" (s "status" r);
  Alcotest.(check int)
    "unknown repository" 404
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("status", `String "declined") ])
          "repositories/nope"));
  let st, authors = call "commit_authors" in
  Alcotest.(check int) "authors" 200 st;
  Alcotest.(check (list string))
    "Yours first"
    [ "ada@example.com"; "hermes-bot@example.com" ]
    (List.map (s "email") (list authors));
  let st, added =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [ ("email", `String "Ada@Work.example"); ("label", `String "yours") ])
      "commit_authors"
  in
  Alcotest.(check int) "add" 201 st;
  Alcotest.(check bool)
    "the member's" true
    (member "member_set" added = `Bool true);
  Alcotest.(check int)
    "duplicate" 422
    (fst
       (call ~meth:"POST"
          ~body:
            (`Assoc
               [
                 ("email", `String "ada@work.example");
                 ("label", `String "yours");
               ])
          "commit_authors"));
  Alcotest.(check int)
    "no email" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("email", `String " "); ("label", `String "yours") ])
          "commit_authors"));
  let bot = List.nth (list authors) 1 in
  let st, relabelled =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("label", `String "yours") ])
      ("commit_authors/" ^ s "id" bot)
  in
  Alcotest.(check int) "relabel" 200 st;
  Alcotest.(check bool)
    "relabelled is the member's" true
    (member "member_set" relabelled = `Bool true);
  Alcotest.(check int)
    "remove" 204
    (fst (call ~meth:"DELETE" ("commit_authors/" ^ s "id" bot)));
  Alcotest.(check int)
    "removed" 404
    (fst (call ~meth:"DELETE" ("commit_authors/" ^ s "id" bot)))

(* Note time (DES-37265, Settings is one tab): any time of day, HH:MM, in the member's zone. *)
(* ISS-50743: Settings, Digest. A member who joined without a digest email supplies one here. *)
let digest_settings () =
  let n = demo () in
  let c = session n in
  Log.exec n.log "DELETE FROM config WHERE key = ?"
    [ Log.s Digestif_daily.Daily_digest.k_email ];
  let st, d = call n c "settings/digest" in
  Alcotest.(check int) "read" 200 st;
  Alcotest.(check bool) "no email yet" true (member "email" d = `Null);
  Alcotest.(check int)
    "the default hour" 7
    (Yojson.Safe.Util.to_int (member "hour" d));
  let put email hour =
    call n c ~meth:"PUT"
      ~body:(`Assoc [ ("email", `String email); ("hour", `Int hour) ])
      "settings/digest"
  in
  let st, e = put "not an address" 8 in
  Alcotest.(check int) "refused" 422 st;
  Alcotest.(check string)
    "names the field" "email"
    (s "field" (List.hd (list e)));
  let st, e = put "ada@example.com" 24 in
  Alcotest.(check int) "an hour past 23" 422 st;
  Alcotest.(check string) "names the hour" "hour" (s "field" (List.hd (list e)));
  Alcotest.(check (option string))
    "a refusal saves nothing" None
    (Digestif_daily.Daily_digest.email n);
  let st, d = put " ada@example.com " 6 in
  Alcotest.(check int) "saved" 200 st;
  Alcotest.(check string) "trimmed" "ada@example.com" (s "email" d);
  Alcotest.(check int) "the hour" 6 (Yojson.Safe.Util.to_int (member "hour" d));
  Alcotest.(check (option string))
    "the digest's own setting" (Some "ada@example.com")
    (Digestif_daily.Daily_digest.email n)

let note_time () =
  let n = demo () in
  let c = session n in
  let st, t = call n c "settings/note_time" in
  Alcotest.(check int) "read" 200 st;
  Alcotest.(check string) "unsaved reads as the default" "07:00" (s "time" t);
  Alcotest.(check bool) "names a zone" true (s "time_zone" t <> "");
  let put time =
    call n c ~meth:"PUT"
      ~body:(`Assoc [ ("time", `String time) ])
      "settings/note_time"
  in
  let st, t = put "6:30" in
  Alcotest.(check int) "saved" 200 st;
  Alcotest.(check string) "padded" "06:30" (s "time" t);
  Alcotest.(check string)
    "kept" "06:30"
    (s "time" (snd (call n c "settings/note_time")));
  Alcotest.(check string)
    "any time of day" "23:59"
    (s "time" (snd (put "23:59")));
  List.iter
    (fun bad ->
      let st, e = put bad in
      Alcotest.(check int) ("refused " ^ bad) 422 st;
      Alcotest.(check string)
        (bad ^ " names the field") "time"
        (s "field" (List.hd (list e))))
    [ "24:00"; "7:60"; "seven"; ""; "7"; "07:5" ];
  Alcotest.(check string)
    "a refusal saves nothing" "23:59"
    (s "time" (snd (call n c "settings/note_time")))

(* Names on Settings: a new signed card, which every request after it reads. *)
let names () =
  let n = demo () in
  let c = session n in
  let st, j = call n c "settings/names" in
  Alcotest.(check int) "read" 200 st;
  Alcotest.(check string) "the card's name" "Ada Park" (s "member_name" j);
  Alcotest.(check bool) "published" true (member "published" j = `Bool true);
  let writes = ref 0 in
  let put body =
    let r =
      Server.handler
        ~on_write:(fun () -> incr writes)
        n
        (request ~meth:"PUT"
           ~headers:[ ("cookie", c); ("digestif-local", "1") ]
           ~body:(Yojson.Safe.to_string body)
           "/api/v0/settings/names")
    in
    (r.status, Yojson.Safe.from_string r.body)
  in
  let form m a =
    `Assoc [ ("member_name", `String m); ("agent_name", `String a) ]
  in
  let st, e = put (form "Ada Park" " ") in
  Alcotest.(check int) "an empty agent name" 422 st;
  Alcotest.(check string)
    "names the field" "agent_name"
    (s "field" (List.hd (list e)));
  Alcotest.(check int) "nothing signed" 0 !writes;
  let st, j = put (form " Ada Lovelace " "Iris") in
  Alcotest.(check int) "saved" 200 st;
  Alcotest.(check string) "trimmed" "Ada Lovelace" (s "member_name" j);
  Alcotest.(check int) "a sync is asked for" 1 !writes;
  let status = snd (call n c "status") in
  Alcotest.(check string)
    "status reads the new card" "Ada Lovelace" (s "member_name" status);
  Alcotest.(check string) "and the agent" "Iris" (s "agent_name" status)

(* A member whose setup chat skipped Names has no card: Settings publishes the first one, and
   setup's names step is done once the digest email is saved too. A machine that never joined is refused. *)
let names_first_card () =
  let n = fresh () in
  Alcotest.(check (option string)) "names not done" (Some "names") (next n);
  (match Api.Names.publish n ~member_name:"Roman" ~agent_name:"Otto" with
  | Ok () -> ()
  | Error (_, m) -> Alcotest.fail m);
  Alcotest.(check (option string))
    "names wait for the digest email" (Some "names") (next n);
  ignore (ok (Digestif_daily.Daily_digest.set_email n "roman@example.com"));
  Alcotest.(check (option string)) "names done" (Some "sources") (next n);
  Alcotest.(check bool)
    "a card signed" true
    (List.exists
       (fun (r : Log.row) -> r.signed.envelope.kind = "card")
       (Log.by_author n.log (Option.get (Log.get_config n.log Node.k_device))));
  let unjoined = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init unjoined.log;
  match Api.Names.publish unjoined ~member_name:"Roman" ~agent_name:"Otto" with
  | Error (None, _) -> ()
  | _ -> Alcotest.fail "a machine that never joined publishes no card"

(* DIG-378: Ask your agent. A notice from the node with a page goes to the agent connected on Setup,
   on a thread of its own, and the answer comes back on the item as agent_ask. The prompt carries the
   member's Inbox prompt and, inline, the item's id, kind, title, the fixed line of what to do, the
   page and its address, and nothing of its detail: the agent cannot open a page. *)
let ask_agent () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let notice subject detail =
    match
      Api.Inbox.raise_notice (Api.ctx_of n) ~subject ~title:"A note is ready."
        ~detail ()
    with
    | Ok id -> id
    | Error e -> Alcotest.fail e
  in
  (* A note waits, so the node's note_ready notice stays open. *)
  ignore (Store.Notes.add n.log ~status:"waiting" "Worked on: the ask.");
  let secret = "SECRET-DETAIL of the note and /Users/ada/private" in
  let id = notice "note_ready" secret in
  let no_page = notice "work" "Some work." in
  let ask id = call ~meth:"POST" ("items/" ^ enc id ^ "/ask-agent") in
  let code e = s "code" (List.hd (list e)) in
  let st, e = ask no_page in
  Alcotest.(check int) "a notice with no page, no agent" 422 st;
  Alcotest.(check string)
    "is not askable, before an agent is asked for" "not_askable" (code e);
  let st, e = ask id in
  Alcotest.(check int) "no agent connected" 422 st;
  Alcotest.(check string) "says so" "no_agent" (code e);
  let item () = snd (call ("items/" ^ enc id)) in
  Alcotest.(check bool)
    "the item says no agent is connected" true
    (member "agent_connected" (item ()) = `Bool false);
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let prompts =
    Filename.concat (Filename.concat n.dir "good") "behaviors/prompts"
  in
  Node.mkdir_p prompts;
  Out_channel.with_open_bin (Filename.concat prompts "inbox.md") (fun oc ->
      output_string oc "Read what reaches me.\n");
  Alcotest.(check int) "an unknown item" 404 (fst (ask "item-none"));
  let st, e = ask no_page in
  Alcotest.(check int) "a notice with no page" 422 st;
  Alcotest.(check string) "is not askable" "not_askable" (code e);
  Alcotest.(check bool)
    "the item says an agent is connected" true
    (member "agent_connected" (item ()) = `Bool true);
  Alcotest.(check bool)
    "nothing asked yet" true
    (member "agent_ask" (item ()) = `Null);
  Log.set_config n.log Api.k_ui_url "http://127.0.0.1:7420";
  let prompts_seen = ref [] in
  let answer = ref (Ok "I opened the page and approved nothing.") in
  let gate_r, gate_w = Unix.pipe () in
  let release () = ignore (Unix.write_substring gate_w "x" 0 1) in
  let saved = !Api.Ask_agent.run in
  (Api.Ask_agent.run :=
     fun (a : Api.Agent.A.t) ~id:_ ~on_spawn:_ ~prompt ->
       ignore (Unix.read gate_r (Bytes.create 1) 0 1);
       prompts_seen := (a.path, prompt) :: !prompts_seen;
       !answer);
  Fun.protect
    ~finally:(fun () ->
      Api.Ask_agent.run := saved;
      Unix.close gate_r;
      Unix.close gate_w)
    (fun () ->
      let until status =
        let rec go tries =
          let a = member "agent_ask" (item ()) in
          if s "status" a = status then a
          else if tries > 0 then (
            Thread.delay 0.01;
            go (tries - 1))
          else Alcotest.failf "the ask never read %s" status
        in
        go 500
      in
      let st, a = ask id in
      Alcotest.(check int) "answers at once" 202 st;
      Alcotest.(check string) "asked" "asked" (s "status" a);
      Alcotest.(check string)
        "the item reads asked" "asked"
        (s "status" (member "agent_ask" (item ())));
      let st, e = ask id in
      Alcotest.(check int) "one ask at a time" 422 st;
      Alcotest.(check string) "says so" "asking" (code e);
      release ();
      let a = until "answered" in
      Alcotest.(check string)
        "the agent's answer is the reply"
        "I opened the page and approved nothing." (s "reply" a);
      let path, prompt = List.hd !prompts_seen in
      Alcotest.(check string) "the saved agent ran" claude path;
      List.iter
        (fun (what, needle) ->
          Alcotest.(check bool) what true (contains prompt needle))
        [
          ("the Inbox prompt", "Read what reaches me.");
          ("the item id", id);
          ("the kind", "Kind: notice");
          ("the title", "A note is ready.");
          ("the page", "Page: /feed");
          ( "the address",
            "Address, on the member's machine: http://127.0.0.1:7420/feed" );
          ( "the member's step, from the fixed line",
            "What the member does there: Read the note and approve it, edit it \
             or dismiss it." );
          ("the agent is told not to open", "Do not open anything: you cannot.");
          ("where and how to act", "Say where the member should act and how");
        ];
      Alcotest.(check bool)
        "never told to open the page" false
        (contains prompt "Open the page"
        || contains prompt "read the details there");
      Alcotest.(check (option string))
        "reading the default Inbox prompt saved nothing" None
        (Log.get_config n.log "inbox_prompt");
      Alcotest.(check bool)
        "none of the detail" false
        (contains prompt "SECRET-DETAIL" || contains prompt "/Users/ada");
      (* A failure is a reply that says why. The claim is released just after the answer is kept. *)
      answer := Error "it stopped with code 1";
      let rec again tries =
        let st, _ = ask id in
        if st = 202 then ()
        else if tries > 0 then (
          Thread.delay 0.01;
          again (tries - 1))
        else Alcotest.failf "asked again: %d" st
      in
      again 500;
      release ();
      let a = until "failed" in
      Alcotest.(check string)
        "says why" "Your agent did not answer (it stopped with code 1)."
        (s "reply" a);
      Alcotest.(check int)
        "the reply is on the item, not in the feed" 0
        (List.length
           (List.filter
              (fun m -> contains (s "text" m) "Your agent did not answer")
              (list (snd (call "feed?limit=200")))));
      (* An ask left asked by a process that died fails at startup, and one that outlived its run's
         deadline reads failed. *)
      let key = Api.Inbox.k_ask id in
      Log.set_config n.log key
        (Api.Inbox.ask_record ~status:"asked" ~at:(Time_fmt.now ()) ());
      Alcotest.(check string)
        "asked just now reads asked" "asked"
        (s "status" (member "agent_ask" (item ())));
      Api.Ask_agent.settle_leftovers n.log;
      let a = member "agent_ask" (item ()) in
      Alcotest.(check string) "failed at startup" "failed" (s "status" a);
      Alcotest.(check string)
        "and says why" "Your agent did not answer (the node restarted)."
        (s "reply" a);
      (* Its recorded process group is killed only while the run can still be the agent the node
         started: past the deadline and margin the number may lead an unrelated group. *)
      let killed = ref [] in
      let saved_kill = !Api.Ask_agent.kill_pgid in
      (Api.Ask_agent.kill_pgid := fun g -> killed := g :: !killed);
      Fun.protect
        ~finally:(fun () -> Api.Ask_agent.kill_pgid := saved_kill)
        (fun () ->
          let now = Unix.gettimeofday () in
          let asked_ago secs pgid =
            Log.set_config n.log key
              (Api.Inbox.ask_record ~status:"asked"
                 ~at:(Time_fmt.of_unix (now -. secs))
                 ~pgid ());
            Api.Ask_agent.settle_leftovers ~now n.log
          in
          asked_ago 3600.0 424242;
          Alcotest.(check (list int)) "an old ask's group is spared" [] !killed;
          Alcotest.(check string)
            "and the ask is failed" "failed"
            (s "status" (member "agent_ask" (item ())));
          Alcotest.(check string)
            "as the node restarting"
            "Your agent did not answer (the node restarted)."
            (s "reply" (member "agent_ask" (item ())));
          asked_ago 721.0 424243;
          Alcotest.(check (list int)) "just past the window" [] !killed;
          asked_ago 60.0 424244;
          Alcotest.(check (list int))
            "a recent ask's group is killed" [ 424244 ] !killed;
          Alcotest.(check string)
            "and the ask is failed too" "failed"
            (s "status" (member "agent_ask" (item ()))));
      Log.set_config n.log key
        (Api.Inbox.ask_record ~status:"asked"
           ~at:(Time_fmt.of_unix (Unix.gettimeofday () -. 900.0))
           ());
      let a = member "agent_ask" (item ()) in
      Alcotest.(check string) "past its deadline" "failed" (s "status" a);
      Alcotest.(check string)
        "says why" "Your agent did not answer (it ran past ten minutes)."
        (s "reply" a);
      (* A settled notice is not asked about. *)
      Alcotest.(check int)
        "acknowledged" 200
        (fst (call ~meth:"POST" ("items/" ^ enc id ^ "/acknowledge")));
      let st, e = ask id in
      Alcotest.(check int) "a settled notice" 422 st;
      Alcotest.(check string) "is not askable" "not_askable" (code e);
      Alcotest.(check bool)
        "and carries no agent_connected" true
        (member "agent_connected" (item ()) = `Null);
      (* Its ask row goes once the item is settled, unless the ask is still running. *)
      let now = Unix.gettimeofday () in
      Log.set_config n.log key
        (Api.Inbox.ask_record ~status:"asked" ~at:(Time_fmt.now ()) ());
      Digest_lines.clear_notices n ~now;
      Alcotest.(check bool)
        "a running ask on a settled item keeps its row" true
        (Log.get_config n.log key <> None);
      Log.set_config n.log key
        (Api.Inbox.ask_record ~status:"answered" ~at:(Time_fmt.now ())
           ~reply:"Done." ());
      Digest_lines.clear_notices n ~now;
      Alcotest.(check bool)
        "an answered ask on a settled item is dropped" true
        (Log.get_config n.log key = None))

(* DIG-378: the prompt for a could_not_run notice, whose title and fixed line say "Open it": the line
   is the member's step, and the agent is told it cannot open anything. A stop kills a running ask
   and fails it as the node stopping, and the worker never writes it back as answered. *)
let ask_agent_prompt_and_stop () =
  let n = demo () in
  let c = session n in
  let ctx = Api.ctx_of n in
  let notice subject title =
    match Api.Inbox.raise_notice ctx ~subject ~title () with
    | Ok id -> id
    | Error e -> Alcotest.fail e
  in
  let id =
    notice "could_not_run"
      "Digestif could not run today. Open it on your machine to see why."
  in
  let row = Option.get (Api.Inbox.find ctx id) in
  let prompt = Api.Ask_agent.prompt ctx row "/feed" in
  List.iter
    (fun (what, needle) ->
      Alcotest.(check bool) what true (contains prompt needle))
    [
      ( "the member's step",
        "What the member does there: Open it to see why Digestif could not run."
      );
      ("the agent is told not to open", "Do not open anything: you cannot.");
      ("where and how to act", "Say where the member should act and how");
    ];
  Alcotest.(check bool)
    "no line telling the agent what to do there" false
    (contains prompt "What to do there");
  (* A stop. *)
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let gate_r, gate_w = Unix.pipe () in
  let saved = !Api.Ask_agent.run in
  (Api.Ask_agent.run :=
     fun _ ~id:_ ~on_spawn:_ ~prompt:_ ->
       ignore (Unix.read gate_r (Bytes.create 1) 0 1);
       Ok "A late answer.");
  Fun.protect
    ~finally:(fun () ->
      Api.Ask_agent.run := saved;
      Unix.close gate_r;
      Unix.close gate_w)
    (fun () ->
      let item () = snd (call n c ("items/" ^ enc id)) in
      let st, _ = call n c ~meth:"POST" ("items/" ^ enc id ^ "/ask-agent") in
      Alcotest.(check int) "asked" 202 st;
      Api.Ask_agent.kill_running n.log;
      let a = member "agent_ask" (item ()) in
      Alcotest.(check string) "failed at the stop" "failed" (s "status" a);
      Alcotest.(check string)
        "and says why" "Your agent did not answer (the node stopped)."
        (s "reply" a);
      (* The run ends after the stop: its worker says the node stopped, not answered. *)
      ignore (Unix.write_substring gate_w "x" 0 1);
      let rec settled tries =
        if
          Mutex.protect Api.Ask_agent.running_lock (fun () ->
              Hashtbl.mem Api.Ask_agent.running id)
          && tries > 0
        then (
          Thread.delay 0.01;
          settled (tries - 1))
      in
      settled 500;
      let a = member "agent_ask" (item ()) in
      Alcotest.(check string) "still failed" "failed" (s "status" a);
      Alcotest.(check string)
        "still the node stopped" "Your agent did not answer (the node stopped)."
        (s "reply" a))

(* The agent on Settings: Save runs the check and answers with its verdict, the check reads
   Checking while it runs and every other page answers meanwhile (the request has a thread of its
   own, as Http.run gives it), the program is saved only once it passes, and it becomes the note
   writer's harness, with its kind, beside what config.json already held: Claude Code, Codex and a
   typed path alike. ISS-41847, ISS-47299 *)
let agent () =
  let n = demo () in
  let c = session n in
  Alcotest.(check int) "none saved" 404 (fst (call n c "settings/agent"));
  Alcotest.(check int)
    "no check yet" 404
    (fst (call n c "settings/agent/check"));
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  let program name =
    let p = Filename.concat bin name in
    Out_channel.with_open_bin p (fun oc -> output_string oc "#!/bin/sh\n");
    Unix.chmod p 0o755;
    p
  in
  let verdict =
    ref (Api.Agent.A.Fails "does not answer (exit 1): signed out")
  in
  let checked = ref [] in
  (* The check holds until the test lets one through, as a real one runs for minutes. *)
  let gate_r, gate_w = Unix.pipe () in
  let release () = ignore (Unix.write_substring gate_w "x" 0 1) in
  let saved = !Api.Agent.check in
  (Api.Agent.check :=
     fun ~dir (a : Api.Agent.A.t) ->
       ignore (Unix.read gate_r (Bytes.create 1) 0 1);
       checked := (dir, a.path) :: !checked;
       !verdict);
  Fun.protect
    ~finally:(fun () ->
      Api.Agent.check := saved;
      Unix.close gate_r;
      Unix.close gate_w)
    (fun () ->
      let put path =
        call n c ~meth:"PUT"
          ~body:(`Assoc [ ("path", `String path) ])
          "settings/agent"
      in
      let the_check () =
        let st, j = call n c "settings/agent/check" in
        Alcotest.(check int) "the check reads" 200 st;
        j
      in
      let st, e = put (Filename.concat bin "nope") in
      Alcotest.(check int) "not a program" 422 st;
      Alcotest.(check string) "names path" "path" (s "field" (List.hd (list e)));
      Alcotest.(check int)
        "no check started" 404
        (fst (call n c "settings/agent/check"));
      (* The first check on a thread of its own and its own connection to the log, as the server
         answers it, so this one can ask while it runs. *)
      let other = { n with log = Log.open_ (Node.log_path n.dir) } in
      let result = ref None in
      let first =
        Thread.create
          (fun () ->
            result :=
              Some
                (call other c ~meth:"PUT"
                   ~body:(`Assoc [ ("path", `String claude) ])
                   "settings/agent"))
          ()
      in
      let rec until_checking tries =
        match call n c "settings/agent/check" with
        | 200, j when s "status" j = "checking" -> j
        | _ when tries > 0 ->
            Thread.delay 0.01;
            until_checking (tries - 1)
        | _ -> Alcotest.fail "the check never read Checking"
      in
      let j = until_checking 500 in
      Alcotest.(check string) "the program" claude (s "path" j);
      Alcotest.(check int)
        "other pages answer meanwhile" 200
        (fst (call n c "status"));
      Alcotest.(check int)
        "not saved while it runs" 404
        (fst (call n c "settings/agent"));
      let st, e = put claude in
      Alcotest.(check int) "one check at a time" 422 st;
      Alcotest.(check string) "says so" "checking" (s "code" (List.hd (list e)));
      release ();
      Thread.join first;
      Log.close other.log;
      let st, answered = Option.get !result in
      Alcotest.(check int) "Save answers with the verdict" 200 st;
      Alcotest.(check string)
        "which is the check's" "failed" (s "status" answered);
      let j = the_check () in
      Alcotest.(check string) "fails the check" "failed" (s "status" j);
      Alcotest.(check bool)
        "says why" true
        (contains (s "message" j) "signed out");
      Alcotest.(check bool)
        "and that nothing was saved" true
        (contains (s "message" j) "Not saved.");
      Alcotest.(check (list (pair string string)))
        "checked in the node's directory"
        [ (n.dir, claude) ]
        !checked;
      Alcotest.(check int) "not saved" 404 (fst (call n c "settings/agent"));
      let nightly = Filename.concat n.dir "behaviors/nightly" in
      Node.mkdir_p nightly;
      let config = Filename.concat nightly "config.json" in
      Yojson.Safe.to_file config
        (`Assoc [ ("harness", `String "/old/claude"); ("brief", `String "b") ]);
      verdict := Api.Agent.A.Works;
      release ();
      let st, answered = put claude in
      Alcotest.(check int) "a second check answers" 200 st;
      Alcotest.(check string) "passed" "passed" (s "status" answered);
      let j = the_check () in
      Alcotest.(check string) "passes" "passed" (s "status" j);
      Alcotest.(check string) "Claude Code" "Claude Code" (s "name" j);
      Alcotest.(check string)
        "saved" claude
        (s "path" (snd (call n c "settings/agent")));
      let written = Yojson.Safe.from_file config in
      Alcotest.(check string)
        "the writer's harness" claude (s "harness" written);
      Alcotest.(check string) "its kind" "claude_code" (s "agent" written);
      Alcotest.(check string) "the rest kept" "b" (s "brief" written);
      List.iter
        (fun (name, kind) ->
          let path = program name in
          release ();
          let st, _ = put path in
          Alcotest.(check int) (name ^ "'s check answers") 200 st;
          Alcotest.(check string)
            (name ^ " passes") "passed"
            (s "status" (the_check ()));
          let written = Yojson.Safe.from_file config in
          Alcotest.(check string)
            (name ^ " is the writer's harness")
            path (s "harness" written);
          Alcotest.(check string) (name ^ "'s kind") kind (s "agent" written);
          Alcotest.(check string)
            (name ^ ": the rest kept") "b" (s "brief" written))
        [ ("codex", "codex"); ("my-agent", "other") ])

(* A raw HTTP/1.1 GET over a socket to 127.0.0.1:[port]; the whole answer, read to EOF. *)
let raw_get ?(headers = []) port target =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.setsockopt_float fd Unix.SO_RCVTIMEO 10.0;
      Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
      let head =
        String.concat ""
          (List.map
             (fun (k, v) -> k ^ ": " ^ v ^ "\r\n")
             (("Host", Printf.sprintf "127.0.0.1:%d" port) :: headers))
      in
      Http.write_all fd (Printf.sprintf "GET %s HTTP/1.1\r\n%s\r\n" target head);
      let b = Buffer.create 1024 and chunk = Bytes.create 4096 in
      let rec go () =
        match Unix.read fd chunk 0 4096 with
        | 0 -> ()
        | k ->
            Buffer.add_subbytes b chunk 0 k;
            go ()
      in
      go ();
      Buffer.contents b)

(* The server answers concurrently: a request still in flight holds nobody else, so a page and the
   UI's assets load while it runs. ISS-47299 *)
let concurrent_server () =
  let gate_r, gate_w = Unix.pipe () in
  let fd, port = Result.get_ok (Http.listen ~port:0 ()) in
  let stop = Atomic.make false in
  let handler (req : Http.request) =
    if req.path = "/slow" then ignore (Unix.read gate_r (Bytes.create 1) 0 1);
    Http.plain 200 ("answered " ^ req.path)
  in
  let server =
    Thread.create
      (fun () -> Http.run ~stop:(fun () -> Atomic.get stop) handler fd)
      ()
  in
  let slow_answer = ref "" in
  let slow = Thread.create (fun () -> slow_answer := raw_get port "/slow") () in
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.write_substring gate_w "x" 0 1);
      Thread.join slow;
      Atomic.set stop true;
      Thread.join server;
      Unix.close fd;
      Unix.close gate_r;
      Unix.close gate_w)
    (fun () ->
      Thread.delay 0.1;
      let t = Unix.gettimeofday () in
      let fast = raw_get port "/feed" in
      let took = Unix.gettimeofday () -. t in
      Alcotest.(check bool)
        "a page answers while a slow request is in flight" true
        (contains fast "answered /feed");
      Alcotest.(check bool) "and at once" true (took < 2.);
      Alcotest.(check string) "the slow one is still waiting" "" !slow_answer;
      ignore (Unix.write_substring gate_w "x" 0 1);
      Thread.join slow;
      Alcotest.(check bool)
        "the slow one is answered once it ends" true
        (contains !slow_answer "answered /slow"))

(* The UI's bind waits for a port the node being replaced still holds, and is refused at once with
   no wait. ISS-47299 *)
let bind_waits () =
  let held, port = Result.get_ok (Http.listen ~port:0 ()) in
  (match Http.listen ~port () with
  | Ok (fd, _) ->
      Unix.close fd;
      Alcotest.fail "a held port was bound"
  | Error e ->
      Alcotest.(check bool) "says the port is taken" true (contains e "in use"));
  let releaser =
    Thread.create
      (fun () ->
        Thread.delay 0.5;
        Unix.close held)
      ()
  in
  (match Http.listen ~wait_for:10. ~port () with
  | Ok (fd, bound) ->
      Alcotest.(check int) "the same port" port bound;
      Unix.close fd
  | Error e -> Alcotest.fail ("the wait did not bind: " ^ e));
  Thread.join releaser

(* Server.serve answers each request against a connection of its own to the node's log: the static
   UI and the local API, side by side, over real sockets. *)
(* ISS-47299: requests run on threads of their own, each with its own log connection, and the demo
   plays the send job before every one. Passes racing over one approved note sign it once. *)
let send_once_under_concurrency () =
  let n = demo () in
  let note = List.hd (Store.Notes.waiting n.log) in
  let v = List.hd (List.rev (Store.Notes.versions n.log ~note_id:note.n_id)) in
  Store.Notes.approve n.log ~note_id:note.n_id ~version_id:v.v_id
    ~status:"approved";
  let before = Log.count n.log in
  let pass () =
    let log = Log.open_ (Node.log_path n.dir) in
    Fun.protect
      ~finally:(fun () -> Log.close log)
      (fun () -> Api.send_notes { n with log })
  in
  List.iter Thread.join (List.init 6 (fun _ -> Thread.create pass ()));
  Alcotest.(check int) "one envelope" (before + 1) (Log.count n.log);
  Alcotest.(check bool)
    "the note records it" true
    ((Option.get (Store.Notes.find n.log note.n_id)).n_posted_hash <> None)

(* [f port cookie] against [n] served over a real socket by Server.serve, after a launch. *)
let serving n f =
  let fd = Result.get_ok (Server.start ~port:0 n) in
  let port =
    match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | _ -> 0
  in
  let token = Store.new_launch_token n.Node.log in
  let stop = Atomic.make false in
  let server =
    Thread.create
      (fun () -> Server.serve ~stop:(fun () -> Atomic.get stop) n fd)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set stop true;
      Thread.join server;
      Unix.close fd)
    (fun () ->
      let launched = raw_get port ("/launch?token=" ^ token) in
      Alcotest.(check bool) "launch" true (contains launched "303 See Other");
      let cookie =
        let i = index_of launched "digestif_session_" in
        let rest = String.sub launched i (String.length launched - i) in
        String.sub rest 0 (String.index rest ';')
      in
      f port cookie)

let api_get port cookie target =
  raw_get ~headers:[ ("Cookie", cookie); ("Digestif-Local", "1") ] port target

let serve_own_log () =
  let n = demo () in
  serving n (fun port cookie ->
      let answers =
        List.map
          (fun target ->
            let r = ref "" in
            let t =
              Thread.create (fun () -> r := api_get port cookie target) ()
            in
            (t, r))
          [ "/api/v0/status"; "/api/v0/feed"; "/"; "/api/v0/members" ]
      in
      List.iter
        (fun (t, r) ->
          Thread.join t;
          Alcotest.(check bool) "answered 200" true (contains !r "200 OK"))
        answers)

(* ISS-78820: the first paint waits on GET status, the Inbox's items and members, and a GET never
   waits for the log's write lock. Background work holds it (a sync storing a relay's page, the scan's
   writes, a behavior's CLI call), and a GET that waited painted nothing for up to the busy timeout and
   then failed. Here another connection holds the lock for the whole test; every read the UI makes
   without a parameter answers at once. *)
let reads_answer_while_log_is_held () =
  let n = demo () in
  serving n (fun port cookie ->
      let holder = Log.open_ (Node.log_path n.dir) in
      Fun.protect
        ~finally:(fun () -> Log.close holder)
        (fun () ->
          Log.transaction holder (fun () ->
              List.iter
                (fun target ->
                  let t = Unix.gettimeofday () in
                  let r = api_get port cookie target in
                  let took = Unix.gettimeofday () -. t in
                  (* Answered, not failed: a read of something not set (quiet hours) is a 404. *)
                  Alcotest.(check bool)
                    (target ^ " answered") true
                    (contains r "HTTP/1.1 200 " || contains r "HTTP/1.1 404 ");
                  Alcotest.(check bool)
                    (Printf.sprintf "%s at once (%.2fs)" target took)
                    true (took < 1.))
                (List.map
                   (fun p -> "/api/v0/" ^ p)
                   [
                     "items?status=draft&status=new&limit=51";
                     "search?q=eval";
                     "members?limit=200";
                     "brief";
                     "commit_authors";
                     "feed";
                     "invitees";
                     "items";
                     "learnings";
                     "members";
                     "note_prompt";
                     "notes";
                     "organizations";
                     "paused";
                     "problems";
                     "repositories";
                     "repositories/counts";
                     "rules";
                     "rules/deny";
                     "rules/quiet_hours";
                     "settings/agent";
                     "settings/approval";
                     "settings/digest";
                     "settings/inbox_agent";
                     "settings/names";
                     "settings/note_time";
                     "sources";
                     "status";
                     "suggestions";
                   ])));
      (* Once the lock is free, a read brings the index up as it always did. *)
      Alcotest.(check bool)
        "after the lock is let go" true
        (contains (api_get port cookie "/api/v0/status") "200 OK"))

(* The setup chat proposes git by organization and its commit authors, and saves what the member
   changed of them (ISS-38824). *)
let setup_chat_repositories () =
  let module R = Store.Repositories in
  let n = fresh () in
  Log.set_config n.log Sources.k_fixed "1";
  Store.set_offered n.log [ Sources.git_source [ "~/code/a" ] ];
  R.apply_scan n.log ~at:"2026-01-01T00:00:00Z"
    [ found "a"; found "b"; found ~org:"github.com/acme" ~org_name:"acme" "c" ];
  R.propose_authors n.log
    [
      ("dana@x.com", Some "Dana", "yours");
      ("bot@x.com", Some "Bot", "your_fleet");
      ("pat@acme.com", Some "Pat", "your_fleet");
    ];
  let f = Setup_chat.found n ~invited_name:None in
  let git =
    List.find
      (fun s -> member "id" s = `String "git")
      (list (member "sources" f))
  in
  Alcotest.(check bool) "git has no paths" true (member "paths" git = `Null);
  let orgs = list (member "organizations" git) in
  Alcotest.(check (list string))
    "by organization, each with its choice"
    [ "acme:all_automatic"; "o:all_automatic" ]
    (List.map (fun o -> s "name" o ^ ":" ^ s "choice" o) orgs);
  Alcotest.(check (list string))
    "and its repositories"
    [ "a:approved"; "b:approved" ]
    (List.map
       (fun r -> s "name" r ^ ":" ^ s "status" r)
       (list (member "repositories" (List.nth orgs 1))));
  Alcotest.(check (list string))
    "the commit authors"
    [ "dana@x.com:yours"; "bot@x.com:your_fleet"; "pat@acme.com:your_fleet" ]
    (List.map
       (fun a -> s "email" a ^ ":" ^ s "label" a)
       (list (member "commit_authors" f)));
  ignore
    (ok
       (Setup_chat.save_names n ~name:"Dana" ~agent_name:"Wren"
          ~email:"dana@example.com"));
  let save ?(organizations = []) ?(approve = []) ?(decline = []) ?(authors = [])
      ?(remove_authors = []) () =
    Result.bind
      (Setup_chat.choices_of_flags ~organizations ~approve ~decline ~authors
         ~remove_authors) (fun choices ->
        Setup_chat.save_sources ~choices n ~all:true ~ids:[])
  in
  refused "a choice that is not one"
    (save ~organizations:[ "github.com/acme=some" ] ());
  refused "an organization not found"
    (save ~organizations:[ "github.com/nope=chosen" ] ());
  refused "not KEY=VALUE" (save ~organizations:[ "github.com/acme" ] ());
  refused "a repository not found" (save ~decline:[ "github.com/o/zz" ] ());
  refused "approved and declined"
    (save ~approve:[ "github.com/o/a" ] ~decline:[ "github.com/o/a" ] ());
  refused "an author not on the list" (save ~remove_authors:[ "x@y.z" ] ());
  refused "a label that is not one" (save ~authors:[ "me@x.com=mine" ] ());
  Alcotest.(check (option string))
    "a refusal saves nothing" (Some "sources") (next n);
  Alcotest.(check string)
    "nothing changed" "all_automatic"
    (Option.get (R.organization n.log "github.com/acme")).choice;
  ignore
    (ok
       (save
          ~organizations:[ "github.com/acme=chosen"; "github.com/o=all" ]
          ~decline:[ "github.com/o/b"; "github.com/acme/c" ]
          ~authors:[ "me@home.org=yours"; "bot@x.com=yours" ]
          ~remove_authors:[ "pat@acme.com" ] ()));
  Alcotest.(check (option string)) "then the brief" (Some "brief") (next n);
  Alcotest.(check (list string))
    "each organization's choice" [ "acme:chosen"; "o:all" ]
    (List.map
       (fun (o : R.organization) -> o.o_name ^ ":" ^ o.choice)
       (R.organizations n.log));
  Alcotest.(check (list (pair string string)))
    "declined under All keeps the choice"
    [ ("c", "declined"); ("a", "approved"); ("b", "declined") ]
    (statuses n.log);
  Alcotest.(check (list string))
    "the authors as changed"
    [ "bot@x.com:yours"; "dana@x.com:yours"; "me@home.org:yours" ]
    (List.map (fun (a : R.author) -> a.email ^ ":" ^ a.label) (R.authors n.log));
  Alcotest.(check bool)
    "an author the chat changed is the member's" true
    (List.for_all
       (fun (a : R.author) -> a.member_set = (a.email <> "dana@x.com"))
       (R.authors n.log))

(* ISS-51009: a round is each judge's next pick. All the suggested version adopts it, all the current
   one closes it, a split runs the pair again, and a judge who has not picked leaves the round
   open. *)
let suggestion_rounds () =
  let module S = Suggestions in
  let s : S.suggestion =
    {
      hash = "sha256:s";
      author = "ed25519:ada";
      created_at = "2026-11-06T00:00:00.000Z";
      text = "x";
      change = "y";
      id = "sha256:x";
      judges = [ "ed25519:ada"; "ed25519:ben" ];
      withdrawn = false;
    }
  in
  let at d = Printf.sprintf "2026-11-0%dT08:00:00.000Z" d in
  let result picks =
    let rounds, decided = S.rounds_of ~s picks in
    ( List.map
        (fun (r : S.round) ->
          match r.result with Some x -> S.result_name x | None -> "open")
        rounds,
      Option.map (fun (x, _) -> S.result_name x) decided )
  in
  let check name picks expected decided =
    let rounds, d = result picks in
    Alcotest.(check (list string)) (name ^ ": rounds") expected rounds;
    Alcotest.(check (option string)) (name ^ ": decided") decided d
  in
  check "nobody has picked" [] [] None;
  check "one judge picked"
    [ ("ed25519:ada", [ (at 7, S.Suggested) ]) ]
    [ "open" ] None;
  check "both picked the suggested version"
    [
      ("ed25519:ada", [ (at 7, S.Suggested) ]);
      ("ed25519:ben", [ (at 7, S.Suggested) ]);
    ]
    [ "adopted" ] (Some "adopted");
  check "a split, then both the current one"
    [
      ("ed25519:ada", [ (at 7, S.Suggested); (at 8, S.Current) ]);
      ("ed25519:ben", [ (at 7, S.Current); (at 9, S.Current) ]);
    ]
    [ "split"; "not_adopted" ] (Some "not_adopted");
  check "a quiet day lines up on the next note"
    [
      ("ed25519:ada", [ (at 7, S.Current); (at 8, S.Suggested) ]);
      ("ed25519:ben", [ (at 9, S.Suggested) ]);
    ]
    [ "split"; "open" ] None;
  check "picks after the deciding round are not read"
    [
      ("ed25519:ada", [ (at 7, S.Suggested); (at 8, S.Current) ]);
      ("ed25519:ben", [ (at 7, S.Suggested); (at 8, S.Current) ]);
    ]
    [ "adopted" ] (Some "adopted")

(* ISS-51009, end to end on one node: a suggestion names its judges, its judge's note is written in
   two versions that wait whatever the approval setting, approving the suggested one is the pick the
   signed summary carries, the round adopts it, the author's node writes the circle's live prompt,
   and the nightly behavior is told a pull request is owed. *)
let suggestion_flow () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let prompt =
    "You write the note. {{always_on_rules}} Lead with the lesson."
  in
  let refused body code =
    let st, j = call ~meth:"POST" ~body "suggestions" in
    Alcotest.(check int) (code ^ ": refused") 422 st;
    Alcotest.(check string) code code (s "code" (List.hd (list j)))
  in
  refused
    (`Assoc [ ("text", `String "No rule here."); ("change", `String "x") ])
    "always_on";
  refused (`Assoc [ ("text", `String prompt); ("change", `String "") ]) "empty";
  refused
    (`Assoc
       [
         ("text", `String prompt);
         ("change", `String "x");
         ("judges", `List [ `String "ed25519:nobody" ]);
       ])
    "judges";
  let st, created =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String prompt);
             ("change", `String "Lead with\n the lesson");
           ])
      "suggestions"
  in
  Alcotest.(check int) "suggested" 201 st;
  let hash = s "hash" created in
  Alcotest.(check string) "one line" "Lead with the lesson" (s "change" created);
  Alcotest.(check string) "judging" "judging" (s "status" created);
  Alcotest.(check bool)
    "it runs for its author" true
    (member "running" created = `Bool true);
  Alcotest.(check int)
    "the author judges it" 1
    (List.length (list (member "judges" created)));
  let _, np = call "note_prompt" in
  Alcotest.(check string)
    "the behavior is handed it" hash
    (s "hash" (member "running" np));
  Alcotest.(check bool) "no live prompt yet" true (member "text" np = `Null);
  (* The night's note, in two versions, with auto approval saved: it still waits. *)
  ignore
    (call ~meth:"PUT"
       ~body:(`Assoc [ ("setting", `String "auto_approve") ])
       "settings/approval");
  let suggested_id = Suggestions.prompt_id prompt in
  let pair =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("suggestion", `String hash);
           ("prompt", `String suggested_id);
           ("text", `String "Learned: the lesson first.");
           ("checks", `List []);
         ])
  in
  let id =
    ok
      (Api.submit_note_text ~approve:true ~prompt:"sha256:current" ~pair n
         "Worked on: the work log first.")
  in
  let _, note = call ("notes/" ^ id) in
  Alcotest.(check string) "it waits" "waiting" (s "status" note);
  let versions = list (member "pair" note) in
  Alcotest.(check (list int))
    "numbered 1 and 2" [ 1; 2 ]
    (List.map
       (fun v -> match member "number" v with `Int i -> i | _ -> 0)
       versions);
  let suggested =
    List.find (fun v -> s "text" v = "Learned: the lesson first.") versions
  in
  (* Either of the pair is approvable: the member picks the suggested one. *)
  let st, _ =
    call ~meth:"POST"
      ~body:(`Assoc [ ("version_id", `String (s "id" suggested)) ])
      ("notes/" ^ id ^ "/approve")
  in
  Alcotest.(check int) "picked" 200 st;
  Api.send_notes n;
  let signed =
    List.find
      (fun (r : Log.row) ->
        Option.bind r.signed.body (Content.str_field "text")
        = Some "Learned: the lesson first.")
      (Log.of_kind n.log "summary")
  in
  let body = Option.get signed.signed.body in
  Alcotest.(check (option string))
    "the note carries its prompt" (Some suggested_id)
    (Content.str_field "prompt" body);
  Alcotest.(check (option string))
    "and the suggestion it judged" (Some hash)
    (Content.str_field "suggestion" body);
  let _, after = call ("suggestions/" ^ hash) in
  Alcotest.(check string) "adopted" "adopted" (s "status" after);
  Alcotest.(check bool) "live" true (member "live" after = `Bool true);
  Alcotest.(check int)
    "one prompt envelope" 1
    (List.length (Log.of_kind n.log "prompt"));
  Api.send_notes n;
  Alcotest.(check int)
    "written once" 1
    (List.length (Log.of_kind n.log "prompt"));
  let _, np = call "note_prompt" in
  Alcotest.(check string) "the circle's live prompt" prompt (s "text" np);
  Alcotest.(check string) "its id" suggested_id (s "id" np);
  Alcotest.(check bool) "nothing runs now" true (member "running" np = `Null);
  Alcotest.(check bool)
    "a pull request is owed" true
    (member "pull_request_owed" after = `Bool true);
  let st, _ =
    call ~meth:"PUT"
      ~body:
        (`Assoc
           [ ("url", `String "https://github.com/digestif-ai/digestif/pull/1") ])
      ("suggestions/" ^ hash ^ "/pull_request")
  in
  Alcotest.(check int) "recorded" 200 st;
  let _, after = call ("suggestions/" ^ hash) in
  Alcotest.(check bool)
    "none owed now" true
    (member "pull_request_owed" after = `Bool false);
  refused
    (`Assoc [ ("text", `String prompt); ("change", `String "again") ])
    "unchanged";
  (* The digest tells the round and the change of prompt, once. The hook runs inside the digest's
     transaction, as Daily_digest.write runs it. *)
  let lines =
    Log.transaction n.log (fun () ->
        Digest_lines.machine n ~now:(Unix.gettimeofday ()))
  in
  Alcotest.(check bool)
    "the round" true
    (List.exists
       (fun l -> contains l "you picked the suggested version")
       lines.lines);
  Alcotest.(check bool)
    "the change of prompt" true
    (List.exists
       (fun l -> contains l "nightly note prompt changed")
       lines.lines);
  lines.told ();
  let again = Digest_lines.machine n ~now:(Unix.gettimeofday ()) in
  Alcotest.(check bool)
    "told once" false
    (List.exists (fun l -> contains l "prompt") again.lines)

(* ISS-51009: a suggestion naming another judge waits for their pick, and its author may withdraw
   it while it judges. *)
let suggestion_judges () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let others =
    List.filter
      (fun m -> member "is_self" m <> `Bool true && s "stage" m = "active")
      (list (snd (call "members")))
  in
  let ben = s "identity" (List.hd others) in
  let prompt = "Write it. {{always_on_rules}}" in
  let _, created =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String prompt);
             ("change", `String "Shorter");
             ("judges", `List [ `String ben ]);
           ])
      "suggestions"
  in
  let hash = s "hash" created in
  Alcotest.(check int)
    "two judges" 2
    (List.length (list (member "judges" created)));
  let id =
    ok
      (Api.submit_note_text ~prompt:"sha256:current"
         ~pair:
           (Yojson.Safe.to_string
              (`Assoc
                 [
                   ("suggestion", `String hash);
                   ("prompt", `String (Suggestions.prompt_id prompt));
                   ("text", `String "Short.");
                 ]))
         n "Long.")
  in
  let _, note = call ("notes/" ^ id) in
  let current =
    List.find (fun v -> s "text" v = "Long.") (list (member "pair" note))
  in
  ignore
    (call ~meth:"POST"
       ~body:(`Assoc [ ("version_id", `String (s "id" current)) ])
       ("notes/" ^ id ^ "/approve"));
  Api.send_notes n;
  let _, after = call ("suggestions/" ^ hash) in
  Alcotest.(check string) "still judging" "judging" (s "status" after);
  let round = List.hd (list (member "rounds" after)) in
  Alcotest.(check bool) "the round is open" true (member "result" round = `Null);
  Alcotest.(check string)
    "the pick" "current"
    (s "pick" (List.hd (list (member "picks" round))));
  Alcotest.(check bool)
    "its author may withdraw it" true
    (member "can_withdraw" after = `Bool true);
  let st, _ = call ~meth:"DELETE" ("suggestions/" ^ hash) in
  Alcotest.(check int) "withdrawn" 204 st;
  let _, after = call ("suggestions/" ^ hash) in
  Alcotest.(check string) "withdrawn" "withdrawn" (s "status" after);
  let _, np = call "note_prompt" in
  Alcotest.(check bool) "nothing runs" true (member "running" np = `Null)

(* ISS-52609: the Inbox. A member of the circle this test signs for, joined from a dinner Ada
   hosts, so the node reads what they send as it reads any other member. *)
type peer = {
  p_identity : Crypto.signing_key;
  p_device : Crypto.signing_key;
  p_enc : Crypto.encryption_key;
  mutable p_seq : int;
  mutable p_prev : string option;
}

let hours_ago h = Time_fmt.of_unix (Unix.gettimeofday () -. (h *. 3600.))

(* The envelope [p] would write next, signed and chained but not imported. *)
let peer_sign n p ?(created_at = Time_fmt.now ()) kind body =
  let sg =
    Envelope.create ~key:p.p_device ~seq:p.p_seq ?prev:p.p_prev ~created_at
      ~epoch:(Node.fold n).epoch ~kind body
  in
  let h = Envelope.hash sg.envelope in
  p.p_seq <- p.p_seq + 1;
  p.p_prev <- Some h;
  (sg, h)

let peer_write n p ?created_at kind body =
  let sg, h = peer_sign n p ?created_at kind body in
  ignore (ok (Node.import n sg));
  h

(* [p]'s envelope in the log before the run loop's pass has indexed it. *)
let peer_arrive n p ?created_at kind body =
  let sg, h = peer_sign n p ?created_at kind body in
  ignore (ok (Core_node.import n sg));
  h

let join_peer n name =
  let inv = Crypto.generate_signing_key () in
  let host = Option.get (Log.get_config n.Node.log Node.k_identity) in
  let dinner, _ =
    ok
      (Node.write n ~kind:"dinner"
         (Bodies.dinner_json
            {
              host;
              date = String.sub (hours_ago 2.) 0 10;
              label = "Items dinner";
              guests =
                [
                  {
                    Bodies.name;
                    invite_key = Keys.public inv;
                    expires_at = hours_ago (-30.);
                    admission = None;
                  };
                ];
              relays = [ "https://relay-1.example" ];
            }))
  in
  let p =
    {
      p_identity = Crypto.generate_signing_key ();
      p_device = Crypto.generate_signing_key ();
      p_enc = Result.get_ok (Crypto.encryption_key_of_secret (Crypto.random 32));
      p_seq = 1;
      p_prev = None;
    }
  in
  let join =
    Envelope.create ~key:inv ~seq:1 ~created_at:(hours_ago 1.)
      ~epoch:(Node.fold n).epoch ~kind:"join"
      (Bodies.make_join ~invite_key:inv ~dinner_hash:dinner
         ~identity:p.p_identity ~device:p.p_device)
  in
  ignore (ok (Node.import n join));
  ignore
    (peer_write n p ~created_at:(hours_ago 0.9) "card"
       (Bodies.make_card ~name ~agent_name:"Pax"
          ~encryption_key:(Keys.encryption_public p.p_enc)));
  p

let raw_key k = Result.get_ok (Keys.decode_x25519 k)

(* An item [p] sends: to the circle in the clear, or sealed to [members] (identities, with the raw
   X25519 keys [keys]) and to [p]. *)
let peer_item_body p ~to_ item =
  match to_ with
  | `Circle -> Item.item_body ~to_:Circle ~keys:[] item
  | `Members (ids, keys) ->
      Item.item_body ~to_:(Members ids) ~keys:(p.p_enc.public :: keys) item

let peer_item n p ?created_at ?(to_ = `Circle) (item : Item.t) =
  peer_write n p ?created_at "item" (peer_item_body p ~to_ item)

let question ?(kind = "question") ?(options = []) ?default ?deadline title :
    Item.t =
  {
    kind;
    subject = None;
    voice = "agent";
    title;
    detail = "";
    about = None;
    quote = None;
    options;
    default;
    deadline;
    adopted = None;
    link = None;
  }

(* DIG-219: the Inbox's index reads past its watermark, and still opens an item whose body arrives
   after a pass read past it, and one at a local order a removed envelope held. *)
let inbox_index_mark () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let titles () = List.map (s "title") (list (snd (call "items"))) in
  let has t = List.mem t (titles ()) in
  ignore (peer_item n pia (question "First?"));
  Alcotest.(check bool) "an item that arrived" true (has "First?");
  let late, _ =
    peer_sign n pia "item" (peer_item_body pia ~to_:`Circle (question "Late?"))
  in
  ignore (ok (Node.import n { late with body = None }));
  ignore (peer_item n pia (question "After?"));
  Alcotest.(check (pair bool bool))
    "read past the one without its body" (true, false)
    (has "After?", has "Late?");
  ignore (ok (Node.import n late));
  Alcotest.(check bool) "opened once its body arrives" true (has "Late?");
  let newest = Store.Stages.newest_order n.log in
  let prev = pia.p_prev in
  let last = peer_item n pia (question "Removed?") in
  Log.delete n.log last;
  pia.p_seq <- pia.p_seq - 1;
  pia.p_prev <- prev;
  let again = peer_item n pia (question "Again?") in
  Alcotest.(check bool)
    "a removed envelope's order is not given again" true
    ((Option.get (Log.find n.log again)).local_order > newest + 1);
  Alcotest.(check bool) "read after a removal" true (has "Again?")

(* DIG-179: the count beside Inbox is one for each bold row, and the Inbox lists threads: every
   item about one message is one row, bold while any of them is Draft or New. *)
let inbox_count_threads () =
  let log = fresh_log () in
  let me = "ed25519:me" and roman = "ed25519:roman" in
  let at = Time_fmt.now () in
  let add ?about ?read_at id =
    Store.Items.add log ~id ~author:roman
      ~item:{ (question ("Item " ^ id)) with kind = "notice"; about }
      ~to_:Circle ~created_at:at ~sent_at:at ?read_at ()
  in
  let count () =
    Store.Items.inbox_count log ~now:(Unix.gettimeofday ()) ~me ()
  in
  List.iter
    (fun id -> add ~about:"sha256:idea" id)
    [ "adopt-1"; "adopt-2"; "adopt-3"; "adopt-4" ];
  Alcotest.(check int) "four unread items about one note are one" 1 (count ());
  add "alone";
  Alcotest.(check int)
    "an item about nothing is a thread of its own" 2 (count ());
  add ~about:"sha256:other" ~read_at:at "read-1";
  Alcotest.(check int)
    "a thread with nothing unread is not counted" 2 (count ());
  add ~about:"sha256:other" "unread-2";
  Alcotest.(check int) "one unread item makes its thread count" 3 (count ());
  (* DIG-225: a thread is read by its key, oldest first, the Archive included. *)
  Store.Items.archive log "adopt-2" ~at;
  let thread key =
    List.map
      (fun (r : Store.Items.row) -> r.id)
      (Store.Items.thread log ~now:(Unix.gettimeofday ()) ~me key)
  in
  Alcotest.(check (list string))
    "every item about the note, the archived one too"
    [ "adopt-1"; "adopt-2"; "adopt-3"; "adopt-4" ]
    (thread "sha256:idea");
  Alcotest.(check (list string))
    "an item about nothing is its own key" [ "alone" ] (thread "alone");
  Alcotest.(check (list string))
    "an item about a note is not under its own id" [] (thread "adopt-1")

let envelopes_of n kind = List.length (Log.of_kind n.Node.log kind)

let body_of n hash =
  match Log.find n.Node.log hash with
  | Some { signed = { body = Some b; _ }; _ } -> b
  | _ -> Alcotest.fail "not in the log"

let by_id items id = List.find (fun i -> s "id" i = id) (list items)
let int_of name j = match member name j with `Int i -> i | _ -> -1

(* ISS-52612: the note's Questions part goes out as circle items when the note does, and the
   asker's agent closes an answered one naming the answer, under the asker's own close. *)
let note_questions_parsed () =
  Alcotest.(check (list string))
    "each line ending in a question mark, at most two"
    [ "Who has a fake clock?"; "Which relay?" ]
    (Note_checks.questions
       "Worked on: x.\n\
        Stuck on: y.\n\
        Questions:\n\
        - Who has a fake clock?\n\n\
        2. Which relay?\n\
        * A third?\n");
  Alcotest.(check (list string))
    "on the heading's own line"
    [ "Who has a fake clock?" ]
    (Note_checks.questions "Stuck on: y.\nQuestions: Who has a fake clock?");
  Alcotest.(check (list string))
    "Nothing asks none" []
    (Note_checks.questions "Stuck on: nothing.\nQuestions:\nNothing.");
  Alcotest.(check (list string))
    "no part, none" []
    (Note_checks.questions "Worked on: x?\nStuck on: is it?")

let note_questions_and_closer () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  (* Each call reads the node afresh, as each `digestif question` command does. *)
  let text =
    "Worked on: the timer tests.\n\
     Stuck on: the clock tests flake in CI.\n\
     Questions:\n\
     - Has anyone used a fake clock for timer tests?\n\
     - Which relay region answers fastest from Europe?"
  in
  let id = ok (Api.submit_note_text ~approve:true n text) in
  (* Every question the note asked, read from the store: none is in Ada's own Inbox. *)
  let inbox () = list (snd (call "items?subject=note_question")) in
  let asked () =
    ignore (inbox ());
    Store.Items.page n.log ~now:(Unix.gettimeofday ()) ~kind:"question"
      ~limit:200 ()
    |> List.filter (fun (r : Store.Items.row) ->
        r.item.subject = Some "note_question")
    |> List.map (fun (r : Store.Items.row) -> snd (call ("items/" ^ r.id)))
  in
  let in_inbox id = List.exists (fun i -> s "id" i = id) (inbox ()) in
  Alcotest.(check int)
    "nothing goes out before the note" 0
    (List.length (asked ()));
  Api.send_notes n;
  let note_hash =
    Option.get (Option.get (Store.Notes.find n.log id)).n_posted_hash
  in
  Api.send_notes n;
  let qs = asked () in
  Alcotest.(check int)
    "each question once, as the note goes out" 2 (List.length qs);
  let first =
    snd
      (call
         ("items/"
         ^ s "id"
             (List.find
                (fun i ->
                  s "title" i = "Has anyone used a fake clock for timer tests?")
                qs)))
  in
  Alcotest.(check (list string))
    "to the circle, from the agent, about the note"
    [ "true"; "agent"; note_hash ]
    [
      Yojson.Safe.to_string (member "circle" (member "to" first));
      s "voice" first;
      s "about" first;
    ];
  let qid = s "id" first and qhash = s "hash" first in
  (* ISS-64736: the note's questions are Ada's own, so her Inbox leaves them out. *)
  Alcotest.(check bool) "not in her Inbox" false (in_inbox qid);
  Alcotest.(check bool)
    "in the clear on the wire" true
    (member "item" (body_of n qhash) <> `Null);
  Alcotest.(check int)
    "nothing to close without an answer" 0
    (List.length (Api.Questions.open_answered (Api.ctx_of n)));
  let ans =
    peer_write n pia "item_answer"
      (`Assoc
         [
           ("item", `String qhash);
           ("text", `String "We use a fake clock injected at startup.");
           ("voice", `String "person");
         ])
  in
  Alcotest.(check bool) "the answer brings it in" true (in_inbox qid);
  (match Api.Questions.open_answered (Api.ctx_of n) with
  | [ q ] ->
      Alcotest.(check string) "the answered question" qid (s "id" q);
      Alcotest.(check string)
        "with its answer" ans
        (s "hash" (List.hd (list (member "answers" q))))
  | l -> Alcotest.failf "%d questions to close" (List.length l));
  Alcotest.(check bool)
    "an answer that is not its own" true
    (Result.is_error (Api.Questions.close (Api.ctx_of n) qid ~answer:note_hash));
  ok (Api.Questions.close (Api.ctx_of n) qid ~answer:ans);
  let _, r = call ("items/" ^ qid) in
  Alcotest.(check (list string))
    "the agent closed it, naming the answer" [ "true"; "agent"; ans ]
    [
      Yojson.Safe.to_string (member "closed" r);
      s "voice" (member "close" r);
      s "answer" (member "close" r);
    ];
  Alcotest.(check int)
    "closed, it is not read again" 0
    (List.length (Api.Questions.open_answered (Api.ctx_of n)));
  (* The asker reopens it: theirs stands, and the agent never closes over it. *)
  let _, r =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("closed", `Bool false) ])
      ("items/" ^ qid ^ "/close")
  in
  Alcotest.(check bool) "reopened" false (member "closed" r = `Bool true);
  Alcotest.(check int)
    "the person's close keeps the agent off it" 0
    (List.length (Api.Questions.open_answered (Api.ctx_of n)));
  Alcotest.(check bool)
    "and its close is refused" true
    (Result.is_error (Api.Questions.close (Api.ctx_of n) qid ~answer:ans));
  (* The asker names a different answer: theirs is the one that stands. *)
  let other =
    peer_write n pia "item_answer"
      (`Assoc
         [
           ("item", `String qhash);
           ("text", `String "Or run the suite under faketime.");
           ("voice", `String "person");
         ])
  in
  let _, r =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("closed", `Bool true); ("answer", `String other) ])
      ("items/" ^ qid ^ "/close")
  in
  Alcotest.(check (pair string string))
    "renamed by the asker" ("person", other)
    (s "voice" (member "close" r), s "answer" (member "close" r));
  Alcotest.(check int)
    "every close kept" 3
    (List.length (list (member "closes" r)))

(* ISS-83154: the Inbox agent answers a note as well as a question: within the brief, a reply in
   the circle in the agent's voice; else a draft reply the member reads on the work notice about the
   note and on the note, and sends as their own. The member asks for one on demand, and a read run
   drafts it and never sends it. *)
let inbox_agent_note_replies () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let note text =
    peer_write n pia "summary" (Content.summary_body ~text ~voice:"agent" ())
  in
  let n1 = note "How does your agent verify a UI change with no browser?" in
  let n2 = note "How do you keep a large suite from timing out?" in
  let n3 = note "Anyone sharding specs across machines?" in
  let run answers items =
    let st, r =
      call ~meth:"POST"
        ~body:
          (`Assoc
             [
               ("reviews", `List []);
               ("answers", `List answers);
               ("items", `List items);
             ])
        "inbox_agent/runs"
    in
    Alcotest.(check int) "recorded" 200 st;
    r
  in
  let answer ?send h text =
    `Assoc
      ([ ("item", `String h); ("text", `String text) ]
      @ match send with Some b -> [ ("send", `Bool b) ] | None -> [])
  in
  let summaries = envelopes_of n "summary" in
  let r =
    run
      [
        answer n1 "It screenshots the page.";
        answer ~send:false n2 "We shard it by spec.";
        answer ~send:false n3 "Yes, by file.";
      ]
      [
        `Assoc
          [
            ("subject", `String "work");
            ("title", `String "Answer Pia on sharding");
            ("about", `String n3);
          ];
      ]
  in
  let outcome h =
    s "outcome"
      (List.find (fun a -> s "item" a = h) (list (member "answers" r)))
  in
  Alcotest.(check (list string))
    "within the brief sent; past it kept" [ "sent"; "kept"; "kept" ]
    [ outcome n1; outcome n2; outcome n3 ];
  Alcotest.(check int)
    "one reply on the wire" (summaries + 1) (envelopes_of n "summary");
  let reply =
    List.find
      (fun (row : Log.row) -> (Content.read row.signed.body).reply_to = Some n1)
      (Log.of_kind n.log "summary")
  in
  Alcotest.(check string)
    "in the agent's voice" "agent" (Content.read reply.signed.body).voice;
  let written = list (member "items" r) in
  Alcotest.(check (list string))
    "a kept reply with no work notice gets one; the run's own carries the other"
    [ "Answer Pia on sharding"; "Reply to Pia Gale's note" ]
    (List.map (s "title") written);
  let item_of title =
    snd
      (call
         ("items/" ^ s "id" (List.find (fun i -> s "title" i = title) written)))
  in
  let w2 = item_of "Reply to Pia Gale's note" in
  Alcotest.(check string) "the note it replies to" n2 (s "reply_to" w2);
  Alcotest.(check string)
    "the draft reply on the work notice" "We shard it by spec."
    (s "text" (member "agent_answer" w2));
  Alcotest.(check string)
    "and on the run's own" "Yes, by file."
    (s "text" (member "agent_answer" (item_of "Answer Pia on sharding")));
  let _, m2 = call ("messages/" ^ n2) in
  Alcotest.(check bool)
    "the note can take a draft" true
    (member "can_draft_reply" m2 = `Bool true);
  Alcotest.(check string)
    "and shows it" "We shard it by spec."
    (s "text" (member "agent_answer" m2));
  (* The member sends it, edited, as their own reply: the agent's draft is done. *)
  let st, _ =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("text", `String "We shard it by spec, four ways.");
             ("reply_to", `String n2);
           ])
      "messages"
  in
  Alcotest.(check int) "sent" 201 st;
  Alcotest.(check bool)
    "no draft once replied" true
    (member "agent_answer" (snd (call ("messages/" ^ n2))) = `Null);
  (* On demand: a draft reply asked for is drafted by the next read run and never sent. *)
  let n4 = note "What model do you run nightly?" in
  let st, d = call ~meth:"POST" ("messages/" ^ n4 ^ "/draft-reply") in
  Alcotest.(check int) "asked" 202 st;
  Alcotest.(check string) "asked" "asked" (s "status" d);
  Alcotest.(check bool)
    "waits for a read run" true
    (Store.Reviews.drafts_waiting n.log);
  Alcotest.(check string)
    "the note says so" "asked"
    (s "status" (member "draft_reply" (snd (call ("messages/" ^ n4)))));
  let ctx =
    Behaviors.context
      ~drafts:(Store.Reviews.hand_drafts n.log ~at:(Time_fmt.now ()), false)
      ~hook:Read ~dir:n.dir ~digestif:"digestif" ~api:None ~sources:[]
      ~now:(Unix.gettimeofday ())
      ~deadline:(Unix.gettimeofday () +. 60.)
      ()
  in
  Alcotest.(check bool)
    "handed to the read run" true
    (member "draft_replies" ctx = `List [ `String n4 ]
    && member "read_circle" ctx = `Bool false);
  Alcotest.(check bool)
    "and no longer waiting" false
    (Store.Reviews.drafts_waiting n.log);
  let summaries = envelopes_of n "summary" in
  let r = run [ answer n4 "Opus, nightly." ] [] in
  Alcotest.(check string)
    "kept, though sendable" "kept"
    (s "outcome"
       (List.find (fun a -> s "item" a = n4) (list (member "answers" r))));
  Alcotest.(check int) "nothing sent" summaries (envelopes_of n "summary");
  Alcotest.(check int)
    "no work notice: the member is on its page" 0
    (List.length (list (member "items" r)));
  let _, m4 = call ("messages/" ^ n4) in
  Alcotest.(check string)
    "the draft" "Opus, nightly."
    (s "text" (member "agent_answer" m4));
  Alcotest.(check bool) "asked no more" true (member "draft_reply" m4 = `Null);
  (* A run that wrote none: the draft failed, saying why. *)
  ignore (call ~meth:"POST" ("messages/" ^ n3 ^ "/draft-reply"));
  ignore (Store.Reviews.hand_drafts n.log ~at:(Time_fmt.now ()));
  Store.Reviews.settle_drafts n.log ~at:(Time_fmt.now ())
    ~why:"Your agent wrote no reply.";
  let dr = member "draft_reply" (snd (call ("messages/" ^ n3))) in
  Alcotest.(check (pair string string))
    "failed"
    ("failed", "Your agent wrote no reply.")
    (s "status" dr, s "why" dr);
  (* Only another member's note takes one. *)
  let st, own =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "My own note.") ])
      "messages"
  in
  Alcotest.(check int) "posted" 201 st;
  Alcotest.(check int)
    "not the member's own" 422
    (fst (call ~meth:"POST" ("messages/" ^ s "hash" own ^ "/draft-reply")));
  Alcotest.(check bool)
    "which offers none" true
    (member "can_draft_reply" own = `Null);
  Alcotest.(check int)
    "nor one gone" 404
    (fst (call ~meth:"POST" "messages/sha256:nope/draft-reply"))

let inbox_drafts_and_sending () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  Alcotest.(check int)
    "nothing waits in a new Inbox" 0
    (int_of "inbox" (snd (call "status")));
  let ben =
    List.find (fun m -> s "name" m = "Ben Ortiz") (list (snd (call "members")))
    |> s "identity"
  in
  (* A draft stays on the machine. *)
  let st, d =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "question");
             ("title", `String "Anyone tried fake clocks?");
             ("detail", `String "For timer tests.");
           ])
      "items"
  in
  Alcotest.(check int) "saved" 201 st;
  Alcotest.(check string) "a draft" "draft" (s "status" d);
  Alcotest.(check bool)
    "to the circle by default" true
    (member "circle" (member "to" d) = `Bool true);
  Alcotest.(check int) "nothing signed" 0 (envelopes_of n "item");
  Alcotest.(check int)
    "a draft counts in the Inbox" 1
    (int_of "inbox" (snd (call "status")));
  let id = s "id" d in
  let st, d =
    call ~meth:"PUT"
      ~body:
        (`Assoc
           [
             ("title", `String "Anyone tried a fake clock?");
             ("detail", `String "For timer tests in CI.");
           ])
      ("items/" ^ id)
  in
  Alcotest.(check int) "edited" 200 st;
  Alcotest.(check string) "the member's own words" "person" (s "voice" d);
  Alcotest.(check bool) "no agent words kept" true (member "drafted" d = `Null);
  (* Sending signs it in the clear for the circle. *)
  let st, sent = call ~meth:"POST" ("items/" ^ id ^ "/send") in
  Alcotest.(check int) "sent" 201 st;
  Alcotest.(check string) "the same id" id (s "id" sent);
  Alcotest.(check string) "its author has read it" "read" (s "status" sent);
  let hash = s "hash" sent in
  let b = body_of n hash in
  Alcotest.(check string) "to the circle" "circle" (s "to" b);
  Alcotest.(check string)
    "signed plaintext" "Anyone tried a fake clock?"
    (s "title" (member "item" b));
  (match Log.find n.log hash with
  | Some r ->
      Alcotest.(check bool) "verifies" true (Envelope.verify r.signed = Ok ())
  | None -> Alcotest.fail "not in the log");
  Alcotest.(check int)
    "a sent draft is not edited" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("title", `String "x") ])
          ("items/" ^ id)));
  Alcotest.(check int)
    "nor discarded" 422
    (fst (call ~meth:"DELETE" ("items/" ^ id)));
  (* The deny layer reads every word before anything is signed, and nothing is kept. *)
  let st, _ =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "notice");
             ("title", `String "Notes moved");
             ("detail", `String "They are at internal.example.com now.");
             ("send", `Bool true);
           ])
      "items"
  in
  Alcotest.(check int) "refused" 422 st;
  Alcotest.(check int) "nothing signed" 1 (envelopes_of n "item");
  Alcotest.(check int)
    "nothing kept" 1
    (List.length
       (Store.Items.page n.log ~now:(Unix.gettimeofday ()) ~limit:200 ()));
  (* Named members get it sealed. *)
  let st, named =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "notice");
             ("circle", `Bool false);
             ("members", `List [ `String ben ]);
             ("title", `String "Coffee next week");
             ("send", `Bool true);
           ])
      "items"
  in
  Alcotest.(check int) "sent named" 201 st;
  let b = body_of n (s "hash" named) in
  Alcotest.(check bool)
    "sealed, naming Ben in the clear" true
    (member "sealed" b <> `Null
    && member "item" b = `Null
    && member "to" b = `List [ `String ben ]);
  Alcotest.(check string)
    "its author reads it back" "Coffee next week" (s "title" named);
  (* What a member may not write. *)
  let refused body = fst (call ~meth:"POST" ~body:(`Assoc body) "items") in
  Alcotest.(check int)
    "an empty title" 422
    (refused [ ("kind", `String "question"); ("title", `String " ") ]);
  Alcotest.(check int)
    "a choice of their own" 422
    (refused [ ("kind", `String "choice"); ("title", `String "Pick") ]);
  Alcotest.(check int)
    "work" 422
    (refused
       [
         ("kind", `String "notice");
         ("subject", `String "work");
         ("title", `String "Do it");
       ]);
  Alcotest.(check int)
    "an intro naming one person" 422
    (refused
       [
         ("kind", `String "notice");
         ("subject", `String "intro");
         ("circle", `Bool false);
         ("members", `List [ `String ben ]);
         ("title", `String "Meet");
       ]);
  Alcotest.(check int)
    "no members" 422
    (refused
       [
         ("kind", `String "notice");
         ("circle", `Bool false);
         ("title", `String "Hi");
       ]);
  Alcotest.(check int)
    "someone outside the circle" 422
    (refused
       [
         ("kind", `String "notice");
         ("circle", `Bool false);
         ("members", `List [ `String "ed25519:nobody" ]);
         ("title", `String "Hi");
       ]);
  (* An agent's draft keeps its words beside the member's edit. *)
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let agent_id = "item-agent" in
  Store.Items.add n.log ~id:agent_id ~author:me
    ~item:{ (question "Intro Ben to Cy?") with kind = "notice" }
    ~to_:Circle ~created_at:(Time_fmt.now ()) ();
  let _, edited =
    call ~meth:"PUT"
      ~body:
        (`Assoc
           [
             ("title", `String "Ben, meet Cy");
             ("detail", `String "Both of you fight timers.");
           ])
      ("items/" ^ agent_id)
  in
  Alcotest.(check string) "edited: the member's" "person" (s "voice" edited);
  Alcotest.(check string)
    "the agent's words kept" "Intro Ben to Cy?"
    (s "title" (member "drafted" edited));
  Alcotest.(check int)
    "discarded" 204
    (fst (call ~meth:"DELETE" ("items/" ^ agent_id)));
  Alcotest.(check int) "gone" 404 (fst (call ("items/" ^ agent_id)))

(* DIG-536: a node signs no item_answer whose only reader is its author. *)
let inbox_no_reply_to_self () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let notice title = { (question title) with kind = "notice" } in
  let yes_no title =
    question ~kind:"choice"
      ~options:
        [
          { Item.id = "yes"; label = "Yes"; recommended = false };
          { id = "no"; label = "No"; recommended = true };
        ]
      ~default:"no" title
  in
  (* An own item named to the member alone, and one named to Pia. *)
  let own_item item ~named ~keys =
    let h, _ =
      ok
        (Node.write n ~kind:"item"
           (Item.item_body ~to_:(Members named) ~keys item))
    in
    h
  in
  let reply h =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "A note to myself.") ])
      ("items/" ^ h ^ "/answers")
  in
  let before = envelopes_of n "item_answer" in
  (* 1. An own notice to the member alone. *)
  let h1 =
    own_item (notice "A practice notice") ~named:[ me ] ~keys:[ raw_key my_key ]
  in
  let st, r = reply h1 in
  Alcotest.(check int) "1: refused" 422 st;
  Alcotest.(check string) "1: to_self" "to_self" (s "code" (List.hd (list r)));
  Alcotest.(check int) "1: nothing signed" before (envelopes_of n "item_answer");
  (* 2. An own choice to the member alone. *)
  let h2 =
    own_item (yes_no "Which one?") ~named:[ me ] ~keys:[ raw_key my_key ]
  in
  let st, r = reply h2 in
  Alcotest.(check int) "2: refused" 422 st;
  Alcotest.(check string) "2: to_self" "to_self" (s "code" (List.hd (list r)));
  Alcotest.(check int) "2: nothing signed" before (envelopes_of n "item_answer");
  (* 3. Pia's notice to the member. *)
  let h3 =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (notice "Pia's notice")
  in
  let st, _ = reply h3 in
  Alcotest.(check int) "3: taken" 201 st;
  (* 4. An own notice to Pia. *)
  let h4 =
    own_item (notice "For Pia") ~named:[ pia_id ]
      ~keys:[ raw_key my_key; pia.p_enc.public ]
  in
  let st, _ = reply h4 in
  Alcotest.(check int) "4: taken" 201 st;
  Alcotest.(check int)
    "3 and 4: two on the wire" (before + 2)
    (envelopes_of n "item_answer");
  (* 5. An agent-voice work notice by the member to the member alone. *)
  let h5 =
    own_item
      { (notice "Work for me") with subject = Some "work" }
      ~named:[ me ]
      ~keys:[ raw_key my_key ]
  in
  let st, r = reply h5 in
  Alcotest.(check int) "5: refused" 422 st;
  Alcotest.(check string) "5: to_self" "to_self" (s "code" (List.hd (list r)));
  (* 6. An own notice to the circle takes a reply. *)
  let h6 =
    let h, _ =
      ok
        (Node.write n ~kind:"item"
           (Item.item_body ~to_:Circle ~keys:[] (notice "For everyone")))
    in
    h
  in
  let st, _ = reply h6 in
  Alcotest.(check int) "6: taken" 201 st;
  (* 7. An own notice to the member and Pia takes a reply. *)
  let h7 =
    own_item (notice "For us two") ~named:[ me; pia_id ]
      ~keys:[ raw_key my_key; pia.p_enc.public ]
  in
  let st, _ = reply h7 in
  Alcotest.(check int) "7: taken" 201 st;
  Alcotest.(check int)
    "3, 4, 6 and 7: four on the wire" (before + 4)
    (envelopes_of n "item_answer");
  (* 8. An old self-reply stays listed. *)
  ignore
    (ok
       (Node.write n ~kind:"item_answer"
          (Item.answer_body ~item:h1 ~to_:(Members [ me ])
             ~keys:[ raw_key my_key ]
             ~text:"An old note." ~voice:"person")));
  let _, r = call ("items/" ^ h1) in
  Alcotest.(check int)
    "8: the old reply is listed" 1
    (List.length (list (member "answers" r)))

(* DIG-538: a node signs no answer on a closed question. A reply on a closed notice or choice is
   taken: it reopens nothing, and a pick carries no text. *)
let inbox_closed_question_takes_no_answer () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let yes_no ?deadline title =
    question ~kind:"choice" ?deadline
      ~options:
        [
          { Item.id = "yes"; label = "Yes"; recommended = false };
          { id = "no"; label = "No"; recommended = true };
        ]
      ~default:"no" title
  in
  let to_pia item =
    let h, _ =
      ok
        (Node.write n ~kind:"item"
           (Item.item_body ~to_:(Members [ pia_id ])
              ~keys:[ raw_key my_key; pia.p_enc.public ]
              item))
    in
    h
  in
  let reply h =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "A word on it.") ])
      ("items/" ^ h ^ "/answers")
  in
  let is_closed h = member "closed" (snd (call ("items/" ^ h))) = `Bool true in
  let before = envelopes_of n "item_answer" in
  (* 1. Ada's question to Pia, closed by its author. *)
  let h1 = to_pia (question "Dinner on Thursday?") in
  let st, _ =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("closed", `Bool true) ])
      ("items/" ^ h1 ^ "/close")
  in
  Alcotest.(check int) "1: closed" 200 st;
  let st, r = reply h1 in
  Alcotest.(check int) "1: refused" 422 st;
  Alcotest.(check string) "1: closed" "closed" (s "code" (List.hd (list r)));
  Alcotest.(check int) "1: nothing signed" before (envelopes_of n "item_answer");
  (* 1b. Pia's question to the member, closed by Pia. *)
  let hb =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (question "Pia's question")
  in
  ignore
    (peer_write n pia "item_close"
       (Item.close_body ~item:hb ~to_:(Members [ me ])
          ~keys:[ raw_key my_key; pia.p_enc.public ]
          ~closed:true ~voice:"person" ()));
  Alcotest.(check bool) "1b: it is closed" true (is_closed hb);
  let st, r = reply hb in
  Alcotest.(check int) "1b: refused" 422 st;
  Alcotest.(check string) "1b: closed" "closed" (s "code" (List.hd (list r)));
  Alcotest.(check int)
    "1b: nothing signed" before
    (envelopes_of n "item_answer");
  (* 2. A choice past its deadline takes a reply. *)
  let h2 = to_pia (yes_no ~deadline:(hours_ago 1.) "Which one?") in
  Alcotest.(check bool) "2: it is closed" true (is_closed h2);
  let st, _ = reply h2 in
  Alcotest.(check int) "2: taken" 201 st;
  (* 3. A choice to one member, closed by that member's pick, takes a reply. *)
  let h3 = to_pia (yes_no "Red or blue?") in
  ignore
    (peer_write n pia "decision"
       (Item.pick_body ~item:h3 ~keys:[ raw_key my_key ] ~option:"yes"));
  Alcotest.(check bool) "3: the pick closed it" true (is_closed h3);
  let st, _ = reply h3 in
  Alcotest.(check int) "3: taken" 201 st;
  Alcotest.(check int)
    "2 and 3: two on the wire" (before + 2)
    (envelopes_of n "item_answer");
  (* 4. A peer's answer on the closed question is still listed. *)
  ignore
    (peer_write n pia "item_answer"
       (Item.answer_body ~item:h1 ~to_:(Members [ pia_id ])
          ~keys:[ raw_key my_key; pia.p_enc.public ]
          ~text:"Thursday works." ~voice:"person"));
  let _, r = call ("items/" ^ h1) in
  Alcotest.(check int)
    "4: the peer's answer is listed" 1
    (List.length (list (member "answers" r)));
  (* 5. Pia's question to the member, a week and more with no answer, closed by the clock. *)
  let before5 = envelopes_of n "item_answer" in
  let h5 =
    peer_item n pia ~created_at:(hours_ago 200.)
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (question "Pia's old question")
  in
  Alcotest.(check bool) "5: the clock closed it" true (is_closed h5);
  let st, r = reply h5 in
  Alcotest.(check int) "5: refused" 422 st;
  Alcotest.(check string) "5: closed" "closed" (s "code" (List.hd (list r)));
  Alcotest.(check int)
    "5: nothing signed" before5
    (envelopes_of n "item_answer");
  (* 6. A notice closed by its author still takes a reply. *)
  let h6 = to_pia { (question "A heads up") with kind = "notice" } in
  let st, _ =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("closed", `Bool true) ])
      ("items/" ^ h6 ^ "/close")
  in
  Alcotest.(check int) "6: closed" 200 st;
  let st, _ = reply h6 in
  Alcotest.(check int) "6: taken" 201 st

(* DIG-544: only an answer signed inside the week counts. A question that closed by itself stays
   closed when a peer's late answer arrives: the answer is kept and listed, and reopens nothing. An
   answer signed in the week counts whenever it arrives, and its author's own reopen still opens a
   closed question. *)
let inbox_late_answer_reopens_nothing () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let ask title ~hours =
    peer_item n pia ~created_at:(hours_ago hours) (question title)
  in
  let answer h ~hours =
    ignore
      (peer_write n quinn ~created_at:(hours_ago hours) "item_answer"
         (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
            ~voice:"person"))
  in
  let item h = snd (call ("items/" ^ h)) in
  let is_closed h = member "closed" (item h) = `Bool true in
  let listed h = List.length (list (member "answers" (item h))) in
  (* 1. Asked 250 hours ago, so it lapsed 82 hours ago; the answer is signed 50 hours ago. *)
  let h1 = ask "Late one?" ~hours:250. in
  Alcotest.(check bool) "1: closed by the clock" true (is_closed h1);
  answer h1 ~hours:50.;
  Alcotest.(check bool) "1: the late answer reopens nothing" true (is_closed h1);
  Alcotest.(check int) "1: and is still listed" 1 (listed h1);
  (* 2. The asker's own reopen opens it. *)
  ignore
    (peer_write n pia "item_close"
       (Item.close_body ~item:h1 ~to_:Circle ~keys:[] ~closed:false
          ~voice:"person" ()));
  Alcotest.(check bool) "2: the asker reopened it" false (is_closed h1);
  (* 3. Asked 250 hours ago, answered on day 6 (106 hours ago): it arrives on day 10 and counts. *)
  let h3 = ask "In-week one?" ~hours:250. in
  answer h3 ~hours:106.;
  Alcotest.(check bool) "3: an in-week answer counts" false (is_closed h3);
  Alcotest.(check int) "3: and is listed" 1 (listed h3);
  (* 4. DIG-91: an answer whose signed time is not in the Z form counts for nothing, as on the phone,
     however early its time reads, and is still listed. *)
  let answer_at h at =
    ignore
      (peer_write n quinn ~created_at:at "item_answer"
         (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
            ~voice:"person"))
  in
  let in_week = Time_fmt.of_unix (Unix.gettimeofday () -. (106. *. 3600.)) in
  let offset = String.sub in_week 0 19 ^ "+00:00" in
  List.iter
    (fun (what, at) ->
      let h = ask ("Non-Z, " ^ what) ~hours:250. in
      answer_at h at;
      Alcotest.(check bool)
        ("4: " ^ what ^ " counts for nothing")
        true (is_closed h);
      Alcotest.(check int) ("4: " ^ what ^ " is listed") 1 (listed h))
    [
      ("an offset", offset);
      ("no zone", String.sub in_week 0 19);
      ("garbage", "not a time");
      ("the 31st of February", "2026-02-31T10:00:00Z");
    ]

(* DIG-544: the boundary is strict, and the answer's signed time decides however the index meets it:
   an answer exactly a week after the question does not count, one a millisecond sooner does, and an
   answer indexed in an earlier pass than its question is judged the same way. *)
let inbox_late_answer_boundary_and_order () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let week = 7. *. 86_400. in
  let asked = Float.floor (Unix.gettimeofday ()) -. (8. *. 86_400.) in
  let item h = snd (call ("items/" ^ h)) in
  let is_closed h = member "closed" (item h) = `Bool true in
  let listed h = List.length (list (member "answers" (item h))) in
  let answer_body h =
    Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
      ~voice:"person"
  in
  (* 1. The boundary. *)
  let ask title =
    peer_item n pia ~created_at:(Time_fmt.of_unix asked) (question title)
  in
  let on_line = ask "On the line" and before = ask "A millisecond before" in
  ignore
    (peer_write n quinn
       ~created_at:(Time_fmt.of_unix (asked +. week))
       "item_answer" (answer_body on_line));
  ignore
    (peer_write n quinn
       ~created_at:(Time_fmt.of_unix (asked +. week -. 0.001))
       "item_answer" (answer_body before));
  Alcotest.(check bool)
    "1: at the lapse it does not count" true (is_closed on_line);
  Alcotest.(check int) "1: and is listed" 1 (listed on_line);
  Alcotest.(check bool)
    "1: a millisecond before it counts" false (is_closed before);
  (* 2. The answer is indexed before its question. *)
  let later_item title =
    let sg =
      Envelope.create ~key:pia.p_device ~seq:pia.p_seq ?prev:pia.p_prev
        ~created_at:(Time_fmt.of_unix asked) ~epoch:(Node.fold n).epoch
        ~kind:"item"
        (Item.item_body ~to_:Circle ~keys:[] (question title))
    in
    let h = Envelope.hash sg.envelope in
    pia.p_seq <- pia.p_seq + 1;
    pia.p_prev <- Some h;
    (h, sg)
  in
  let run_first title ~signed_at =
    let h, sg = later_item title in
    ignore
      (peer_write n quinn
         ~created_at:(Time_fmt.of_unix signed_at)
         "item_answer" (answer_body h));
    ignore (call "items");
    ignore (ok (Node.import n sg));
    h
  in
  let late =
    run_first "Late, answer first" ~signed_at:(asked +. week +. 3600.)
  in
  let early = run_first "In week, answer first" ~signed_at:(asked +. 86_400.) in
  Alcotest.(check bool) "2: a late answer reopens nothing" true (is_closed late);
  Alcotest.(check int) "2: and is listed" 1 (listed late);
  Alcotest.(check bool) "2: an in-week answer counts" false (is_closed early)

(* DIG-86: the member's answer is refused against the very time its envelope is signed with, by the
   expression the fold counts it by. Answering a peer's question at its lapse is refused; a
   millisecond before it the answer is taken, signed at that time, and counted, so the question
   stays answered. *)
let inbox_answer_refused_at_its_signed_time () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let week = 7. *. 86_400. in
  let asked = Float.floor (Unix.gettimeofday ()) -. (8. *. 86_400.) in
  let ask title =
    peer_item n pia ~created_at:(Time_fmt.of_unix asked) (question title)
  in
  let item h = snd (call ("items/" ^ h)) in
  let is_closed h = member "closed" (item h) = `Bool true in
  let answer_at h now =
    let ctx : Api.ctx =
      {
        node = n;
        fold = Node.fold n;
        now;
        on_write = (fun () -> ());
        upkeep_waits = true;
      }
    in
    let r = Option.get (Store.Items.by_hash n.log ~now h) in
    Api.Inbox.answer ctx r (Some (`Assoc [ ("text", `String "Thursday.") ]))
  in
  let answers () = Log.of_kind n.Node.log "item_answer" in
  let on_line = ask "On the line" and before = ask "A millisecond before" in
  ignore (item on_line);
  ignore (item before);
  let count = List.length (answers ()) in
  (* 1. At the lapse: refused, and nothing is signed. *)
  let (res : Api.response) = answer_at on_line (asked +. week) in
  Alcotest.(check int) "1: refused at the lapse" 422 res.status;
  Alcotest.(check bool)
    "1: as closed" true
    (contains
       (Yojson.Safe.to_string (Option.value res.body ~default:`Null))
       "closed");
  Alcotest.(check int) "1: nothing signed" count (List.length (answers ()));
  (* 2. A millisecond before: taken, signed at that very time, and counted. *)
  let t = asked +. week -. 0.001 in
  let (res : Api.response) = answer_at before t in
  Alcotest.(check int) "2: taken a millisecond before" 201 res.status;
  let signed =
    List.map (fun (r : Log.row) -> r.signed.envelope.created_at) (answers ())
  in
  Alcotest.(check (list string))
    "2: signed at the time it was checked against"
    [ Time_fmt.of_unix t ]
    signed;
  Alcotest.(check bool) "2: and counted" false (is_closed before);
  Alcotest.(check int)
    "2: listed" 1
    (List.length (list (member "answers" (item before))))

(* DIG-554: whether a follow-up counts is decided once and stored on its row. [counts_of] reads the
   stored result of every answer on [item], in order. *)
let stored_answers n item =
  List.map
    (fun (a : Store.Items.answer) -> a.a_counts)
    (Store.Items.answers n.Node.log item)

let stored_picks n item =
  List.map
    (fun (p : Store.Items.pick) -> p.p_counts)
    (Store.Items.picks n.Node.log item)

(* A second device of [p], admitted by its identity, so that one can be revoked while the first
   writes the revoke. *)
let second_device n p =
  let key = Crypto.generate_signing_key () in
  ignore
    (peer_write n p "device"
       (Bodies.make_device ~identity:p.p_identity ~key:(Keys.public key)
          ~role:Bodies.Device));
  { p with p_device = key; p_seq = 1; p_prev = None }

(* DIG-554: a member answers a circle question and then leaves. An answer inside the cutoff keeps
   counting, on a node that indexed it before the revoke and on one that indexes it after; one
   past the cutoff does not. An author never admitted does not count. *)
let inbox_follow_up_membership_is_the_cutoff () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let quinn2 = second_device n quinn in
  let ask title = peer_item n pia (question title) in
  let answer who h =
    peer_write n who "item_answer"
      (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
         ~voice:"person")
  in
  let listed h =
    List.length (list (member "answers" (snd (call ("items/" ^ h)))))
  in
  let h1 = ask "Indexed before the revoke" in
  let h2 = ask "Indexed after the revoke" in
  let h3 = ask "Past the cutoff" in
  ignore (answer quinn2 h1);
  ignore (call "items");
  ignore (answer quinn2 h2);
  ignore
    (peer_write n quinn "revoke"
       (Bodies.make_revoke ~by:quinn.p_identity
          ~target:(Keys.public quinn2.p_device)
          ~after_seq:[ (Keys.public quinn2.p_device, 2) ]
          ~mail_read:[]));
  ignore (answer quinn2 h3);
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: indexed before the revoke" [ Some true ] (stored_answers n h1);
  Alcotest.(check (list (option bool)))
    "2: indexed after, inside the cutoff" [ Some true ] (stored_answers n h2);
  Alcotest.(check (list (option bool)))
    "3: past the cutoff" [ Some false ] (stored_answers n h3);
  Alcotest.(check (list int))
    "the item view lists the same" [ 1; 1; 0 ]
    [ listed h1; listed h2; listed h3 ];
  (* A key the fold never admitted. *)
  let me = Option.get (Log.get_config n.Node.log Node.k_identity) in
  let mine, _ =
    ok
      (Node.write n ~kind:"item"
         (Item.item_body ~to_:Circle ~keys:[] (question "Mine, to the circle")))
  in
  ignore me;
  let stranger =
    {
      quinn with
      p_identity = Crypto.generate_signing_key ();
      p_device = Crypto.generate_signing_key ();
      p_seq = 1;
      p_prev = None;
    }
  in
  ignore (answer stranger mine);
  ignore (call "items");
  Alcotest.(check int) "4: a stranger's answer is not listed" 0 (listed mine);
  Alcotest.(check bool)
    "4: and the question still waits on others" true
    (List.exists
       (fun i -> s "id" i = mine)
       (list (snd (call "items?limit=200&state=others"))))

(* DIG-554: a revocation that arrives after a follow-up was decided changes the stored result, the
   same as on a node that had the revoke first. An answer past the cutoff, indexed in an earlier
   pass than the revoke, ends not counting and the question unanswered. *)
let inbox_follow_up_revoke_after_decision () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let quinn2 = second_device n quinn in
  let h =
    peer_item n pia ~created_at:(hours_ago 3.) (question "Revoked later")
  in
  (* Distinct signed times, so the stored order is the order written. *)
  let answer ago =
    peer_write n quinn2 ~created_at:(hours_ago ago) "item_answer"
      (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
         ~voice:"person")
  in
  ignore (answer 2.);
  ignore (answer 1.);
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: both counted before the revoke" [ Some true; Some true ]
    (stored_answers n h);
  ignore
    (peer_arrive n quinn "revoke"
       (Bodies.make_revoke ~by:quinn.p_identity
          ~target:(Keys.public quinn2.p_device)
          ~after_seq:[ (Keys.public quinn2.p_device, 1) ]
          ~mail_read:[]));
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "2: a page leaves the revoke to the run loop" [ Some true; Some true ]
    (stored_answers n h);
  keep_up n;
  Alcotest.(check (list (option bool)))
    "2: the one past the cutoff is decided again" [ Some true; Some false ]
    (stored_answers n h);
  Alcotest.(check int)
    "3: and the item lists one answer" 1
    (List.length (list (member "answers" (snd (call ("items/" ^ h))))))

(* DIG-236: a change of the fold names only the keys it changed, and what is forgotten for it is
   only what those keys signed: a revoke undecides that key's follow-ups and no one else's, and a
   join drops that key's unreadable rows and no one else's. *)
let inbox_fold_change_is_narrowed () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let quinn2 = second_device n quinn in
  let l = n.Node.log in
  let h = peer_item n pia (question "Answered twice") in
  let answer p =
    ignore
      (peer_write n p "item_answer"
         (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
            ~voice:"person"))
  in
  answer quinn;
  answer quinn2;
  let stranger () =
    {
      quinn with
      p_identity = Crypto.generate_signing_key ();
      p_device = Crypto.generate_signing_key ();
      p_seq = 1;
      p_prev = None;
    }
  in
  let s1 = stranger () and s2 = stranger () in
  ignore (peer_item n s1 (question "From a key never admitted"));
  ignore (peer_item n s2 (question "From another"));
  keep_up n;
  ignore (call "items");
  let config = "test_fold_keys" in
  let change () = fst (Api.Fold_keys.change l ~config (Node.fold n)) in
  let record () =
    Log.set_config l config (snd (Api.Fold_keys.change l ~config (Node.fold n)))
  in
  Alcotest.(check bool) "nothing recorded reads as All" true (change () = All);
  record ();
  Alcotest.(check bool)
    "recorded reads as Unchanged" true
    (change () = Unchanged);
  let target = Keys.public quinn2.p_device in
  ignore
    (peer_write n quinn "revoke"
       (Bodies.make_revoke ~by:quinn.p_identity ~target
          ~after_seq:[ (target, 5) ]
          ~mail_read:[]));
  Alcotest.(check bool)
    "a revoke names the revoked key alone" true
    (change () = Keys [ target ]);
  Alcotest.(check (list (option bool)))
    "both answers decided" [ Some true; Some true ] (stored_answers n h);
  Store.Items.forget_decisions ~authors:[ target ] l;
  Alcotest.(check (list (option bool)))
    "only the revoked key's answer is undecided" [ None; Some true ]
    (List.sort compare (stored_answers n h));
  let unreadable () =
    match
      Log.rows l
        "SELECT count(*) FROM ui_items WHERE kind IS NULL AND local = 0" []
    with
    | [ [| v |] ] -> Log.int v
    | _ -> -1
  in
  Alcotest.(check int) "two unreadable items" 2 (unreadable ());
  Store.Items.forget_unread ~authors:[ Keys.public s1.p_device ] l;
  Alcotest.(check int)
    "only the one that key signed is dropped" 1 (unreadable ())

(* DIG-554: an answer from a member's new device that reaches the log before the device's
   admission is decided once the admission arrives, as on a node that had the admission first. *)
let inbox_follow_up_before_its_admission () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let h = peer_item n pia (question "Answered early") in
  let key = Crypto.generate_signing_key () in
  let admission, _ =
    peer_sign n quinn "device"
      (Bodies.make_device ~identity:quinn.p_identity ~key:(Keys.public key)
         ~role:Bodies.Device)
  in
  let quinn2 = { quinn with p_device = key; p_seq = 1; p_prev = None } in
  ignore
    (peer_write n quinn2 "item_answer"
       (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
          ~voice:"person"));
  ignore
    (peer_write n quinn2 "decision"
       (Item.pick_body ~item:h
          ~keys:[ (ok (Node.encryption_key n)).public; pia.p_enc.public ]
          ~option:"yes"));
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: nothing counts while the key is unknown" [] (stored_answers n h);
  ignore (ok (Node.import n admission));
  keep_up n;
  Alcotest.(check (list (option bool)))
    "2: the answer counts once the admission is here" [ Some true ]
    (stored_answers n h);
  Alcotest.(check int)
    "3: and the pick is opened too" 1
    (List.length (stored_picks n h))

(* DIG-101: an item and an approval signed by a member's new device, reaching the log before the
   device's admission, read once the admission arrives as on a node that had it first: the item
   in the Inbox New, the approval listed and filed, and a decline by that device ending the
   approval it answers. [early] are written before the admission is here; [late] after, which
   is how a node that had the admission first sees them. *)
let item_and_approval_before_their_admission () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.Node.log Node.k_identity) in
  let my_raw =
    raw_key (Keys.encryption_public (Result.get_ok (Node.encryption_key n)))
  in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let approval who =
    peer_write n who "approval"
      (`Assoc
         [
           ("to", `List [ `String me; `String pia_id ]);
           ( "sealed",
             Item.seal
               ~keys:[ my_raw; pia.p_enc.public ]
               (Approval.request_to_json
                  {
                    kind = Invite;
                    created_at = Time_fmt.now ();
                    member = None;
                    document = Some "an admission";
                    removed_key = None;
                    added_key = None;
                  }) );
         ])
  in
  let decline who id =
    peer_write n who "approval_answer"
      (`Assoc
         [
           ("approval", `String id);
           ( "sealed",
             Item.seal
               ~keys:[ my_raw; pia.p_enc.public ]
               (Approval.reply_to_json Decline) );
         ])
  in
  (* Answered by the new device; started by the one already admitted. *)
  let answered = approval pia in
  let new_device () =
    let key = Crypto.generate_signing_key () in
    let admission, _ =
      peer_sign n pia "device"
        (Bodies.make_device ~identity:pia.p_identity ~key:(Keys.public key)
           ~role:Bodies.Device)
    in
    (admission, { pia with p_device = key; p_seq = 1; p_prev = None })
  in
  let admission, early = new_device () in
  let item = peer_item n early (question "Sent before the admission") in
  let started = approval early in
  ignore (decline early answered);
  let items () = list (snd (call "items?limit=200")) in
  let listed id = List.exists (fun i -> s "id" i = id) (items ()) in
  let approvals q = List.map (s "id") (list (snd (call ("approvals" ^ q)))) in
  Alcotest.(check bool) "1: the item is not read yet" false (listed item);
  Alcotest.(check (list string))
    "1: nor the approval it started" [ answered ] (approvals "");
  Alcotest.(check (list string))
    "1: nor the decline" [ answered ]
    (approvals "?state=waiting");
  ignore (ok (Node.import n admission));
  (* The same writes from a device whose admission came first. *)
  let admission2, late = new_device () in
  ignore (ok (Node.import n admission2));
  let item2 = peer_item n late (question "Sent after the admission") in
  let started2 = approval late in
  keep_up n;
  let status id = s "status" (snd (call ("items/" ^ id))) in
  Alcotest.(check bool) "2: the item is read" true (listed item);
  Alcotest.(check string)
    "2: and reads as the one sent after" (status item2) (status item);
  Alcotest.(check (list string))
    "2: the approval is listed beside the one started after"
    (List.sort compare [ answered; started; started2 ])
    (List.sort compare (approvals ""));
  let filed id =
    member "item"
      (List.find (fun a -> s "id" a = id) (list (snd (call "approvals"))))
    <> `Null
  in
  Alcotest.(check (pair bool bool))
    "2: and filed in the Inbox as that one is"
    (filed started2, true)
    (filed started, filed started2);
  Alcotest.(check (list string))
    "2: the decline ends the approval it answers" [ answered ]
    (approvals "?state=declined")

(* DIG-554: this node's own key counts only while the fold has not admitted it; a revocation of the
   node's own device binds it. *)
let inbox_follow_up_own_key_revoked () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let h = peer_item n pia (question "Answered by me") in
  let identity =
    (Result.get_ok (Phrase.derive Demo.ada_phrase)).Phrase.identity
  in
  let mine = Keys.public (Result.get_ok (Node.device_key n)) in
  let d2 = Crypto.generate_signing_key () in
  ignore
    (ok
       (Node.write n ~kind:"device"
          (Bodies.make_device ~identity ~key:(Keys.public d2)
             ~role:Bodies.Device)));
  let answer_hash, sg =
    ok
      (Node.write n ~kind:"item_answer"
         (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Mine."
            ~voice:"person"))
  in
  ignore answer_hash;
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: counted while unrevoked" [ Some true ] (stored_answers n h);
  let second =
    { pia with p_identity = identity; p_device = d2; p_seq = 1; p_prev = None }
  in
  ignore
    (peer_write n second "revoke"
       (Bodies.make_revoke ~by:identity ~target:mine
          ~after_seq:[ (mine, sg.envelope.seq - 1) ]
          ~mail_read:[]));
  keep_up n;
  Alcotest.(check (list (option bool)))
    "2: the revoked own key no longer counts" [ Some false ]
    (stored_answers n h)

(* DIG-554: a store upgraded from before the column holds rows with counts NULL and no rule version;
   the first pass decides every one. *)
let inbox_follow_up_bare_upgrade () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let h1 = peer_item n pia (question "One") in
  let h2 = peer_item n pia (question "Two") in
  List.iter
    (fun h ->
      ignore
        (peer_write n quinn "item_answer"
           (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
              ~voice:"person")))
    [ h1; h2 ];
  ignore (call "items");
  let l = n.Node.log in
  Log.exec l "UPDATE ui_item_answers SET counts = NULL" [];
  Log.exec l "UPDATE ui_item_picks SET counts = NULL" [];
  Log.unset_config l Api.Inbox.k_rule;
  Log.unset_config l Api.Inbox.k_fold;
  Alcotest.(check (list (option bool)))
    "1: undecided before" [ None ] (stored_answers n h1);
  keep_up n;
  Alcotest.(check (list (list (option bool))))
    "2: every row decided in the first pass"
    [ [ Some true ]; [ Some true ] ]
    [ stored_answers n h1; stored_answers n h2 ]

(* DIG-554: a follow-up indexed before its item is decided when the item arrives. *)
let inbox_follow_up_decided_when_the_item_arrives () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let sg =
    Envelope.create ~key:pia.p_device ~seq:pia.p_seq ?prev:pia.p_prev
      ~created_at:(Time_fmt.now ()) ~epoch:(Node.fold n).epoch ~kind:"item"
      (Item.item_body ~to_:Circle ~keys:[] (question "Late item"))
  in
  let h = Envelope.hash sg.envelope in
  pia.p_seq <- pia.p_seq + 1;
  pia.p_prev <- Some h;
  ignore
    (peer_write n quinn "item_answer"
       (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
          ~voice:"person"));
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: undecided while the item is missing" [ None ] (stored_answers n h);
  ignore (ok (Node.import n sg));
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "2: decided once it is here" [ Some true ] (stored_answers n h)

(* DIG-554: a pick's result is stored with the deadline and the offered options, and a rule version
   bump decides every stored result again. *)
let inbox_follow_up_rule_version_recomputes () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let option id : Item.option_ = { id; label = id; recommended = false } in
  let deadline = Time_fmt.of_unix (Unix.gettimeofday () +. 3600.) in
  let h =
    peer_item n pia
      (question ~kind:"choice"
         ~options:[ option "a"; option "b" ]
         ~default:"b" ~deadline "Which?")
  in
  let pick o =
    ignore
      (peer_write n quinn "decision"
         (Item.pick_body ~item:h
            ~keys:[ (ok (Node.encryption_key n)).public ]
            ~option:o))
  in
  pick "a";
  pick "zzz";
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: an offered option counts, another does not" [ Some true; Some false ]
    (stored_picks n h);
  let l = n.Node.log in
  Log.exec l "UPDATE ui_item_picks SET counts = 0" [];
  Log.set_config l Api.Inbox.k_rule "0";
  keep_up n;
  Alcotest.(check (list (option bool)))
    "2: a new rule version decides again" [ Some true; Some false ]
    (stored_picks n h);
  Alcotest.(check (option string))
    "3: and is recorded" (Some Api.Inbox.rule_version)
    (Log.get_config l Api.Inbox.k_rule)

(* DIG-100: a result decided again acts as it would have on a node that had the revoke or the
   admission first: a pick on a choice and a close by a revoked key past its cutoff stop acting,
   and the New mark follows the follow-ups that count. *)
let inbox_follow_up_decided_again () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let lee = join_peer n "Lee Ver" in
  let lee2 = second_device n lee in
  let pia3 = second_device n pia in
  let ben = join_peer n "Ben Ode" in
  let ben2 = second_device n ben in
  let late_key = Crypto.generate_signing_key () in
  let admission, _ =
    peer_sign n ben2 "device"
      (Bodies.make_device ~identity:ben.p_identity ~key:(Keys.public late_key)
         ~role:Bodies.Device)
  in
  let late = { ben with p_device = late_key; p_seq = 1; p_prev = None } in
  let mine kind title =
    let it =
      if kind = "choice" then
        question ~kind
          ~options:
            [
              { Item.id = "yes"; label = "Yes"; recommended = false };
              { id = "no"; label = "No"; recommended = true };
            ]
          ~default:"no" title
      else question title
    in
    fst
      (ok (Node.write n ~kind:"item" (Item.item_body ~to_:Circle ~keys:[] it)))
  in
  let answer p h =
    ignore
      (peer_write n p "item_answer"
         (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text:"Thursday."
            ~voice:"person"))
  in
  let listed ?state id =
    List.exists
      (fun i -> s "id" i = id)
      (list
         (snd
            (call
               ("items?limit=200"
               ^ match state with Some st -> "&state=" ^ st | None -> ""))))
  in
  let status id = s "status" (snd (call ("items/" ^ id))) in
  let row h =
    Option.get (Store.Items.by_hash n.Node.log ~now:(Unix.gettimeofday ()) h)
  in
  (* Ada's own choice and question to the circle, and Pia's question, before anyone acts. *)
  let choice = mine "choice" "Dinner on Thursday?" in
  let asked = mine "question" "Who brings dessert?" in
  let waited = mine "question" "Who drives?" in
  let pias = peer_item n pia (question "Anyone free?") in
  let spare = peer_item n pia (question "Spare chairs?") in
  ignore (call "items");
  Alcotest.(check (list bool))
    "0: Ada's own items wait on others, out of her Inbox" [ true; true; false ]
    [
      listed ~state:"others" choice; listed ~state:"others" asked; listed choice;
    ];
  (* Lee's second device: the first write is inside the cutoff the revoke names, the rest past it. *)
  answer lee2 spare;
  ignore
    (peer_write n lee2 "decision"
       (Item.pick_body ~item:choice
          ~keys:[ (ok (Node.encryption_key n)).public ]
          ~option:"yes"));
  answer lee2 asked;
  ignore
    (peer_write n pia3 "item_close"
       (Item.close_body ~item:pias ~to_:Circle ~keys:[] ~closed:true
          ~voice:"person" ()));
  (* Ben's late device answers before its admission is here. *)
  answer late waited;
  ignore (call "items");
  Alcotest.(check (list (option bool)))
    "1: the pick past the cutoff counts before the revoke" [ Some true ]
    (stored_picks n choice);
  Alcotest.(check (list string))
    "1: and is new activity on Ada's choice and question" [ "new"; "new" ]
    [ status choice; status asked ];
  Alcotest.(check int)
    "1: Lee's pick is listed" 1
    (List.length (list (member "picks" (snd (call ("items/" ^ choice))))));
  Alcotest.(check bool)
    "1: Pia's question is closed" true (row pias).closed_flag;
  Alcotest.(check (list (option bool)))
    "1: the late device's answer waits on its admission" []
    (stored_answers n waited);
  ignore
    (peer_write n lee "revoke"
       (Bodies.make_revoke ~by:lee.p_identity
          ~target:(Keys.public lee2.p_device)
          ~after_seq:[ (Keys.public lee2.p_device, 1) ]
          ~mail_read:[]));
  ignore
    (peer_write n pia "revoke"
       (Bodies.make_revoke ~by:pia.p_identity
          ~target:(Keys.public pia3.p_device)
          ~after_seq:[ (Keys.public pia3.p_device, 0) ]
          ~mail_read:[]));
  keep_up n;
  (* a pick on a choice *)
  Alcotest.(check (list (option bool)))
    "2: the pick is decided again" [ Some false ] (stored_picks n choice);
  Alcotest.(check int)
    "2: and is no one's pick" 0
    (List.length (list (member "picks" (snd (call ("items/" ^ choice))))));
  Alcotest.(check (list bool))
    "2: the choice waits on others again, out of Ada's Inbox" [ true; false ]
    [ listed ~state:"others" choice; listed choice ];
  (* a close *)
  Alcotest.(check bool)
    "3: Pia's question is open again" false (row pias).closed_flag;
  Alcotest.(check bool)
    "3: and closes by the clock again" true
    ((row pias).closes_unix <> None);
  (* the New mark *)
  Alcotest.(check (list bool))
    "4: the question answered past the cutoff waits on others again"
    [ true; false ]
    [ listed ~state:"others" asked; listed asked ];
  ignore (ok (Node.import n admission));
  keep_up n;
  Alcotest.(check (list (option bool)))
    "5: the late device's answer counts once its admission is here"
    [ Some true ] (stored_answers n waited);
  Alcotest.(check (list bool))
    "5: and brings Ada's question back New" [ true; false ]
    [ listed waited; listed ~state:"others" waited ];
  Alcotest.(check string) "5: New" "new" (status waited)

(* DIG-556, DIG-100: the follow-up rule over generated items. [follow_up_cases] is a seeded list of
   items and follow-ups, then a fixed list of the cases a random draw rarely reaches ([gap_cases]),
   each with the result it should have, written by an oracle ([judge]) that states the rule from
   docs/protocol.md alone. The node test runs every node-side expression of the rule over the same
   cases and fails on any disagreement; the cases are also committed as follow_up_cases.json, which
   the phone's test (ui/src/lib/phone/follow-up-cases.test.ts) reads, with each reader's pick as the
   node made it under [picked]. *)
type gen_fu = {
  fu_kind : string;  (** answer or pick *)
  by : string;
      (** author; named; member; stranger (never admitted); leaver_in or
          leaver_out (a member's revoked device key, inside or past its cutoff);
          late (a second device of member, admitted after its follow-ups reached
          the log); own (the reader's own key: on the node its mail key, which
          the fold has not admitted) *)
  option : string;
  at : string;
  member : bool;
      (** by a reader, with the key in force, of an offered option before the
          deadline *)
  counts : bool;  (** member, and for an answer also in time (DIG-87) *)
}

(* DIG-87: a close or reopen of a question, by its author, by a revoked device key of the author
   inside or past its cutoff (author_in, author_out), or by another member (ignored). *)
type gen_close = {
  cl_by : string;  (** author, author_in, author_out or member *)
  cl_voice : string;  (** person or agent *)
  cl_closed : bool;
  cl_at : string;
  cl_counts : bool;  (** by the author's identity, with the key in force *)
}

type gen_case = {
  name : string;
  kind : string;
  circle : bool;
  asked : string;
  deadline : string option;
  options : string list;
  fus : gen_fu list;
  closes : gen_close list;
  lapses : bool;
      (** a question that closes by itself: no close of its author stands and no
          reader's answer was signed, in the Z form, inside the week *)
  closed : bool;  (** the author's close that stands closes it *)
  closes_at : string option;
      (** DIG-88: when it closes by the clock, with no close of its author
          standing: a question nobody but its author answered inside the week
          after it was asked, or after the author's reopen that stands; a choice
          at its deadline, and once reopened at the earlier of its deadline and
          a week after the reopen *)
  picked : (string * string) list;
      (** each reader's first pick that counts, by the reader's role: author,
          named, member, own or leaver *)
  answer_order : int list option;
      (** DIG-99: the answers a reader lists, in order, by index into [fus]; on
          a hand case alone, since a generated tie falls to the hash *)
  readable : bool;
      (** DIG-102: false for an item signed at a time not in the Z form, which
          no reader shows and whose follow-ups count for nothing *)
}

(* Whose a role's key is: follow-ups of one identity share a first pick. *)
let identity_of_role = function
  | "author" | "author_in" | "author_out" -> "author"
  | "member" | "late" -> "member"
  | "leaver_in" | "leaver_out" -> "leaver"
  | r -> r

let unix_of s = Option.get (Time_fmt.to_unix s)

(* The rule, from docs/protocol.md (Items: Answers, Picks, Closes). A follow-up counts as a
   reader's when the admission fold reads it from its author and its author is a reader; a pick also
   names an offered option and is signed before the deadline; a close is by the item's author. Of
   one reader's picks that count, the first in (signed time, hash) stands: of two at one signed
   time, the cases are written so that the one listed later has the smaller hash. The close that
   stands is the author's newest by the person, else the newest by their agent. A question stops
   taking answers at the close that stands when it closes, else, with no close standing, at its
   lapse when nobody but its author answered inside the week. *)
let judge ~name ~kind ~circle ~asked ~deadline ~options ~closes raw =
  let week = 7. *. 86_400. in
  let in_force by =
    not (List.mem by [ "stranger"; "leaver_out"; "author_out" ])
  in
  let fus =
    List.map
      (fun (fu_kind, by, option, at) ->
        let id = identity_of_role by in
        let reader = id = "author" || circle || id = "named" || id = "own" in
        let on_time =
          match deadline with None -> true | Some d -> unix_of at < unix_of d
        in
        let member =
          in_force by && reader
          && (fu_kind = "answer" || (List.mem option options && on_time))
        in
        { fu_kind; by; option; at; member; counts = member })
      raw
  in
  let closes =
    List.map
      (fun (cl_by, cl_voice, cl_closed, cl_at) ->
        {
          cl_by;
          cl_voice;
          cl_closed;
          cl_at;
          cl_counts = identity_of_role cl_by = "author" && in_force cl_by;
        })
      closes
  in
  let standing =
    let counted = List.filter (fun x -> x.cl_counts) closes in
    let newest l =
      List.fold_left
        (fun acc x ->
          match acc with
          | Some a when unix_of a.cl_at >= unix_of x.cl_at -> acc
          | _ -> Some x)
        None l
    in
    match newest (List.filter (fun x -> x.cl_voice = "person") counted) with
    | Some x -> Some x
    | None -> newest counted
  in
  let lapse = unix_of asked +. week in
  let answered_in_week =
    List.exists
      (fun f ->
        f.fu_kind = "answer" && f.member
        && identity_of_role f.by <> "author"
        && unix_of f.at < lapse)
      fus
  in
  (* DIG-88: a reopen that stands starts a new week; someone but the author answering inside it,
     at or after the reopen, keeps the question open. *)
  let reopen_answered x =
    let r = unix_of x.cl_at in
    List.exists
      (fun f ->
        f.fu_kind = "answer" && f.member
        && identity_of_role f.by <> "author"
        && unix_of f.at >= r
        && unix_of f.at < r +. week)
      fus
  in
  let in_time f =
    kind <> "question"
    ||
    match standing with
    | Some x when x.cl_closed -> unix_of f.at < unix_of x.cl_at
    | Some x -> reopen_answered x || unix_of f.at < unix_of x.cl_at +. week
    | None -> answered_in_week || unix_of f.at < lapse
  in
  let closes_at =
    match (standing, kind) with
    | Some x, _ when x.cl_closed -> None
    | Some x, "question" ->
        if reopen_answered x then None
        else Some (Time_fmt.of_unix (unix_of x.cl_at +. week))
    | Some x, "choice" ->
        let w = unix_of x.cl_at +. week in
        Some
          (Time_fmt.of_unix
             (match deadline with
             | Some d -> Float.min (unix_of d) w
             | None -> w))
    | None, "question" ->
        if answered_in_week then None else Some (Time_fmt.of_unix lapse)
    | None, "choice" -> deadline
    | _ -> None
  in
  let fus = List.map (fun f -> { f with counts = f.member && in_time f }) fus in
  let picked =
    if kind <> "choice" then []
    else
      List.mapi (fun i f -> (i, f)) fus
      |> List.filter (fun (_, f) -> f.fu_kind = "pick" && f.counts)
      |> List.sort (fun (i, f) (j, g) ->
          compare (unix_of f.at, -i) (unix_of g.at, -j))
      |> List.fold_left
           (fun acc (_, f) ->
             let id = identity_of_role f.by in
             if List.mem_assoc id acc then acc else acc @ [ (id, f.option) ])
           []
      |> List.sort compare
  in
  {
    name;
    kind;
    circle;
    asked;
    deadline;
    options;
    fus;
    closes;
    lapses = kind = "question" && closes_at <> None;
    closed = (match standing with Some x -> x.cl_closed | None -> false);
    closes_at;
    picked;
    answer_order = None;
    readable = true;
  }

(* DIG-100: the cases a random draw rarely reaches: two picks by one reader at one signed time, a
   signer admitted after its follow-ups reached the log, the reader's own key, a close by a revoked
   key of the author inside and past its cutoff, an answer at a close, a millisecond before and
   after, and an answer at a revoked key's cutoff. Each is (title, kind, to the circle, deadline
   after it was asked, follow-ups as (kind, by, option, seconds after it was asked), closes as (by,
   closes, seconds after it was asked), all by the person). *)
let gap_cases =
  let h = 3600. and d = 86_400. and ms = 0.001 in
  let pick by o t = ("pick", by, o, t) in
  let answer by t = ("answer", by, "", t) in
  let close ?(closed = true) by t = (by, closed, t) in
  [
    ( "tie: own picks, the later one listed stands",
      "choice",
      true,
      None,
      [ pick "own" "yes" h; pick "own" "no" h ],
      [] );
    ( "tie: own picks listed the other way, after one that does not count",
      "choice",
      true,
      None,
      [ pick "own" "zzz" (h /. 2.); pick "own" "no" h; pick "own" "yes" h ],
      [] );
    ( "tie: picks by two readers of a named choice",
      "choice",
      false,
      Some (3. *. d),
      [
        pick "named" "yes" (2. *. d);
        pick "own" "no" (2. *. d);
        pick "named" "no" (2. *. d);
        pick "own" "yes" (2. *. d);
      ],
      [] );
    ( "tie: of two picks at one time only one counts",
      "choice",
      true,
      Some (3. *. d),
      [ pick "own" "yes" h; pick "own" "zzz" h; pick "member" "no" h ],
      [] );
    ( "tie: two picks at the deadline count for nothing",
      "choice",
      true,
      Some (3. *. d),
      [
        pick "own" "yes" (3. *. d);
        pick "own" "no" (3. *. d);
        pick "own" "no" (4. *. d);
      ],
      [] );
    ( "late: an answer by a device admitted after it",
      "question",
      true,
      None,
      [ answer "late" h; answer "member" (2. *. h) ],
      [] );
    ( "late: a pick by a device admitted after it",
      "choice",
      true,
      None,
      [ pick "late" "yes" h; pick "member" "no" (2. *. h); pick "own" "no" h ],
      [] );
    ( "late: on a named question it does not read",
      "question",
      false,
      None,
      [ answer "late" h; answer "named" (2. *. h) ],
      [] );
    ( "own: answers on a circle question",
      "question",
      true,
      None,
      [ answer "own" h; answer "author" (2. *. h) ],
      [] );
    ( "own: answers on a named question",
      "question",
      false,
      None,
      [ answer "own" h; answer "stranger" (2. *. h); answer "member" (3. *. h) ],
      [] );
    ( "own: picks on a named choice",
      "choice",
      false,
      None,
      [
        pick "own" "yes" (2. *. h);
        pick "named" "no" h;
        pick "own" "no" (3. *. h);
      ],
      [] );
    ( "revoked close: inside its cutoff it stands",
      "question",
      true,
      None,
      [ answer "member" (12. *. h); answer "member" (2. *. d) ],
      [ close "author_in" d ] );
    ( "revoked close: past its cutoff it stands for nothing",
      "question",
      true,
      None,
      [ answer "member" (2. *. d) ],
      [ close "author_out" d ] );
    ( "revoked close: past its cutoff on an unanswered named question",
      "question",
      false,
      None,
      [ answer "author" (2. *. d) ],
      [ close "author_out" d ] );
    ( "revoked close: a reopen past its cutoff leaves the close inside it",
      "question",
      true,
      None,
      [ answer "member" (3. *. d) ],
      [ close "author_in" d; close ~closed:false "author_out" (2. *. d) ] );
    ( "revoked close: a reopen inside its cutoff after a close past it",
      "question",
      false,
      None,
      [ answer "named" (3. *. d) ],
      [ close "author_out" d; close ~closed:false "author_in" (2. *. d) ] );
    ( "close boundary: on a circle question",
      "question",
      true,
      None,
      [
        answer "member" ((2. *. d) -. ms);
        answer "own" (2. *. d);
        answer "member" ((2. *. d) +. ms);
      ],
      [ close "author" (2. *. d) ] );
    ( "close boundary: on a named question",
      "question",
      false,
      None,
      [
        answer "named" ((2. *. d) +. ms);
        answer "own" ((2. *. d) -. ms);
        answer "named" (2. *. d);
      ],
      [ close "author" (2. *. d) ] );
    ( "close boundary: a reopen takes answers again",
      "question",
      true,
      None,
      [ answer "member" (d +. ms) ],
      [ close "author" d; close ~closed:false "author" (d +. h) ] );
    ( "close boundary: a close by a member is not the author's",
      "question",
      true,
      None,
      [ answer "member" (2. *. d) ],
      [ close "member" d ] );
    (* DIG-88: a reopen starts a new week, and a choice keeps its deadline. *)
    ( "reopen: a reopened question lapses a week after the reopen",
      "question",
      true,
      None,
      [
        answer "member" (d +. h);
        answer "author" (3. *. d);
        answer "member" (9. *. d);
      ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    ( "reopen: an answer a millisecond inside the new week keeps it open",
      "question",
      true,
      None,
      [ answer "member" ((9. *. d) -. ms); answer "member" (30. *. d) ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    ( "reopen: an answer inside the new week keeps it open",
      "question",
      false,
      None,
      [ answer "named" (8. *. d); answer "named" (20. *. d) ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    ( "reopen: a lapsed question reopened lapses again",
      "question",
      true,
      None,
      [ answer "member" (8. *. d); answer "member" (17. *. d) ],
      [ close ~closed:false "author" (10. *. d) ] );
    ( "reopen: a reopened choice closes at its deadline when it comes first",
      "choice",
      true,
      Some (3. *. d),
      [ pick "own" "yes" (2. *. d); pick "member" "no" (4. *. d) ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    ( "reopen: a reopened choice closes a week after the reopen when that \
       comes first",
      "choice",
      false,
      Some (20. *. d),
      [ pick "own" "yes" (3. *. d) ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    ( "reopen: a reopened choice with no deadline closes a week after the reopen",
      "choice",
      true,
      None,
      [ pick "own" "no" (3. *. d) ],
      [ close "author" d; close ~closed:false "author" (2. *. d) ] );
    (* Last, so that on the phone its answer inside the cutoff is the one at it. *)
    ( "leaver: an answer at its key's cutoff and one past it",
      "question",
      true,
      None,
      [ answer "leaver_in" h; answer "leaver_out" (2. *. h) ],
      [] );
  ]

(* DIG-99: one case per way a follow-up signed at a time not in the Z form (Encoding, Times) read
   differently on the node and the phone. Each counts for nothing on both and is still kept; an
   answer and a close are still listed. Their results are written by hand, since [judge] reads only
   Z-form times. Each is (title, kind, deadline after it was asked, lapses, closed, picked, answer
   order, and its follow-ups and closes from [z s], the Z-form time [s] seconds after it was asked,
   and [other tail s], that second with [tail] in place of the Z form's fraction and zone). *)
let hand_cases =
  let h = 3600. and d = 86_400. in
  let pick option at counts =
    { fu_kind = "pick"; by = "own"; option; at; member = counts; counts }
  in
  let answer ?(by = "member") at counts =
    { fu_kind = "answer"; by; option = ""; at; member = true; counts }
  in
  let close ?(closed = true) cl_at =
    {
      cl_by = "author";
      cl_voice = "person";
      cl_closed = closed;
      cl_at;
      cl_counts = true;
    }
  in
  [
    (* The node read the offset as 0.0 and took that pick first; the phone read its real time. *)
    ( "a pick at an offset is no pick",
      "choice",
      None,
      false,
      false,
      [ ("own", "no") ],
      None,
      fun z other ->
        ( [ pick "yes" (other "+00:00" d) false; pick "no" (z (8. *. h)) true ],
          [] ) );
    (* pick_counts had no Z check: a zone-less pick counted before the deadline on the node. *)
    ( "a zone-less pick before the deadline is no pick",
      "choice",
      Some (3. *. d),
      false,
      false,
      [],
      None,
      fun _ other -> ([ pick "yes" (other "" d) false ], []) );
    (* Second 60 and the 31st of February: NaN or another day on the phone, a normalized time on
       the node. *)
    ( "a time the phone cannot parse is no pick",
      "choice",
      Some (3. *. d),
      false,
      false,
      [],
      None,
      fun _ _ ->
        ( [
            pick "yes" "2026-11-02T10:00:60Z" false;
            pick "no" "2026-02-31T10:00:00Z" false;
          ],
          [] ) );
    (* Four fraction digits: the node kept them, the phone cut them to the millisecond. *)
    ( "a pick with four fraction digits is no pick",
      "choice",
      None,
      false,
      false,
      [ ("own", "no") ],
      None,
      fun z other ->
        ( [ pick "yes" (other ".9996Z" (d -. 1.)) false; pick "no" (z d) true ],
          [] ) );
    (* SQL read the answer's real time and found it inside the week; OCaml read 0.0. *)
    ( "an answer at an offset is listed and counts for nothing",
      "question",
      None,
      true,
      false,
      [],
      None,
      fun _ other -> ([ answer (other "+00:00" d) false ], []) );
    (* OCaml put the close at 0.0, so the answer was late; SQL and the phone read its real time. *)
    ( "a close at an offset closes nothing",
      "question",
      None,
      false,
      false,
      [],
      None,
      fun z other ->
        ([ answer (z h) true ], [ close (other "+00:00" (2. *. h)) ]) );
    (* A zone-less reopen sorted after the close as bytes and stood. *)
    ( "a zone-less reopen opens nothing",
      "question",
      None,
      false,
      true,
      [],
      None,
      fun z other ->
        ( [ answer (z h) true; answer (z (4. *. h)) false ],
          [ close (z (2. *. h)); close ~closed:false (other "" (3. *. h)) ] ) );
    (* Answers are listed in signed time, then any not in the Z form, as bytes: not localeCompare
       and not byte order of the times. *)
    ( "answers are listed in the follow-up order",
      "question",
      None,
      false,
      false,
      [],
      Some [ 1; 0; 2 ],
      fun _ other ->
        ( [
            answer (other ".5Z" h) true;
            answer ~by:"author" (other "Z" h) true;
            answer (other "+00:00" (h -. 60.)) false;
          ],
          [] ) );
  ]

(* DIG-102: items signed at a time not in the Z form, which neither the node nor the phone reads, so
   that no follow-up on them counts: the node read the offset as 0.0, its question lapsing in 1970
   and every answer late; the phone read it with Date.parse. Each is (title, kind, the tail in
   place of the Z form's fraction and zone of the time it is signed at, its follow-ups and closes
   given [z s], s seconds after that time in the Z form), and would count them were it readable. *)
let unreadable_cases =
  let h = 3600. in
  [
    ( "an item signed at an offset is unreadable",
      "question",
      "+00:00",
      fun z ->
        ( [
            {
              fu_kind = "answer";
              by = "member";
              option = "";
              at = z h;
              member = false;
              counts = false;
            };
          ],
          [
            {
              cl_by = "author";
              cl_voice = "person";
              cl_closed = true;
              cl_at = z (2. *. h);
              cl_counts = false;
            };
          ] ) );
    ( "a zone-less item is unreadable",
      "choice",
      "",
      fun z ->
        ( [
            {
              fu_kind = "pick";
              by = "own";
              option = "yes";
              at = z h;
              member = false;
              counts = false;
            };
          ],
          [] ) );
  ]

(* Every time a case signs is in the Z form: the generated and gap cases, not the hand cases. *)
let in_z_form (c : gen_case) =
  Time_fmt.is_z c.asked
  && List.for_all (fun f -> Time_fmt.is_z f.at) c.fus
  && List.for_all (fun x -> Time_fmt.is_z x.cl_at) c.closes

(* DIG-106: [at], a time as Time_fmt.of_unix writes it (three fraction digits), in the Z form with
   [n] fraction digits, never fewer than its value needs: "00.500Z" as "00.5Z" or "00.50Z", and
   "00.000Z" as "00Z" too. *)
let z_form n at =
  let ms = String.sub at 20 3 in
  let need =
    if ms = "000" then 0
    else if String.sub ms 1 2 = "00" then 1
    else if ms.[2] = '0' then 2
    else 3
  in
  let n = max n need in
  String.sub at 0 19 ^ (if n = 0 then "" else "." ^ String.sub ms 0 n) ^ "Z"

let follow_up_cases () =
  let rng = Random.State.make [| 556 |] in
  (* DIG-106: answers and closes are signed in every fraction form the Z form allows, drawn from
     their own stream so the cases themselves stay as the seed made them. Readers that order by the
     text of a time instead of its value then disagree with the oracle, which reads the value. *)
  let forms = Random.State.make [| 106 |] in
  let mixed at = z_form (Random.State.int forms 4) at in
  let mix_fus =
    List.map (fun (k, by, o, at) ->
        (k, by, o, if k = "answer" then mixed at else at))
  in
  let choose l = List.nth l (Random.State.int rng (List.length l)) in
  let t0 = unix_of "2026-11-01T00:00:00.000Z" in
  let week = 7. *. 86_400. in
  let to_name circle = if circle then "the circle" else "named members" in
  let random =
    List.init 52 (fun i ->
        let kind = if i mod 2 = 0 then "question" else "choice" in
        let circle = i / 2 mod 2 = 0 in
        let asked = Time_fmt.of_unix (t0 +. (float_of_int i *. 60.)) in
        let deadline =
          if kind = "choice" && Random.State.int rng 4 > 0 then
            Some (Time_fmt.of_unix (unix_of asked +. (3. *. 86_400.)))
          else None
        in
        let options = if kind = "choice" then [ "yes"; "no" ] else [] in
        let roles =
          if circle then
            [
              "author";
              "member";
              "stranger";
              "leaver_in";
              "leaver_out";
              "late";
              "own";
            ]
          else [ "author"; "named"; "member"; "stranger"; "late"; "own" ]
        in
        (* One identity's follow-ups never share a signed time here; the ties are gap_cases'. *)
        let rec fus n used =
          if n = 0 then []
          else
            let fu_kind = if kind = "question" then "answer" else "pick" in
            let by = choose roles in
            let option = choose [ "yes"; "no"; "zzz" ] in
            let base, offsets =
              match (fu_kind, deadline) with
              | "answer", _ ->
                  ( unix_of asked,
                    [
                      3600.;
                      2. *. 86_400.;
                      5. *. 86_400.;
                      week -. 0.001;
                      week;
                      week +. (2. *. 86_400.);
                    ] )
              | _, Some d -> (unix_of d, [ -3600.; -0.001; 0.; 0.001; 3600. ])
              | _, None -> (unix_of asked, [ 3600.; 86_400. ])
            in
            let at = Time_fmt.of_unix (base +. choose offsets) in
            let key = (identity_of_role by, at) in
            if List.mem key used then fus n used
            else (fu_kind, by, option, at) :: fus (n - 1) (key :: used)
        in
        let fus = fus (1 + Random.State.int rng 4) [] in
        (* Closes and reopens of a question, at distinct times, some by a member who is not its
           author (they stand for nothing). Half the questions have none. *)
        let rec closes n used =
          if n = 0 then []
          else
            let at =
              Time_fmt.of_unix
                (unix_of asked
                +. choose
                     [
                       1800.;
                       86_400.;
                       4. *. 86_400.;
                       week +. 3600.;
                       9. *. 86_400.;
                     ])
            in
            if List.mem at used then closes n used
            else
              let by = choose [ "author"; "author"; "member" ] in
              let voice = choose [ "person"; "agent" ] in
              let closed = Random.State.int rng 3 > 0 in
              (by, voice, closed, at) :: closes (n - 1) (at :: used)
        in
        let closes =
          if kind = "question" && Random.State.bool rng then
            closes (1 + Random.State.int rng 3) []
          else []
        in
        (* The last two questions are fixed, so the two rules the random closes seldom reach are
           decided in them. Case 48: the author closed, then reopened half a second later in the
           same second, and an answer between the two is late under the close alone and counts
           because of the reopen; each is written with the fewest fraction digits, so as text the
           close ("00Z") sorts after the reopen ("00.5Z") (DIG-106). Case 50: the
           person's reopen stands over the agent's newer close, so the answer counts as the
           person's close says and not as the agent's would. *)
        let fixed = i >= 48 && kind = "question" in
        let after s = Time_fmt.of_unix (unix_of asked +. s) in
        let fus =
          if i = 48 && kind = "question" then
            [
              ( "answer",
                (if circle then "member" else "named"),
                "yes",
                z_form 0 (after (86_400. +. 0.25)) );
            ]
          else if fixed then
            [
              ( "answer",
                (if circle then "member" else "named"),
                "yes",
                after (2. *. 86_400.) );
            ]
          else mix_fus fus
        in
        let closes =
          if not fixed then
            List.map (fun (by, v, c, at) -> (by, v, c, mixed at)) closes
          else if i = 48 then
            [
              ("author", "person", true, z_form 0 (after 86_400.));
              ("author", "person", false, z_form 0 (after (86_400. +. 0.5)));
            ]
          else
            [
              ("author", "person", false, after 1800.);
              ("author", "agent", true, after 86_400.);
            ]
        in
        judge
          ~name:(Printf.sprintf "case %02d: %s to %s" i kind (to_name circle))
          ~kind ~circle ~asked ~deadline ~options ~closes fus)
  in
  let gaps =
    List.mapi
      (fun j (title, kind, circle, deadline, raw, closes) ->
        let i = 52 + j in
        let asked = t0 +. (float_of_int i *. 60.) in
        let at s = Time_fmt.of_unix (asked +. s) in
        judge
          ~name:
            (Printf.sprintf "case %02d: %s to %s, %s" i kind (to_name circle)
               title)
          ~kind ~circle ~asked:(at 0.) ~deadline:(Option.map at deadline)
          ~options:(if kind = "choice" then [ "yes"; "no" ] else [])
          ~closes:
            (List.map
               (fun (by, c, s) -> (by, "person", c, mixed (at s)))
               closes)
          (mix_fus (List.map (fun (k, by, o, s) -> (k, by, o, at s)) raw)))
      gap_cases
  in
  let hands =
    List.mapi
      (fun j (title, kind, deadline, lapses, closed, picked, answer_order, f) ->
        let i = 52 + List.length gap_cases + j in
        let asked = t0 +. (float_of_int i *. 60.) in
        let z s = Time_fmt.of_unix (asked +. s) in
        let other tail s =
          let t = z s in
          String.sub t 0 (String.length t - 5) ^ tail
        in
        let fus, closes = f z other in
        {
          name = Printf.sprintf "case %02d: %s to the circle, %s" i kind title;
          kind;
          circle = true;
          asked = z 0.;
          deadline = Option.map z deadline;
          options = (if kind = "choice" then [ "yes"; "no" ] else []);
          fus;
          closes;
          lapses;
          closed;
          (* No hand case reopens: it closes by the clock at a choice's deadline or a question's
             lapse. *)
          closes_at =
            (if closed then None
             else if kind = "choice" then Option.map z deadline
             else if lapses then Some (z (7. *. 86_400.))
             else None);
          picked;
          answer_order;
          readable = true;
        })
      hand_cases
  in
  let unreadable =
    List.mapi
      (fun j (title, kind, tail, f) ->
        let i = 52 + List.length gap_cases + List.length hand_cases + j in
        let asked = t0 +. (float_of_int i *. 60.) in
        let z s = Time_fmt.of_unix (asked +. s) in
        let a = z 0. in
        let fus, closes = f z in
        {
          name = Printf.sprintf "case %02d: %s to the circle, %s" i kind title;
          kind;
          circle = true;
          asked = String.sub a 0 (String.length a - 5) ^ tail;
          deadline = None;
          options = (if kind = "choice" then [ "yes"; "no" ] else []);
          fus;
          closes;
          lapses = false;
          closed = false;
          closes_at = None;
          picked = [];
          answer_order = None;
          readable = false;
        })
      unreadable_cases
  in
  random @ gaps @ hands @ unreadable

let follow_up_fixture cases =
  let str s = `String s in
  let opt = function Some s -> str s | None -> `Null in
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("seed", `Int 556);
         ( "cases",
           `List
             (List.map
                (fun c ->
                  `Assoc
                    [
                      ("name", str c.name);
                      ("kind", str c.kind);
                      ("to", str (if c.circle then "circle" else "named"));
                      ("asked", str c.asked);
                      ("deadline", opt c.deadline);
                      ("options", `List (List.map str c.options));
                      ( "follow_ups",
                        `List
                          (List.map
                             (fun f ->
                               `Assoc
                                 [
                                   ("kind", str f.fu_kind);
                                   ("by", str f.by);
                                   ("option", str f.option);
                                   ("at", str f.at);
                                   ("member", `Bool f.member);
                                   ("counts", `Bool f.counts);
                                 ])
                             c.fus) );
                      ( "closes",
                        `List
                          (List.map
                             (fun x ->
                               `Assoc
                                 [
                                   ("by", str x.cl_by);
                                   ("voice", str x.cl_voice);
                                   ("closed", `Bool x.cl_closed);
                                   ("at", str x.cl_at);
                                   ("counts", `Bool x.cl_counts);
                                 ])
                             c.closes) );
                      ("lapses", `Bool c.lapses);
                      ("closed", `Bool c.closed);
                      ("closes_at", opt c.closes_at);
                      ( "picked",
                        `Assoc (List.map (fun (r, o) -> (r, str o)) c.picked) );
                      ( "answer_order",
                        match c.answer_order with
                        | None -> `Null
                        | Some l -> `List (List.map (fun i -> `Int i) l) );
                      ("readable", `Bool c.readable);
                    ])
                cases) );
       ])
  ^ "\n"

(* Every node-side expression of the rule over the generated cases, in a random arrival order with
   index passes between: the stored column, the SQL fragments of the Inbox, Api.Inbox.answers,
   counted_answers, picks and closes, a fresh run of the OCaml decision, whether the question
   lapses, and each reader's first pick, which the fixture records as the node's. *)
let follow_up_agreement () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let cases = follow_up_cases () in
  let rng = Random.State.make [| 5560 |] in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let ben = join_peer n "Ben Ode" in
  let leaver = join_peer n "Lee Ver" in
  let leaver2 = second_device n leaver in
  let pia3 = second_device n pia in
  (* [late]: a device of Ben, admitted by a second device of his whose admission envelope reaches
     the log only after every follow-up [late] signed was indexed. *)
  let ben2 = second_device n ben in
  let late_key = Crypto.generate_signing_key () in
  let late_admission, _ =
    peer_sign n ben2 "device"
      (Bodies.make_device ~identity:ben.p_identity ~key:(Keys.public late_key)
         ~role:Bodies.Device)
  in
  let late = { ben with p_device = late_key; p_seq = 1; p_prev = None } in
  let stranger =
    {
      ben with
      p_identity = Crypto.generate_signing_key ();
      p_device = Crypto.generate_signing_key ();
      p_seq = 1;
      p_prev = None;
    }
  in
  let me = Option.get (Log.get_config n.Node.log Node.k_identity) in
  let my_key =
    raw_key (Keys.encryption_public (Result.get_ok (Node.encryption_key n)))
  in
  (* [own]: this node's mail key, which the fold has not admitted, so is_reader reads it by
     Node.own_keys. *)
  let mail = Result.get_ok (Node.mail_key n) in
  Alcotest.(check bool)
    "the node's mail key is not admitted" true
    (Fold.find (Node.fold n) (Keys.public mail) = None);
  let mail_seq = ref 0 in
  let id p = Keys.public p.p_identity in
  let named = [ me; id quinn ] in
  let persons =
    [
      ("author", pia);
      ("named", quinn);
      ("member", ben);
      ("stranger", stranger);
      ("leaver_in", leaver2);
      ("leaver_out", leaver2);
      ("late", late);
      ("author_in", pia3);
      ("author_out", pia3);
    ]
  in
  let role_of_identity =
    [
      (id pia, "author");
      (id quinn, "named");
      (id ben, "member");
      (me, "own");
      (id leaver, "leaver");
    ]
  in
  let named_keys = [ my_key; pia.p_enc.public; quinn.p_enc.public ] in
  (* Every third item is signed by a second device of its author and imported late, after the
     revoke: its follow-ups reach the index before it does. *)
  let pia2 = second_device n pia in
  let pending = ref [] in
  let hash_of_item =
    List.mapi
      (fun idx (cs : gen_case) ->
        let options =
          List.map
            (fun id : Item.option_ -> { id; label = id; recommended = false })
            cs.options
        in
        let it =
          question ~kind:cs.kind ~options
            ?default:(if cs.kind = "choice" then Some "no" else None)
            ?deadline:cs.deadline cs.name
        in
        let to_ =
          if cs.circle then `Circle
          else `Members (named, [ my_key; quinn.p_enc.public ])
        in
        let body = peer_item_body pia ~to_ it in
        if idx mod 3 = 0 then (
          let sg, h = peer_sign n pia2 ~created_at:cs.asked "item" body in
          pending := sg :: !pending;
          (cs.name, h))
        else (cs.name, peer_write n pia ~created_at:cs.asked "item" body))
      cases
  in
  let writes =
    List.concat_map
      (fun (cs : gen_case) ->
        List.mapi (fun i (f : gen_fu) -> (cs, i, f)) cs.fus)
      cases
  in
  let shuffle l =
    List.map snd
      (List.sort compare (List.map (fun x -> (Random.State.bits rng, x)) l))
  in
  (* Every write inside a cutoff comes before every write past it, as a cutoff is a seq; every
     write by [late] is indexed before its admission arrives. *)
  let first, rest =
    List.partition
      (fun (_, _, (f : gen_fu)) ->
        f.by = "leaver_in" || f.by = "late"
        || (f.by <> "leaver_out" && Random.State.bool rng))
      writes
  in
  (* Some writes past the cutoff reach the index before the revoke does, in a pass of their own, and
     are decided as counting; the revoke then changes that. *)
  let early_out, rest =
    List.partition
      (fun (_, _, (f : gen_fu)) -> f.by = "leaver_out" && Random.State.bool rng)
      rest
  in
  let hashes = Hashtbl.create 64 in
  let close_hashes = Hashtbl.create 64 in
  (* The closes, written in two passes so they too arrive in mixed order: every close inside the
     author's revoked key's cutoff in the first, before any past it. *)
  let close_writes =
    List.concat_map
      (fun (cs : gen_case) -> List.mapi (fun i x -> (cs, i, x)) cs.closes)
      cases
  in
  let write_close ((cs : gen_case), i, (x : gen_close)) =
    let item = List.assoc cs.name hash_of_item in
    let p = List.assoc x.cl_by persons in
    let to_ = if cs.circle then Item.Circle else Item.Members named in
    let keys = if cs.circle then [] else named_keys in
    Hashtbl.replace close_hashes (cs.name, i)
      (peer_write n p ~created_at:x.cl_at "item_close"
         (Item.close_body ~item ~to_ ~keys ~closed:x.cl_closed ~voice:x.cl_voice
            ()))
  in
  (* Of two picks by one reader at one signed time, the one listed later is written with the
     smaller hash (judge): a pick's body is sealed afresh until its hash falls on that side. *)
  let tie_wanted (cs : gen_case) i (f : gen_fu) =
    List.concat
      (List.mapi
         (fun j (g : gen_fu) ->
           if
             j <> i && g.fu_kind = "pick" && f.fu_kind = "pick" && g.at = f.at
             && identity_of_role g.by = identity_of_role f.by
           then
             match Hashtbl.find_opt hashes (cs.name, j) with
             | Some hj -> [ (fun h -> if i > j then h < hj else h > hj) ]
             | None -> []
           else [])
         cs.fus)
  in
  let write (cs, i, (f : gen_fu)) =
    let item = List.assoc cs.name hash_of_item in
    let to_ = if cs.circle then Item.Circle else Item.Members named in
    let keys = if cs.circle then [] else named_keys in
    let body () =
      if f.fu_kind = "answer" then
        ( "item_answer",
          Item.answer_body ~item ~to_ ~keys ~text:"Thursday." ~voice:"person" )
      else
        ( "decision",
          Item.pick_body ~item
            ~keys:[ (ok (Node.encryption_key n)).public; pia.p_enc.public ]
            ~option:f.option )
    in
    let wanted = tie_wanted cs i f in
    let rec sign () =
      let kind, b = body () in
      let sg, h, commit =
        if f.by = "own" then
          let sg =
            Envelope.create ~key:mail ~seq:(!mail_seq + 1) ~prev:item
              ~created_at:f.at ~epoch:(Node.fold n).epoch ~kind b
          in
          (sg, Envelope.hash sg.envelope, fun () -> incr mail_seq)
        else
          let p = List.assoc f.by persons in
          let seq, prev = (p.p_seq, p.p_prev) in
          let sg, h = peer_sign n p ~created_at:f.at kind b in
          p.p_seq <- seq;
          p.p_prev <- prev;
          ( sg,
            h,
            fun () ->
              p.p_seq <- seq + 1;
              p.p_prev <- Some h )
      in
      if List.for_all (fun ok -> ok h) wanted then (
        commit ();
        ignore (ok (Node.import n sg));
        h)
      else sign ()
    in
    Hashtbl.replace hashes (cs.name, i) (sign ());
    if Random.State.int rng 4 = 0 then ignore (call "items")
  in
  List.iter write (shuffle first);
  let close_first, close_rest =
    List.partition
      (fun (_, _, x) -> x.cl_by = "author_in" || Random.State.bool rng)
      close_writes
  in
  let inside_first =
    List.stable_sort (fun (_, _, x) (_, _, y) ->
        compare (x.cl_by <> "author_in") (y.cl_by <> "author_in"))
  in
  List.iter write_close (inside_first close_first);
  let count p =
    List.length (List.filter (fun (_, _, (f : gen_fu)) -> f.by = p) writes)
  and count_closes p =
    List.length (List.filter (fun (_, _, x) -> x.cl_by = p) close_writes)
  in
  ignore (call "items");
  Alcotest.(check bool)
    "some writes past the cutoff are decided before the revoke" true
    (early_out <> []);
  List.iter write (shuffle early_out);
  ignore (call "items");
  let revoke by target cutoff =
    ignore
      (peer_write n by "revoke"
         (Bodies.make_revoke ~by:by.p_identity
            ~target:(Keys.public target.p_device)
            ~after_seq:[ (Keys.public target.p_device, cutoff) ]
            ~mail_read:[]))
  in
  revoke leaver leaver2 (count "leaver_in");
  revoke pia pia3 (count_closes "author_in");
  let rest = shuffle rest in
  let half = List.length rest / 2 in
  List.iteri (fun i w -> if i < half then write w) rest;
  List.iter (fun sg -> ignore (ok (Node.import n sg))) (List.rev !pending);
  ignore (ok (Node.import n late_admission));
  ignore (call "items");
  keep_up n;
  List.iter write_close close_rest;
  ignore (call "items");
  List.iteri (fun i w -> if i >= half then write w) rest;
  ignore (call "items");
  let ctx = Api.ctx_of n in
  let log = n.Node.log in
  let module I = Store.Items in
  let in_sql cs where who =
    I.select log ~now:ctx.now
      ("WHERE hash = ?2 AND " ^ where who)
      [ Log.s (List.assoc cs.name hash_of_item) ]
    <> []
  in
  (* DIG-87: the SQL reading of whether one answer is in time, over its item's row. *)
  let in_time_sql h =
    Log.rows log
      ("SELECT 1 FROM ui_item_answers a JOIN ui_items r ON r.hash = a.item \
        WHERE a.hash = ? AND a.counts = 1 AND " ^ I.answer_in_time)
      [ Log.s h ]
    <> []
  in
  let node_picked = Hashtbl.create 64 in
  (* DIG-102: an unreadable item is in no reader's list, and nothing on it counts. *)
  List.iter
    (fun (cs : gen_case) ->
      let item = List.assoc cs.name hash_of_item in
      Alcotest.(check bool)
        (cs.name ^ ": not shown") true
        (I.by_hash log ~now:ctx.now item = None);
      Alcotest.(check bool)
        (cs.name ^ ": not in the Inbox list")
        false
        (List.exists
           (fun j -> s "id" j = item)
           (list (snd (call "items?limit=200"))));
      Alcotest.(check int)
        (cs.name ^ ": no follow-up counts")
        0
        (List.length
           (List.filter
              (fun (a : I.answer) -> a.a_counts = Some true)
              (I.answers log item))
        + List.length
            (List.filter
               (fun (p : I.pick) -> p.p_counts = Some true)
               (I.picks log item))
        + List.length
            (List.filter
               (fun (x : I.close) -> x.c_counts = Some true)
               (I.closes log item)));
      Hashtbl.replace node_picked cs.name [])
    (List.filter (fun (c : gen_case) -> not c.readable) cases);
  List.iter
    (fun (cs : gen_case) ->
      let item = List.assoc cs.name hash_of_item in
      let r = Option.get (I.by_hash log ~now:ctx.now item) in
      let check what got want =
        Alcotest.(check bool) (cs.name ^ ": " ^ what) want got
      in
      let stored_a = I.answers log item
      and stored_p = I.picks log item
      and stored_c = I.closes log item in
      let counted_answers = Api.Inbox.counted_answers ctx r in
      List.iteri
        (fun i (f : gen_fu) ->
          let h = Hashtbl.find hashes (cs.name, i) in
          let tag =
            Printf.sprintf "follow-up %d (%s by %s at %s)" i f.fu_kind f.by f.at
          in
          let e = Option.get (Log.find log h) in
          if f.fu_kind = "answer" then (
            check (tag ^ " in time (SQL)") (in_time_sql h) f.counts;
            match
              List.find_opt (fun (a : I.answer) -> a.a_hash = h) stored_a
            with
            | Some a ->
                check (tag ^ " stored") (a.a_counts = Some true) f.member;
                check (tag ^ " decision")
                  (Api.Inbox.answer_counts ctx r e a)
                  f.member
            | None -> check (tag ^ " not stored") false f.member)
          else
            match List.find_opt (fun (p : I.pick) -> p.p_hash = h) stored_p with
            | Some p ->
                check (tag ^ " stored") (p.p_counts = Some true) f.member;
                check (tag ^ " decision")
                  (Api.Inbox.pick_counts ctx r e p)
                  f.member
            | None -> check (tag ^ " not stored") false f.member)
        cs.fus;
      List.iteri
        (fun i (x : gen_close) ->
          let h = Hashtbl.find close_hashes (cs.name, i) in
          let tag = Printf.sprintf "close %d (by %s at %s)" i x.cl_by x.cl_at in
          let e = Option.get (Log.find log h) in
          match List.find_opt (fun (y : I.close) -> y.c_hash = h) stored_c with
          | Some y ->
              check (tag ^ " stored") (y.c_counts = Some true) x.cl_counts;
              check (tag ^ " decision")
                (Api.Inbox.close_counts ctx r e y)
                x.cl_counts
          | None -> check (tag ^ " not stored") false x.cl_counts)
        cs.closes;
      let counted = List.filter (fun (f : gen_fu) -> f.counts) cs.fus in
      let members = List.filter (fun (f : gen_fu) -> f.member) cs.fus in
      let others =
        List.filter
          (fun (f : gen_fu) -> identity_of_role f.by <> "author")
          counted
      in
      check "SQL: any counted follow-up"
        (in_sql cs I.acted_by (fun _ -> "1 = 1"))
        (counted <> []);
      check "SQL: one by someone else"
        (in_sql cs I.acted_by I.not_author)
        (others <> []);
      let listed_hashes =
        if cs.kind = "question" then
          List.map (fun (a : I.answer) -> a.a_hash) counted_answers
        else List.map (fun (p : I.pick) -> p.p_hash) (Api.Inbox.picks ctx r)
      in
      if cs.kind = "question" then (
        (* The reader's rows are membership alone, the late ones among them (DIG-87). *)
        Alcotest.(check int)
          (cs.name ^ ": Api.Inbox.answers is membership")
          (List.length members)
          (List.length (Api.Inbox.answers ctx r));
        let want =
          List.sort compare
            (List.filter_map
               (fun (i, (f : gen_fu)) ->
                 if f.counts then Some (Hashtbl.find hashes (cs.name, i))
                 else None)
               (List.mapi (fun i f -> (i, f)) cs.fus))
        in
        Alcotest.(check (list string))
          (cs.name ^ ": counted_answers are exactly the in-time ones")
          want
          (List.sort compare listed_hashes));
      Alcotest.(check int)
        (cs.name ^ ": Inbox lists the counted ones")
        (if cs.kind = "question" then List.length counted
         else
           List.length
             (List.sort_uniq compare
                (List.map (fun (f : gen_fu) -> identity_of_role f.by) counted)))
        (List.length listed_hashes);
      let picked =
        List.sort compare
          (List.map
             (fun (p : I.pick) ->
               (List.assoc p.p_author role_of_identity, p.option))
             (Api.Inbox.picks ctx r))
      in
      Alcotest.(check (list (pair string string)))
        (cs.name ^ ": each reader's first pick")
        cs.picked picked;
      Hashtbl.replace node_picked cs.name picked;
      check "the author's close that stands closes it"
        (match Api.Inbox.standing (Api.Inbox.closes ctx r) with
        | Some x -> x.closed
        | None -> false)
        cs.closed;
      Alcotest.(check (option string))
        (cs.name ^ ": closes by the clock at")
        cs.closes_at
        (Option.map Time_fmt.of_unix r.closes_unix);
      if cs.kind = "question" then (
        check "lapses by itself" (r.closes_unix <> None) cs.lapses;
        (* DIG-99: a close that counts for nothing is still kept and listed. *)
        Alcotest.(check int)
          (cs.name ^ ": every close that counts is listed")
          (List.length (List.filter (fun x -> x.cl_counts) cs.closes))
          (List.length (list (member "closes" (snd (call ("items/" ^ item)))))));
      Option.iter
        (fun order ->
          let want =
            List.map (fun i -> Hashtbl.find hashes (cs.name, i)) order
          in
          Alcotest.(check (list string))
            (cs.name ^ ": the answers in the follow-up order")
            want
            (List.map
               (fun (a : I.answer) -> a.a_hash)
               (Api.Inbox.answers ctx r));
          Alcotest.(check (list string))
            (cs.name ^ ": and on the item's page")
            want
            (List.map (s "hash")
               (list (member "answers" (snd (call ("items/" ^ item)))))))
        cs.answer_order)
    (List.filter (fun (c : gen_case) -> c.readable) cases);
  (* The rules are exercised: late answers, standing closes, reopens, ignored closes. The hand
     cases are left out: their times are not all in the Z form, which the generator's oracle reads. *)
  let q =
    List.filter (fun (c : gen_case) -> c.kind = "question" && in_z_form c) cases
  in
  let some what p =
    Alcotest.(check bool) ("generated: " ^ what) true (List.exists p q)
  in
  let fus_of c = c.fus in
  some "a late answer by a reader" (fun c ->
      List.exists (fun f -> f.member && not f.counts) (fus_of c));
  some "an in-time answer" (fun c -> List.exists (fun f -> f.counts) (fus_of c));
  let author_closes c = List.filter (fun x -> x.cl_counts) c.closes in
  let newest l =
    List.fold_left
      (fun acc x ->
        match acc with
        | Some a when unix_of a.cl_at >= unix_of x.cl_at -> acc
        | _ -> Some x)
      None l
  in
  (* The standing close, as the generator states it. *)
  let standing_of c =
    match
      newest (List.filter (fun x -> x.cl_voice = "person") (author_closes c))
    with
    | Some x -> Some x
    | None -> newest (author_closes c)
  in
  (* Whether an answer at [f.at] is in time under the close [x] alone. *)
  let under x f = (not x.cl_closed) || unix_of f.at < unix_of x.cl_at in
  some "a late answer after a standing close" (fun c ->
      match standing_of c with
      | Some x ->
          x.cl_closed
          && List.exists
               (fun f ->
                 f.member && (not f.counts) && unix_of f.at >= unix_of x.cl_at)
               (fus_of c)
      | None -> false);
  (* A standing reopen is decisive: an answer late under an earlier close by the author counts
     because the author reopened. *)
  some "a standing reopen that lets a late answer count" (fun c ->
      match standing_of c with
      | Some s when not s.cl_closed ->
          List.exists
            (fun f ->
              f.counts
              && List.exists
                   (fun x ->
                     x.cl_closed
                     && unix_of x.cl_at < unix_of s.cl_at
                     && not (under x f))
                   (author_closes c))
            (fus_of c)
      | _ -> false);
  (* Person over agent is decisive: the agent's close is newer and says otherwise, and the answer
     counts as the person's close says, not as the agent's would. *)
  some "a person close that outranks a newer agent close that differs" (fun c ->
      match
        ( newest (List.filter (fun x -> x.cl_voice = "person") (author_closes c)),
          newest (List.filter (fun x -> x.cl_voice = "agent") (author_closes c))
        )
      with
      | Some pc, Some ag
        when unix_of ag.cl_at > unix_of pc.cl_at && ag.cl_closed <> pc.cl_closed
        ->
          List.exists
            (fun f ->
              f.member && under pc f <> under ag f && f.counts = under pc f)
            (fus_of c)
      | _ -> false);
  some "a close by the author" (fun c ->
      List.exists (fun x -> x.cl_counts && x.cl_closed) c.closes);
  some "a reopen by the author" (fun c ->
      List.exists (fun x -> x.cl_counts && not x.cl_closed) c.closes);
  some "a close by another member" (fun c ->
      List.exists (fun x -> x.cl_by = "member") c.closes);
  some "a close by the agent" (fun c ->
      List.exists (fun x -> x.cl_voice = "agent") c.closes);
  some "a close past a revoked key's cutoff" (fun c ->
      List.exists (fun x -> x.cl_by = "author_out") c.closes);
  some "a question that lapses" (fun c -> c.lapses);
  (* DIG-88: a reopen that stands runs a new week. *)
  let reopened c =
    match standing_of c with Some s -> not s.cl_closed | None -> false
  in
  some "a reopened question that lapses again" (fun c -> reopened c && c.lapses);
  some "a reopened question answered inside its new week" (fun c ->
      reopened c && not c.lapses);
  some "an answer late under a reopen's new week" (fun c ->
      reopened c && List.exists (fun f -> f.member && not f.counts) (fus_of c));
  some "a question that does not lapse with no close" (fun c ->
      c.closes = [] && not c.lapses);
  (* The committed fixture is these cases, with each reader's pick as the node made it. *)
  let fixture =
    follow_up_fixture
      (List.map
         (fun (cs : gen_case) ->
           { cs with picked = Hashtbl.find node_picked cs.name })
         cases)
  in
  match Sys.getenv_opt "DIGESTIF_WRITE_FIXTURE" with
  | Some path ->
      let oc = open_out_bin path in
      output_string oc fixture;
      close_out oc
  | None ->
      let committed =
        In_channel.with_open_bin "follow_up_cases.json" In_channel.input_all
      in
      if committed <> fixture then
        Alcotest.fail
          "node/web/test/follow_up_cases.json is stale: run the tests with \
           DIGESTIF_WRITE_FIXTURE=<path to that file> and commit it"

(* DIG-87: a late answer, signed after its question closed by itself or by its author, is kept and
   shown and is not new activity: it leaves the item read, in the Archive, and out of the Inbox,
   the same as a late pick. An answer signed before the close still brings it back New. *)
let inbox_late_answer_is_not_new_activity () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let quinn = join_peer n "Quinn Ross" in
  let item id = snd (call ("items/" ^ id)) in
  let kept id =
    let r = item id in
    (s "status" r, member "archived_at" r = `Null)
  in
  let listed id =
    List.exists (fun i -> s "id" i = id) (list (snd (call "items?limit=200")))
  in
  let answers id = List.length (list (member "answers" (item id))) in
  let settle id =
    ignore (call ~meth:"POST" ("items/" ^ id ^ "/read"));
    ignore (call ~meth:"POST" ("items/" ^ id ^ "/archive"))
  in
  (* Pia's question to the member, asked 250 hours ago, so it lapsed 82 hours ago, read and
     archived; then Pia adds to it, signed [hours] ago. *)
  let lapsed ~hours =
    let h =
      peer_item n pia ~created_at:(hours_ago 250.)
        ~to_:(`Members ([ me ], [ raw_key my_key ]))
        (question (Printf.sprintf "Pia's question %g?" hours))
    in
    settle h;
    ignore
      (peer_write n pia ~created_at:(hours_ago hours) "item_answer"
         (Item.answer_body ~item:h ~to_:(Members [ me ])
            ~keys:[ raw_key my_key; pia.p_enc.public ]
            ~text:"Still curious." ~voice:"person"));
    h
  in
  (* 1. After the lapse: stays read and archived, and is shown. *)
  let h = lapsed ~hours:50. in
  Alcotest.(check (pair string bool))
    "1: a late answer stays archived and read" ("read", false) (kept h);
  Alcotest.(check int) "1: and is shown" 1 (answers h);
  Alcotest.(check bool) "1: not in the Inbox" false (listed h);
  (* 2. Signed inside the week, arriving late: it counts. *)
  let h = lapsed ~hours:106. in
  Alcotest.(check (pair string bool))
    "2: an in-week answer brings it back New" ("new", true) (kept h);
  (* The member's own circle question, sent now. *)
  let own title =
    let _, q =
      call ~meth:"POST"
        ~body:
          (`Assoc
             [
               ("kind", `String "question");
               ("title", `String title);
               ("send", `Bool true);
             ])
        "items"
    in
    (s "id" q, s "hash" q)
  in
  let quinn_answers hash =
    ignore
      (peer_write n quinn "item_answer"
         (Item.answer_body ~item:hash ~to_:Circle ~keys:[] ~text:"Thursday."
            ~voice:"person"))
  in
  let close id =
    let st, _ =
      call ~meth:"PUT"
        ~body:(`Assoc [ ("closed", `Bool true) ])
        ("items/" ^ id ^ "/close")
    in
    Alcotest.(check int) "closed" 200 st
  in
  (* 3. Closed by the member, then answered: out of the Inbox, read, shown. *)
  let id, hash = own "Closed, then answered?" in
  close id;
  quinn_answers hash;
  Alcotest.(check bool) "3: not in the Inbox" false (listed id);
  Alcotest.(check string) "3: stays read" "read" (s "status" (item id));
  Alcotest.(check int) "3: and is shown" 1 (answers id);
  (* 4. The same, archived first: it stays in the Archive. *)
  let id, hash = own "Closed, archived, then answered?" in
  close id;
  ignore (call ~meth:"POST" ("items/" ^ id ^ "/archive"));
  quinn_answers hash;
  Alcotest.(check (pair string bool))
    "4: stays archived and read" ("read", false) (kept id);
  (* 5. Answered while open: New and in the Inbox. *)
  let id, hash = own "Open, then answered?" in
  ignore (call ~meth:"POST" ("items/" ^ id ^ "/archive"));
  quinn_answers hash;
  Alcotest.(check (pair string bool))
    "5: an answer that counts brings it back New" ("new", true) (kept id);
  Alcotest.(check bool) "5: in the Inbox" true (listed id)

(* DIG-555: a choice's deadline is in the protocol's Z form, or the item is malformed, and a node
   signs none that is not. *)
let item_deadline_z_form () =
  let json deadline =
    `Assoc
      ([
         ("kind", `String "choice");
         ("title", `String "Which one?");
         ( "options",
           `List
             [
               `Assoc [ ("id", `String "yes"); ("label", `String "Yes") ];
               `Assoc [ ("id", `String "no"); ("label", `String "No") ];
             ] );
         ("default", `String "no");
       ]
      @ match deadline with None -> [] | Some d -> [ ("deadline", d) ])
  in
  let parsed d = Item.of_json (json (Some (`String d))) in
  List.iter
    (fun d ->
      match parsed d with
      | Ok i ->
          Alcotest.(check (option string))
            ("accepted: " ^ d) (Some d) i.deadline
      | Error e -> Alcotest.fail (d ^ " refused: " ^ e))
    [ "2026-12-01T10:00:00Z"; "2026-12-01T10:00:00.250Z" ];
  List.iter
    (fun d ->
      match parsed d with
      | Ok _ -> Alcotest.fail ("accepted: " ^ d)
      | Error e ->
          Alcotest.(check bool)
            ("refused: " ^ d ^ ", and the message names the form")
            true (contains e "Z form"))
    [ "2026-12-01T10:00:00+01:00"; "2026-12-01T10:00:00"; "2026-12-01"; "" ];
  (match Item.of_json (json None) with
  | Ok i -> Alcotest.(check (option string)) "none stays none" None i.deadline
  | Error e -> Alcotest.fail e);
  (match Item.of_json (json (Some (`Int 5))) with
  | Ok _ -> Alcotest.fail "accepted a number"
  | Error _ -> ());
  (* Sending: a draft with such a deadline is refused before it signs, and the node's own raise too. *)
  let n = demo () in
  let c = session n in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let bad = question ~kind:"choice" ~deadline:"2026-12-01T10:00:00+01:00" in
  let item =
    bad
      ~options:
        [
          { Item.id = "yes"; label = "Yes"; recommended = false };
          { id = "no"; label = "No"; recommended = true };
        ]
      ~default:"no" "Which one?"
  in
  let before = envelopes_of n "item" in
  let id =
    Api.Inbox.add_draft (Api.ctx_of n) ~author:me ~item ~to_:(Members [ me ])
  in
  let st, r = call n c ~meth:"POST" ("items/" ^ id ^ "/send") in
  Alcotest.(check int) "the draft is refused" 422 st;
  Alcotest.(check bool)
    "and the refusal names the form" true
    (contains (Yojson.Safe.to_string r) "Z form");
  (match Api.Inbox.raise_item (Api.ctx_of n) item with
  | Ok _ -> Alcotest.fail "the node signed it"
  | Error e ->
      Alcotest.(check bool) "raise names the form" true (contains e "Z form"));
  Alcotest.(check int) "nothing signed" before (envelopes_of n "item")

(* DIG-102: an item signed at a time not in the Z form is unreadable on the node: its lapse would be
   counted from 0.0. One a store indexed before that rule is brought under it once, at startup. *)
let item_created_z_form () =
  let n = demo () in
  let c = session n in
  let pia = join_peer n "Pia Gale" in
  let module I = Store.Items in
  let now = Unix.gettimeofday () in
  let offset = "2026-11-01T10:00:00+00:00" in
  let h = peer_item n pia ~created_at:offset (question "Lunch?") in
  let z = peer_item n pia (question "Dinner?") in
  ignore (call n c "items");
  Alcotest.(check bool)
    "an item at an offset is unreadable" true
    (I.by_hash n.log ~now h = None);
  Alcotest.(check bool)
    "one in the Z form is read" true
    (I.by_hash n.log ~now z <> None);
  (* As a store indexed before the rule holds it, on a node that has started since (Demo.seed
     clears the config Store.init wrote). *)
  I.init n.log;
  Log.exec n.log
    "UPDATE ui_items SET kind = 'question', title = 'Lunch?', detail = '', \
     author = ?, voice = 'person', to_circle = 1, to_members = '[]', options = \
     '[]', sent_at = created_at WHERE hash = ?"
    [ Log.s (Keys.public pia.p_identity); Log.s h ];
  Alcotest.(check bool)
    "read before the rule" true
    (I.by_hash n.log ~now h <> None);
  I.init n.log;
  Alcotest.(check bool)
    "a store that already ran the pass runs it no more" true
    (I.by_hash n.log ~now h <> None);
  Log.set_config n.log I.k_items_z "0";
  I.init n.log;
  Alcotest.(check bool)
    "unreadable after the pass" true
    (I.by_hash n.log ~now h = None);
  Alcotest.(check bool)
    "the Z one untouched" true
    (I.by_hash n.log ~now z <> None);
  ignore (call n c "items");
  Alcotest.(check bool)
    "and stays so after the next index pass" true
    (I.by_hash n.log ~now h = None)

(* DIG-477: a notice a member writes to one member carries the about it is given, so a reply sits in
   the thread of what it answers, and without one it is about nothing. *)
let inbox_reply_about () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let form about =
    `Assoc
      ([
         ("kind", `String "notice");
         ("circle", `Bool false);
         ("members", `List [ `String pia_id ]);
         ("title", `String "Re: A note");
         ("detail", `String "Thanks.");
         ("send", `Bool true);
       ]
      @ about)
  in
  let st, d =
    call ~meth:"POST" ~body:(form [ ("about", `String "sha256:abc") ]) "items"
  in
  Alcotest.(check int) "sent" 201 st;
  Alcotest.(check string) "about kept" "sha256:abc" (s "about" d);
  let st, d = call ~meth:"POST" ~body:(form []) "items" in
  Alcotest.(check int) "sent without" 201 st;
  Alcotest.(check bool) "about nothing" true (member "about" d = `Null)

(* ISS-52613: a prompt suggestion is a choice to its judges. Written on New item it is a draft until
   sent, addressed to the judges it names with its author taken out, and sealed to them; it is never
   picked on the item. One that reaches a judge waits in their Inbox, links to the note waiting in
   two versions for it, and closes when a round decides it. *)
let inbox_suggestion () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let prompt = "Write the note. {{always_on_rules}} Lead with the lesson." in
  let form ?(send = false) ?(detail = prompt) members =
    `Assoc
      [
        ("kind", `String "choice");
        ("subject", `String "suggestion");
        ("circle", `Bool false);
        ("members", `List (List.map (fun m -> `String m) members));
        ("title", `String "Lead with\n the lesson");
        ("detail", `String detail);
        ("send", `Bool send);
      ]
  in
  let st, j =
    call ~meth:"POST" ~body:(form ~detail:"No rule." [ me ]) "items"
  in
  Alcotest.(check int) "no rules placeholder: refused" 422 st;
  Alcotest.(check string) "why" "always_on" (s "code" (List.hd (list j)));
  let st, d = call ~meth:"POST" ~body:(form [ me; pia_id ]) "items" in
  Alcotest.(check int) "saved" 201 st;
  Alcotest.(check (list string))
    "a draft choice"
    [ "draft"; "choice"; "suggestion" ]
    [ s "status" d; s "kind" d; s "subject" d ];
  Alcotest.(check string) "the change line" "Lead with the lesson" (s "title" d);
  Alcotest.(check (list string))
    "to its other judge" [ "Pia Gale" ]
    (List.map (s "name") (list (member "members" (member "to" d))));
  Alcotest.(check (list string))
    "the two versions, the current one standing" [ "suggested"; "current" ]
    (List.map (s "id") (list (member "options" d)));
  Alcotest.(check string) "default" "current" (s "default_option" d);
  Alcotest.(check int) "nothing signed" 0 (envelopes_of n "item");
  let st, sent = call ~meth:"POST" ("items/" ^ s "id" d ^ "/send") in
  Alcotest.(check int) "sent" 201 st;
  let hash = s "hash" sent in
  let b = body_of n hash in
  Alcotest.(check bool)
    "sealed to Pia" true
    (member "sealed" b <> `Null && member "to" b = `List [ `String pia_id ]);
  Alcotest.(check int) "no suggestion envelope" 0 (envelopes_of n "suggestion");
  let _, sg = call ("suggestions/" ^ hash) in
  Alcotest.(check string) "judging" "judging" (s "status" sg);
  Alcotest.(check int) "two judges" 2 (List.length (list (member "judges" sg)));
  Alcotest.(check string)
    "read on its page until a note waits"
    ("/settings/note-prompt/" ^ hash)
    (s "path" sent);
  Alcotest.(check int)
    "never picked on the item" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "suggested") ])
          ("items/" ^ s "id" sent ^ "/picks")));
  let st, _ = call ~meth:"DELETE" ("suggestions/" ^ hash) in
  Alcotest.(check int) "withdrawn" 204 st;
  Alcotest.(check bool)
    "out of the Inbox" false
    (List.exists (fun i -> s "id" i = s "id" sent) (list (snd (call "items"))));
  (* Pia's suggestion, judged by Ada and Pia, reaches Ada's Inbox. *)
  let pias_prompt = "Shorter. {{always_on_rules}}" in
  let theirs =
    peer_item n pia ~created_at:(hours_ago 0.5)
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (Suggestions.item ~text:pias_prompt ~change:"Shorter")
  in
  let _, row = call ("items/" ^ theirs) in
  Alcotest.(check (list string))
    "a New choice from Pia"
    [ "new"; "choice"; "suggestion"; "Pia Gale" ]
    [
      s "status" row;
      s "kind" row;
      s "subject" row;
      s "name" (member "author" row);
    ];
  let _, np = call "note_prompt" in
  Alcotest.(check string)
    "Ada's notes judge it" theirs
    (s "hash" (member "running" np));
  let id =
    ok
      (Api.submit_note_text ~prompt:"sha256:current"
         ~pair:
           (Yojson.Safe.to_string
              (`Assoc
                 [
                   ("suggestion", `String theirs);
                   ("prompt", `String (Suggestions.prompt_id pias_prompt));
                   ("text", `String "Short.");
                 ]))
         n "Long.")
  in
  let _, row = call ("items/" ^ theirs) in
  Alcotest.(check string)
    "picked on the waiting note" ("/feed/" ^ id) (s "path" row);
  let _, note = call ("notes/" ^ id) in
  let short =
    List.find (fun v -> s "text" v = "Short.") (list (member "pair" note))
  in
  ignore
    (call ~meth:"POST"
       ~body:(`Assoc [ ("version_id", `String (s "id" short)) ])
       ("notes/" ^ id ^ "/approve"));
  Api.send_notes n;
  let _, row = call ("items/" ^ theirs) in
  Alcotest.(check bool)
    "open while Pia judges" false
    (member "closed" row = `Bool true);
  (* DIG-221: Pia's pick is indexed as her summary arrives: held first without its body, it picks
     nothing; once its body arrives it decides the round; retracted, the round is open again. *)
  let sg, pias_pick =
    peer_sign n pia "summary"
      (Content.summary_body ~text:"Short too." ~voice:"agent"
         ~prompt:(Suggestions.prompt_id pias_prompt)
         ~suggestion:theirs ())
  in
  ignore (ok (Node.import n { sg with body = None }));
  let _, sg_row = call ("suggestions/" ^ theirs) in
  Alcotest.(check string)
    "a summary without its body picks nothing" "judging" (s "status" sg_row);
  ignore (ok (Node.import n sg));
  let _, row = call ("items/" ^ theirs) in
  Alcotest.(check (pair bool string))
    "the round adopts it and closes the choice" (true, "closed")
    (member "closed" row = `Bool true, s "done" row);
  let _, sg_row = call ("suggestions/" ^ theirs) in
  Alcotest.(check string) "adopted" "adopted" (s "status" sg_row);
  let retract =
    peer_write n pia "retract" (Bodies.make_retract ~target:pias_pick)
  in
  Log.drop_body n.log ~hash:pias_pick ~retracted_by:retract;
  let _, sg_row = call ("suggestions/" ^ theirs) in
  Alcotest.(check string)
    "a retracted pick leaves the round open" "judging" (s "status" sg_row)

(* ISS-52834: an Inbox read on another request's thread that lands between a send's sign and its
   stamp indexes the member's new envelope as a row of its own. on_write fires inside that window,
   so a read there plays the race deterministically: the send still answers, and the item is one
   row, the draft's, carrying the hash. *)
let inbox_send_raced_by_a_read () =
  let n = demo () in
  let c = session n in
  let st, d =
    call n c ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "question");
             ("title", `String "Anyone tried fake clocks?");
           ])
      "items"
  in
  Alcotest.(check int) "saved" 201 st;
  let id = s "id" d in
  let reads = ref 0 in
  let r =
    Server.handler
      ~on_write:(fun () ->
        incr reads;
        Alcotest.(check int) "the read answers" 200 (fst (call n c "items")))
      n
      (request ~meth:"POST"
         ~headers:[ ("cookie", c); ("digestif-local", "1") ]
         ("/api/v0/items/" ^ id ^ "/send"))
  in
  Alcotest.(check bool) "the read ran inside the send" true (!reads > 0);
  Alcotest.(check int) "sent" 201 r.status;
  let sent = Yojson.Safe.from_string r.body in
  Alcotest.(check string) "the draft's own row" id (s "id" sent);
  Alcotest.(check bool) "no longer a draft" true (s "status" sent <> "draft");
  let rows =
    List.filter
      (fun (r : Store.Items.row) -> r.item.title = "Anyone tried fake clocks?")
      (Store.Items.page n.log ~now:(Unix.gettimeofday ()) ~limit:200 ())
  in
  Alcotest.(check (list string))
    "one row" [ id ]
    (List.map (fun (r : Store.Items.row) -> r.id) rows)

(* DIG-394 (docs/protocol.md, Member review): the rules every node reads alike. Silence is three whole
   UTC days with no note; the review opens at the start of the fourth. A Keep verifies only as its
   signer made it, and its id is its plaintext's, so a forwarded copy is the same Keep. *)
let member_review_rules () =
  let module R = Member_review in
  let at s = Option.get (Time_fmt.to_unix s) in
  (* A note on Friday the 13th at 23:00 UTC: Saturday, Sunday and Monday are the three days. *)
  let friday = at "2026-11-13T23:00:00.000Z" in
  Alcotest.(check string)
    "the review opens at the start of the fourth silent day"
    "2026-11-17T00:00:00.000Z"
    (Time_fmt.of_unix (R.opens_at ~anchor:friday));
  Alcotest.(check bool)
    "Friday's note, then Saturday and Sunday, is two days" false
    (R.in_review ~now:(at "2026-11-16T12:00:00.000Z") ~anchor:friday);
  Alcotest.(check bool)
    "a long weekend trips it" true
    (R.in_review ~now:(at "2026-11-17T00:00:00.000Z") ~anchor:friday);
  Alcotest.(check int)
    "the days with no note" 3
    (R.days_without ~now:(at "2026-11-17T08:00:00.000Z") ~anchor:friday);
  Alcotest.(check (option (float 0.)))
    "the count runs from the latest of note, Keep and join"
    (Some (at "2026-11-15T10:00:00.000Z"))
    (R.anchor ~note:(Some friday)
       ~keep:(Some (at "2026-11-15T10:00:00.000Z"))
       ~join:(Some (at "2026-10-01T10:00:00.000Z")));
  let device = Crypto.generate_signing_key () in
  let k =
    R.make ~device ~member:"ed25519:member"
      ~created_at:"2026-11-19T15:00:00.000Z"
  in
  Alcotest.(check bool) "a Keep verifies" true (R.verifies k);
  Alcotest.(check bool)
    "a Keep naming another member does not" false
    (R.verifies { k with member = "ed25519:someone-else" });
  let read = Option.get (R.of_json (R.to_json k)) in
  Alcotest.(check string) "its id is its plaintext's" (R.id k) (R.id read);
  Alcotest.(check bool)
    "in force before its review opens again, with no note since" true
    (R.in_force
       ~now:(at "2026-11-21T00:00:00.000Z")
       ~kept_at:(at k.created_at) ~note:None);
  Alcotest.(check bool)
    "not once a note followed it" false
    (R.in_force
       ~now:(at "2026-11-21T00:00:00.000Z")
       ~kept_at:(at k.created_at)
       ~note:(Some (at "2026-11-20T09:00:00.000Z")));
  Alcotest.(check bool)
    "not once its review opened again" false
    (R.in_force
       ~now:(at "2026-11-23T00:00:00.000Z")
       ~kept_at:(at k.created_at) ~note:None)

(* The signer set Review judges Keeps by (Api.Review.bindings_at), as the fold would hold it: each
   call seats [ids], a fresh key bound to each, from [from] on, so a Keep dated earlier is judged by
   the set before. [unbind_admins] puts the fold's own back. *)
let fold_bindings = !Api.Review.bindings_at
let binding_history = ref []

let bind_admins ?(from = "1970-01-01T00:00:00.000Z") ids =
  binding_history :=
    ( from,
      List.map
        (fun i -> (Keys.public (Crypto.generate_signing_key ()), Some i))
        ids )
    :: !binding_history;
  Api.Review.bindings_at :=
    fun _ ~at ->
      let found =
        match at with
        | None -> List.nth_opt !binding_history 0
        | Some at -> List.find_opt (fun (c, _) -> c <= at) !binding_history
      in
      Option.fold ~none:[] ~some:snd found

let unbind_admins () =
  binding_history := [];
  Api.Review.bindings_at := fold_bindings

let member_named call name =
  List.find (fun m -> s "name" m = name) (list (snd (call "members")))

let review_items call =
  List.filter (fun i -> s "subject" i = "review") (list (snd (call "items")))

(* DIG-394: Last note counts no status note, for every reader. In the demo Cy's newest summary is a
   status note an hour after his question, and Ben's note went out after his waiting note. *)
let last_note_counts_no_status_note () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let cy = member_named call "Cy Lund" in
  let ben = member_named call "Ben Ortiz" in
  Alcotest.(check bool)
    "Cy's Last note is his question, not the status note after it" true
    (s "last_note_at" cy < s "last_status_note_at" cy);
  Alcotest.(check string)
    "the status note goes beside it" "could_not_run" (s "last_status_note" cy);
  Alcotest.(check string)
    "a status note older than the last note is not shown" ""
    (s "last_status_note" ben);
  let dee = member_named call "Dee Rao" in
  Alcotest.(check string)
    "Dee's status note is no Last note" "" (s "last_note_at" dee)

(* DIG-394: In review is worked out on read and shown to the admins and the member alone; the
   admin's item is raised by the upkeep, never by a read, and closed by a Keep, which only an admin's
   Keep does. Dee has sent no note since she joined, weeks ago; Ada is the node. *)
let member_review () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let dee_id = s "identity" (member_named call "Dee Rao") in
  Alcotest.(check string)
    "a member who is no admin sees nobody's review" ""
    (s "in_review_since" (member_named call "Dee Rao"));
  let ada_id = Option.get (Log.get_config n.log Node.k_identity) in
  bind_admins [ ada_id ];
  Fun.protect ~finally:unbind_admins @@ fun () ->
  let dee () = member_named call "Dee Rao" in
  Alcotest.(check bool)
    "an admin sees Dee in review" true
    (s "in_review_since" (dee ()) <> "");
  Alcotest.(check string)
    "Ben, who sent a note today, is not" ""
    (s "in_review_since" (member_named call "Ben Ortiz"));
  Alcotest.(check int)
    "a read raises no item" 0
    (List.length (review_items call));
  keep_up n;
  (match review_items call with
  | [ i ] ->
      Alcotest.(check string) "the item is about Dee" dee_id (s "about" i);
      Alcotest.(check bool)
        "its title says how long she has been silent" true
        (String.starts_with ~prefix:"Dee Rao has sent no note in " (s "title" i));
      Alcotest.(check bool)
        "it shows the command that removes her" true
        (contains
           (s "detail" (snd (call ("items/" ^ enc (s "id" i)))))
           ("digestif-update remove " ^ dee_id))
  | l -> Alcotest.failf "one review item, got %d" (List.length l));
  keep_up n;
  Alcotest.(check int)
    "the next pass raises no second item" 1
    (List.length (review_items call));
  (* A Keep from Pia, who is no admin, is ignored. *)
  let pia = join_peer n "Pia Gale" in
  let ada_raw =
    raw_key (Keys.encryption_public (Result.get_ok (Node.encryption_key n)))
  in
  let forged =
    Member_review.make ~device:pia.p_device ~member:dee_id
      ~created_at:(Time_fmt.now ())
  in
  ignore
    (peer_write n pia "keep"
       (`Assoc
          [
            ( "to",
              `List
                [
                  `String (Option.get (Log.get_config n.log Node.k_identity));
                  `String (Keys.public pia.p_identity);
                ] );
            ( "sealed",
              Item.seal
                ~keys:[ ada_raw; pia.p_enc.public ]
                (Member_review.to_json forged) );
          ]));
  Alcotest.(check bool)
    "a Keep from a non-admin ends nothing" true
    (s "in_review_since" (dee ()) <> "");
  Alcotest.(check int)
    "and closes no item" 0
    (List.length (List.filter (fun i -> s "done" i <> "") (review_items call)));
  (* Ada keeps her. *)
  let status, kept = call ~meth:"POST" ("members/" ^ enc dee_id ^ "/keep") in
  Alcotest.(check int) "Keep" 201 status;
  Alcotest.(check string)
    "she is no longer in review" "" (s "in_review_since" kept);
  Alcotest.(check string)
    "the outcome reads Kept" "kept"
    (s "outcome" (member "review" kept));
  Alcotest.(check string)
    "by Ada" "Ada Park"
    (s "name" (member "by" (member "review" kept)));
  (match review_items call with
  | [ i ] -> Alcotest.(check string) "the item settles" "resolved" (s "done" i)
  | l -> Alcotest.failf "one review item, got %d" (List.length l));
  let status, _ = call ~meth:"POST" ("members/" ^ enc dee_id ^ "/keep") in
  Alcotest.(check int) "a member not in review is not kept" 422 status;
  (* The Keep went to every admin and the member, sealed. *)
  (match Log.of_kind n.log "keep" with
  | [ _forged; r ] ->
      let to_ =
        match Item.to_of (Option.get r.signed.body) with
        | Some (Members l) -> l
        | _ -> []
      in
      Alcotest.(check bool) "sealed to Dee" true (List.mem dee_id to_)
  | l -> Alcotest.failf "two keep envelopes, got %d" (List.length l));
  (* Pia is promoted: Ada's node forwards the Keep still in force, sealed to her. *)
  bind_admins ~from:(Time_fmt.now ()) [ ada_id; Keys.public pia.p_identity ];
  keep_up n;
  let forwarded =
    List.filter
      (fun (r : Log.row) ->
        match Item.to_of (Option.get r.signed.body) with
        | Some (Members l) ->
            List.mem (Keys.public pia.p_identity) l
            && r.signed.envelope.author <> Keys.public pia.p_device
        | _ -> false)
      (Log.of_kind n.log "keep")
  in
  Alcotest.(check int)
    "the Keep is forwarded to the new admin" 1 (List.length forwarded);
  keep_up n;
  Alcotest.(check int)
    "once: the forged Keep, Ada's and its copy" 3
    (List.length (Log.of_kind n.log "keep"));
  (* Pia, an admin now, opens the forwarded copy: the same plaintext, Ada's signature. *)
  let opened =
    List.filter_map
      (fun (r : Log.row) ->
        Option.bind
          (Item.open_sealed ~priv:pia.p_enc.secret (Option.get r.signed.body))
          Member_review.of_json)
      forwarded
  in
  Alcotest.(check bool)
    "the forwarded Keep verifies as Ada's" true
    (List.exists
       (fun (k : Member_review.keep) ->
         k.member = dee_id && Member_review.verifies k)
       opened)

(* DIG-404 (DES-376, "A removed member reads Revoked everywhere"): a revoked identity is a row of
   Members after Onboarding, reading revoked, and no search hit. Pia joins, then leaves. *)
let members_list_a_revoked_member () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  Alcotest.(check string)
    "Pia is in the circle" "active"
    (s "status" (member_named call "Pia Gale"));
  ignore
    (peer_write n pia "revoke"
       (Bodies.make_revoke ~by:pia.p_identity ~target:pia_id
          ~after_seq:[ (Keys.public pia.p_device, pia.p_seq) ]
          ~mail_read:[]));
  keep_up n;
  let rows = list (snd (call "members")) in
  (match List.rev rows with
  | last :: rest ->
      Alcotest.(check string) "Pia is the last row" pia_id (s "identity" last);
      Alcotest.(check string) "reading revoked" "revoked" (s "status" last);
      Alcotest.(check bool)
        "every row before her is in the circle" true
        (List.for_all (fun m -> s "status" m = "active") rest)
  | [] -> Alcotest.fail "no members");
  Alcotest.(check int)
    "a page holds her" 200
    (fst (call ("members?limit=1&cursor=" ^ enc pia_id)));
  Alcotest.(check bool)
    "search leaves her out" false
    (List.exists
       (fun m -> s "identity" m = pia_id)
       (list (member "members" (snd (call "search?q=Pia")))))

(* DIG-396: the notice a removed member finds names who removed them and from what. *)
let member_review_removed_words () =
  let title, detail =
    Api.Review.removed_words ~by:"Sasha Petrov" ~circle:"AI Dinners"
      ~at:(Option.get (Time_fmt.to_unix "2026-11-14T18:20:00.000Z"))
  in
  Alcotest.(check string)
    "the title" "Sasha Petrov removed you from AI Dinners" title;
  Alcotest.(check bool)
    "the way back is a new invite" true
    (contains detail "a new invite from the admins")

(* DIG-395 (docs/protocol.md, revoke): an admin removes a member through the node: the node drafts
   the revoke's claim, digestif-update remove signs it with the admin key, and the node posts it
   with its own device key, which the fold counts. A circle founded with one admin key binds it to
   the founder; [dee_admin] founds it with a second key bound to Dee, who is then a sitting admin. *)
let removal_circle ~dee_admin =
  let module I = Digestif_invite.Invite_node in
  let host = Core_node.open_ ~keystore:(Keystore.memory ()) (fixture ()) in
  Store.init host.log;
  ignore (ok (Core_node.init host ~phrase:(Phrase.generate ())));
  let host_identity =
    Option.get (Log.get_config host.log Core_node.k_identity)
  in
  let dee_phrase = Phrase.generate () in
  let dee_identity = Keys.public (ok (Phrase.derive dee_phrase)).identity in
  let admin = Crypto.generate_signing_key () in
  let admins =
    {
      Approval.name = "Ada";
      key = Keys.public admin;
      identity = Some host_identity;
    }
    ::
    (if dee_admin then
       [
         {
           Approval.name = "Dee";
           key = Keys.public (Crypto.generate_signing_key ());
           identity = Some dee_identity;
         };
       ]
     else [])
  in
  let urls = [ "https://a.test"; "https://b.test" ] in
  let inv =
    ok
      (I.found host ~admins ~name:"Sunday" ~relays:urls ~message:"Join us."
         [
           {
             Digestif_invite.Dinner.name = "Dee Rao";
             email = "dee@example.com";
           };
         ])
  in
  let net =
    Fake_relay.network
      (List.map (fun url -> Fake_relay.create ~url ~root:inv.dinner_hash) urls)
  in
  ignore (ok (I.sync ~transport:net host));
  let dee = Core_node.open_ ~keystore:(Keystore.memory ()) (fixture ()) in
  let code =
    ok
      (Digestif_invite.Invite_code.parse
         (Digestif_invite.Invite_code.to_url (List.hd inv.dinner.invites).code))
  in
  ignore (ok (I.join ~transport:net dee ~code ~phrase:dee_phrase));
  ignore (ok (I.sync ~transport:net host));
  (Api.Phones.sync_first := fun n -> ignore (I.sync ~transport:net n));
  (host, host_identity, dee_identity, admin)

let admin_removes_member () =
  let host, host_identity, dee, admin = removal_circle ~dee_admin:false in
  Alcotest.(check bool)
    "Dee is admitted" true
    (Fold.find (Core_node.fold host) dee <> None);
  let call = call host (session host) ~meth:"POST" in
  let by = Keys.public admin in
  let refused ?(by = by) id =
    let st, j =
      call
        ~body:(`Assoc [ ("by", `String by) ])
        ("members/" ^ enc id ^ "/revocation_drafts")
    in
    (st, match j with `List (e :: _) -> s "code" e | _ -> "")
  in
  Alcotest.(check (pair int string))
    "a key outside the set is no admin" (422, "not_admin")
    (refused ~by:(Keys.public (Crypto.generate_signing_key ())) dee);
  Alcotest.(check (pair int string))
    "an admin does not remove themselves" (422, "self") (refused host_identity);
  let st, d =
    call
      ~body:(`Assoc [ ("by", `String by) ])
      ("members/" ^ enc dee ^ "/revocation_drafts")
  in
  Alcotest.(check int) "the draft" 201 st;
  Alcotest.(check string) "of Dee" dee (s "target" d);
  let cutoffs k =
    Option.value (Yojson.Safe.Util.member k d |> Option.some) ~default:`Null
  in
  let r =
    ok
      (Bodies.parse_revoke
         (`Assoc
            [
              ("target", `String dee);
              ("by", `String by);
              ("after_seq", cutoffs "after_seq");
              ("mail_read", cutoffs "mail_read");
              ("signature", `String "");
            ]))
  in
  Alcotest.(check bool) "it stops Dee's device" true (r.after_seq <> []);
  let signed signature =
    `Assoc
      [
        ("by", `String by);
        ("after_seq", cutoffs "after_seq");
        ("mail_read", cutoffs "mail_read");
        ("signature", `String signature);
      ]
  in
  let claim =
    Bodies.revoke_claim ~target:dee ~by ~after_seq:r.after_seq
      ~mail_read:r.mail_read
  in
  let forged = Keys.sign_json (Crypto.generate_signing_key ()) claim in
  let st, _ =
    call ~body:(signed forged) ("members/" ^ enc dee ^ "/revocations")
  in
  Alcotest.(check int) "a signature of another key is refused" 422 st;
  Alcotest.(check bool)
    "and nothing was posted" false
    ((Option.get (Fold.find (Core_node.fold host) dee)).revoked_by <> None);
  let st, _ =
    call
      ~body:(signed (Keys.sign_json admin claim))
      ("members/" ^ enc dee ^ "/revocations")
  in
  Alcotest.(check int) "the admin's revoke is posted" 201 st;
  let f = Core_node.fold host in
  Alcotest.(check (list (pair string string)))
    "the fold refuses nothing" [] f.rejected;
  Alcotest.(check bool)
    "Dee reads Revoked" true
    ((Option.get (Fold.find f dee)).revoked_by <> None);
  Alcotest.(check (pair int string))
    "a second removal is refused" (422, "revoked") (refused dee)

let admin_removal_refuses_sitting_admin () =
  let host, _, dee, admin = removal_circle ~dee_admin:true in
  let st, j =
    call host (session host) ~meth:"POST"
      ~body:(`Assoc [ ("by", `String (Keys.public admin)) ])
      ("members/" ^ enc dee ^ "/revocation_drafts")
  in
  Alcotest.(check (pair int string))
    "a sitting admin is refused" (422, "sitting_admin")
    (st, match j with `List (e :: _) -> s "code" e | _ -> "")

(* DIG-394: a member in review is told by their own node, in a notice their digest carries; Ada has
   just joined and written nothing, and her dinner was weeks ago. *)
let member_review_notice () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  ok (Demo.seed ~member:Demo.New_member n);
  let c = session n in
  let call = call n c in
  let me = s "identity" (snd (call "members/self")) in
  Alcotest.(check bool)
    "the member sees their own review" true
    (s "in_review_since" (snd (call "members/self")) <> "");
  keep_up n;
  match review_items call with
  | [ i ] ->
      Alcotest.(check string) "about herself" me (s "about" i);
      Alcotest.(check string)
        "the notice" "Your membership is in review" (s "title" i)
  | l -> Alcotest.failf "one review notice, got %d" (List.length l)

(* ISS-87806 (docs/protocol.md, approval): the node folds each approval it reads into its state,
   files the reader's Inbox item, answers the approval operations, and posts the signer_set where
   it recorded the last signature of a set change. The signer set is the test's own: Ada and Pia
   hold its keys, named as their cards are. *)
let approvals () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_raw =
    raw_key (Keys.encryption_public (Result.get_ok (Node.encryption_key n)))
  in
  (* The invite's effect names the relay this node reads in the guest's install command. *)
  Log.add_relay n.log "https://relay-1.example";
  let pia = join_peer n "Pia Gale" in
  let bo = join_peer n "Bo Finch" in
  let pia_id = Keys.public pia.p_identity
  and bo_id = Keys.public bo.p_identity in
  let rk_ada = Crypto.generate_signing_key ()
  and rk_pia = Crypto.generate_signing_key ()
  and rk_bo = Crypto.generate_signing_key () in
  let signer name k = { Approval.name; key = Keys.public k; identity = None } in
  (* The set this node holds is its update state's (ISS-87810), which the set change's effect
     advances. *)
  let set = ref [] in
  let put l =
    set := l;
    Digestif_update.State.save
      (Digestif_update.Schedule.state_path n.Node.dir)
      {
        (Digestif_update.State.initial ()) with
        trust =
          {
            signers =
              List.map
                (fun (x : Approval.signer) : Digestif_update.Release.signer ->
                  { name = x.name; key = x.key })
                l;
            revoked = [];
          };
      }
  in
  put [ signer "Ada Park" rk_ada; signer "Pia Gale" rk_pia ];
  let doc j =
    match B64url.decode (s "document" j) with
    | Ok d -> d
    | Error e -> Alcotest.fail e
  in
  let release_sig k kind d = Keys.sign k (Approval.domain kind ^ d) in
  let names l = List.map (s "name") (list l) in
  (* Pia answers from her own node, sealed to Ada and her. *)
  let pia_answers ?(also = []) id reply =
    ignore
      (peer_write n pia "approval_answer"
         (`Assoc
            [
              ("approval", `String id);
              ( "sealed",
                Item.seal
                  ~keys:([ my_raw; pia.p_enc.public ] @ also)
                  (Approval.reply_to_json reply) );
            ]))
  in
  let invite_form =
    `Assoc
      [
        ("kind", `String "invite");
        ("to", `String "Priya Raman <priya@raman.dev>");
        ("email_subject", `String "Join the circle on Digestif");
        ( "email_body",
          `String "Hi Priya,\n\n{{install_command}}\n{{expires_at}}\n\nAda" );
      ]
  in
  Alcotest.(check int)
    "none yet" 0
    (List.length (list (snd (call "approvals"))));
  (* Only an admin starts one, and only when every admin is known. *)
  put [ signer "Pia Gale" rk_pia; signer "Bo Finch" rk_bo ];
  Alcotest.(check int)
    "a member who is not an admin" 422
    (fst (call ~meth:"POST" ~body:invite_form "approvals"));
  put [ signer "Ada Park" rk_ada; signer "Nobody Here" rk_pia ];
  let st, e = call ~meth:"POST" ~body:invite_form "approvals" in
  Alcotest.(check (pair int string))
    "a key no member is known to hold" (422, "unknown_admin")
    (st, s "code" (List.hd (list e)));
  put [ signer "Ada Park" rk_ada; signer "Pia Gale" rk_pia ];
  Alcotest.(check int)
    "an invite names its guest" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("kind", `String "invite"); ("to", `String "Priya") ])
          "approvals"));
  (* An invite: sealed to both admins, waiting on both, an Inbox item for Ada. *)
  let st, inv = call ~meth:"POST" ~body:invite_form "approvals" in
  Alcotest.(check int) "started" 201 st;
  let id = s "id" inv in
  Alcotest.(check string) "waiting" "waiting" (s "state" inv);
  Alcotest.(check (list string))
    "on both admins" [ "Ada Park"; "Pia Gale" ]
    (List.sort compare (names (member "waiting_on" inv)));
  Alcotest.(check (pair int int))
    "0 of 2" (0, 2)
    (int_of "signed_count" inv, int_of "needed_count" inv);
  Alcotest.(check string)
    "the guest" "Priya Raman <priya@raman.dev>" (s "guest" inv);
  Alcotest.(check string) "as a member" "member" (s "role" inv);
  let body = body_of n id in
  Alcotest.(check bool)
    "sealed, naming its readers in the clear" true
    (member "sealed" body <> `Null
    && List.sort compare
         (List.map
            (function `String x -> x | _ -> "")
            (list (member "to" body)))
       = List.sort compare [ me; pia_id ]);
  let admission =
    Result.get_ok (Digestif_invite.Approved_invite.parse_document (doc inv))
  in
  Alcotest.(check string)
    "the admission names the guest" "priya@raman.dev" admission.guest.email;
  Alcotest.(check bool)
    "the invite key's secret kept in the keystore" true
    (Result.is_ok
       (Digestif_invite.Approved_invite.invite_secret n admission.invite_key));
  Alcotest.(check int)
    "a body without its marked lines" 422
    (fst
       (call ~meth:"POST"
          ~body:
            (`Assoc
               [
                 ("kind", `String "invite");
                 ("to", `String "Priya Raman <priya@raman.dev>");
                 ("email_subject", `String "Join");
                 ("email_body", `String "Hi Priya");
               ])
          "approvals"));
  let _, item = call ("items/" ^ s "item" inv) in
  Alcotest.(check string) "an approval item" "approval" (s "subject" item);
  Alcotest.(check string) "titled" "Invite Priya Raman" (s "title" item);
  Alcotest.(check string)
    "carrying the command"
    ("digestif-update approve " ^ id)
    (s "detail" item);
  Alcotest.(check string)
    "and the approval" id
    (s "id" (member "approval" item));
  (* Ada's signature: refused unless it verifies and is one the approval needs. *)
  let signature k =
    `Assoc
      [
        ("key", `String (Keys.public k));
        ("signature", `String (release_sig k Invite (doc inv)));
      ]
  in
  let code (st, e) = (st, s "code" (List.hd (list e))) in
  Alcotest.(check (pair int string))
    "a key it does not need" (422, "not_needed")
    (code
       (call ~meth:"POST" ~body:(signature rk_bo)
          ("approvals/" ^ id ^ "/signatures")));
  Alcotest.(check (pair int string))
    "a signature that does not verify" (422, "not_verified")
    (code
       (call ~meth:"POST"
          ~body:
            (`Assoc
               [
                 ("key", `String (Keys.public rk_ada));
                 ("signature", `String (release_sig rk_ada Promotion (doc inv)));
               ])
          ("approvals/" ^ id ^ "/signatures")));
  let st, after =
    call ~meth:"POST" ~body:(signature rk_ada)
      ("approvals/" ^ id ^ "/signatures")
  in
  Alcotest.(check int) "signed" 200 st;
  Alcotest.(check (list string))
    "waiting on Pia" [ "Pia Gale" ]
    (names (member "waiting_on" after));
  Alcotest.(check int) "1 of 2" 1 (int_of "signed_count" after);
  Alcotest.(check (pair int string))
    "a key signs once" (422, "signed")
    (code
       (call ~meth:"POST" ~body:(signature rk_ada)
          ("approvals/" ^ id ^ "/signatures")));
  Alcotest.(check (pair string string))
    "Ada's item is settled, and stays in her Inbox read" ("read", "answered")
    (let r = snd (call ("items/" ^ s "item" inv)) in
     (s "status" r, s "done" r));
  (* Pia's signature arrives from her node: it is signed. *)
  pia_answers id
    (Approval.Signature
       {
         key = Keys.public rk_pia;
         signature = release_sig rk_pia Invite (doc inv);
         completes = None;
       });
  let _, signed = call "approvals?state=signed" in
  Alcotest.(check (list string))
    "signed" [ id ]
    (List.map (s "id") (list signed));
  Alcotest.(check bool)
    "every signer signed" true
    (List.for_all
       (fun x -> member "signed" x = `Bool true)
       (list (member "signers" (List.hd (list signed)))));
  Alcotest.(check (pair int string))
    "an ended approval takes no answer" (422, "ended")
    (code (call ~meth:"POST" ("approvals/" ^ id ^ "/declines")));
  (* A decline ends one; nothing else counts after it. *)
  let _, two = call ~meth:"POST" ~body:invite_form "approvals" in
  pia_answers (s "id" two) Approval.Decline;
  (* The run loop's pass after the sync settles its item (DIG-374); a GET leaves that to it. *)
  keep_up n;
  let _, two = call ("items/" ^ s "item" two) in
  Alcotest.(check string)
    "declined" "declined"
    (s "state" (member "approval" two));
  Alcotest.(check bool) "the item is settled" true (member "done" two <> `Null);
  let _, three = call ~meth:"POST" ~body:invite_form "approvals" in
  let st, three =
    call ~meth:"POST" ("approvals/" ^ s "id" three ^ "/declines")
  in
  Alcotest.(check (pair int string))
    "Ada declines" (200, "declined")
    (st, s "state" three);
  (* Seven days after its created_at, one with no last signature has expired. *)
  let old = Time_fmt.of_unix (Unix.gettimeofday () -. (8. *. 86_400.)) in
  let stale =
    peer_write n pia ~created_at:old "approval"
      (`Assoc
         [
           ("to", `List [ `String me; `String pia_id ]);
           ( "sealed",
             Item.seal
               ~keys:[ my_raw; pia.p_enc.public ]
               (Approval.request_to_json
                  {
                    kind = Invite;
                    created_at = old;
                    member = None;
                    document = Some (doc inv);
                    removed_key = None;
                    added_key = None;
                  }) );
         ])
  in
  let _, expired = call "approvals?state=expired" in
  Alcotest.(check (list string))
    "expired" [ stale ]
    (List.map (s "id") (list expired));
  Alcotest.(check bool)
    "with no item" true
    (member "item" (List.hd (list expired)) = `Null);
  Alcotest.(check int)
    "an unknown state" 422
    (fst (call "approvals?state=open"));
  Alcotest.(check int)
    "a limit out of range" 422
    (fst (call "approvals?limit=51"));
  Alcotest.(check int)
    "unknown" 404
    (fst (call ~meth:"POST" "approvals/sha256:00/declines"));
  (* A promotion: Bo signs first, which completes the document; Ada records the last signature
     and posts the signer_set. *)
  Alcotest.(check (pair int string))
    "a removal keeps two keys" (422, "too_few")
    (code
       (call ~meth:"POST"
          ~body:
            (`Assoc [ ("kind", `String "removal"); ("member", `String pia_id) ])
          "approvals"));
  let st, pro =
    call ~meth:"POST"
      ~body:
        (`Assoc [ ("kind", `String "promotion"); ("member", `String bo_id) ])
      "approvals"
  in
  Alcotest.(check int) "promotion started" 201 st;
  let pid = s "id" pro in
  Alcotest.(check (list string))
    "waiting on Bo first"
    [ "Bo Finch"; "Ada Park"; "Pia Gale" ]
    (names (member "waiting_on" pro));
  Alcotest.(check int) "0 of 3" 3 (int_of "needed_count" pro);
  Alcotest.(check bool) "no document yet" true (member "document" pro = `Null);
  Alcotest.(check (pair int string))
    "the admins wait on Bo" (422, "first")
    (code
       (call ~meth:"POST" ~body:(signature rk_ada)
          ("approvals/" ^ pid ^ "/signatures")));
  let new_set =
    Approval.signers_document ~created_at:(Time_fmt.now ())
      (!set @ [ signer "Bo Finch" rk_bo ])
  in
  ignore
    (peer_write n bo "approval_answer"
       (`Assoc
          [
            ("approval", `String pid);
            ( "sealed",
              Item.seal
                ~keys:[ my_raw; pia.p_enc.public; bo.p_enc.public ]
                (Approval.reply_to_json
                   (Signature
                      {
                        key = Keys.public rk_bo;
                        signature = release_sig rk_bo Promotion new_set;
                        completes = Some new_set;
                      })) );
          ]));
  let _, pro = call ("items/" ^ s "item" pro) in
  let pro = member "approval" pro in
  Alcotest.(check string) "the document Bo completed" new_set (doc pro);
  Alcotest.(check string)
    "the key it adds" (Keys.public rk_bo) (s "added_key" pro);
  Alcotest.(check (list string))
    "then the admins" [ "Ada Park"; "Pia Gale" ]
    (List.sort compare (names (member "waiting_on" pro)));
  pia_answers ~also:[ bo.p_enc.public ] pid
    (Signature
       {
         key = Keys.public rk_pia;
         signature = release_sig rk_pia Promotion new_set;
         completes = None;
       });
  let st, pro =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("key", `String (Keys.public rk_ada));
             ("signature", `String (release_sig rk_ada Promotion new_set));
           ])
      ("approvals/" ^ pid ^ "/signatures")
  in
  Alcotest.(check (pair int string))
    "the last signature" (200, "signed")
    (st, s "state" pro);
  Alcotest.(check int) "3 of 3" 3 (int_of "signed_count" pro);
  (* Ada's node recorded the last signature, so the set change's effect ran here, once. *)
  let effected () =
    (Option.get (Store.Approvals.find n.log pid)).effected_at <> None
  in
  Alcotest.(check bool) "its effect ran" true (effected ());
  (* Bo's key is now known as his: the signature that counted says so. *)
  Alcotest.(check (option string))
    "Bo holds the key he signed with" (Some bo_id)
    (Api.Approvals.holders (Api.ctx_of n) (signer "Someone Else" rk_bo));
  Alcotest.(check bool)
    "the invite's effect ran on the starting node" true
    ((Option.get (Store.Approvals.find n.log id)).effected_at <> None);
  (* ISS-87810: the effect adopted the new set into the update state and posted it to the circle. *)
  let path = Digestif_update.Schedule.state_path n.Node.dir in
  let held () = (Result.get_ok (Digestif_update.State.load path)).trust in
  Alcotest.(check (list string))
    "the update state holds the promoted set"
    [ "Ada Park"; "Bo Finch"; "Pia Gale" ]
    (List.sort compare
       (List.map
          (fun (x : Digestif_update.Release.signer) -> x.name)
          (held ()).signers));
  Alcotest.(check int)
    "and the circle carries its signer_set" 1
    (List.length (Log.of_kind n.log "signer_set"));
  Alcotest.(check (pair int string))
    "the signed promotion still reads 3 of 3 under the set it made" (3, "signed")
    (let pro = snd (call "approvals?state=signed") in
     let p = List.find (fun j -> s "id" j = pid) (list pro) in
     (int_of "signed_count" p, s "state" p));
  (* While a revoked key is in the set, a waiting invite ends halted and no invite starts. *)
  let st, waiting = call ~meth:"POST" ~body:invite_form "approvals" in
  Alcotest.(check int) "an invite under the new set" 201 st;
  let wid = s "id" waiting in
  Digestif_update.State.save path
    {
      (Result.get_ok (Digestif_update.State.load path)) with
      trust = { (held ()) with revoked = [ Keys.public rk_pia ] };
    };
  Alcotest.(check (list string))
    "it ends halted" [ wid ]
    (List.map (s "id") (list (snd (call "approvals?state=halted"))));
  Alcotest.(check int)
    "and a new invite is refused" 409
    (fst (call ~meth:"POST" ~body:invite_form "approvals"))

(* ISS-88476: a reply joins the notice it answers and is new activity for whoever it names or who
   answered it; an archived item comes back on it; Waiting on names each member who has not answered;
   the member's own question closed by the clock is New again, out of the Archive. *)
(* DIG-374: an Inbox item read stays off the approvals' upkeep. Signed invites whose effect this node
   still owes (the last signature arrived by sync) are the run loop's to take (Api.keep_up) and a
   write's: a GET of an item takes none of them and reads no invite secret from the keystore, and
   settles no approval at all, so its cost does not grow with the approvals still open. *)
let item_read_leaves_approval_effects () =
  let reads = ref 0 in
  let counting =
    let m = Keystore.memory () in
    {
      m with
      get =
        (fun name ->
          if String.starts_with ~prefix:"invite:" name then incr reads;
          m.get name);
    }
  in
  let n = Node.open_ ~keystore:counting (tmpdir ()) in
  Store.init n.log;
  ok (Demo.seed n);
  let c = session n in
  let call = call n c in
  let my_raw =
    raw_key (Keys.encryption_public (Result.get_ok (Node.encryption_key n)))
  in
  Log.add_relay n.log "https://relay-1.example";
  let pia = join_peer n "Pia Gale" in
  let rk_ada = Crypto.generate_signing_key ()
  and rk_pia = Crypto.generate_signing_key () in
  Digestif_update.State.save
    (Digestif_update.Schedule.state_path n.Node.dir)
    {
      (Digestif_update.State.initial ()) with
      trust =
        {
          signers =
            [
              { name = "Ada Park"; key = Keys.public rk_ada };
              { name = "Pia Gale"; key = Keys.public rk_pia };
            ];
          revoked = [];
        };
    };
  let doc j = ok (B64url.decode (s "document" j)) in
  let release_sig k d = Keys.sign k (Approval.domain Invite ^ d) in
  let invite i =
    let _, inv =
      call ~meth:"POST"
        ~body:
          (`Assoc
             [
               ("kind", `String "invite");
               ( "to",
                 `String (Printf.sprintf "Guest %d <guest%d@example.com>" i i)
               );
               ("email_subject", `String "Join the circle on Digestif");
               ( "email_body",
                 `String "Hi,\n\n{{install_command}}\n{{expires_at}}\n\nAda" );
             ])
        "approvals"
    in
    let id = s "id" inv in
    let st, _ =
      call ~meth:"POST"
        ~body:
          (`Assoc
             [
               ("key", `String (Keys.public rk_ada));
               ("signature", `String (release_sig rk_ada (doc inv)));
             ])
        ("approvals/" ^ id ^ "/signatures")
    in
    Alcotest.(check int) "Ada signs" 200 st;
    (id, s "item" inv, doc inv)
  in
  let invites = List.init 4 invite in
  (* Pia's signatures arrive from her node, as a sync brings them, and the run loop's pass has not
     run yet: each invite is signed, and its effect (the dinner this node writes) is still owed. *)
  List.iter
    (fun (id, _, d) ->
      ignore
        (peer_arrive n pia "approval_answer"
           (`Assoc
              [
                ("approval", `String id);
                ( "sealed",
                  Item.seal
                    ~keys:[ my_raw; pia.p_enc.public ]
                    (Approval.reply_to_json
                       (Signature
                          {
                            key = Keys.public rk_pia;
                            signature = release_sig rk_pia d;
                            completes = None;
                          })) );
              ])))
    invites;
  let effected id = (Option.get (Store.Approvals.find n.log id)).effected_at in
  let opened () =
    List.filter
      (fun (id, _, _) -> List.length (Store.Approvals.answers n.log id) > 1)
      invites
  in
  let _, item, _ = List.hd invites in
  (* DIG-375: a read does no catch-up work at all: neither the approvals' sync nor the Inbox
     index runs on a GET. *)
  let synced = ref 0 in
  let approvals_sync = !Api.Inbox.sync_approvals in
  (Api.Inbox.sync_approvals :=
     fun c ->
       if c.Api.node == n then incr synced;
       approvals_sync c);
  Fun.protect
    ~finally:(fun () -> Api.Inbox.sync_approvals := approvals_sync)
    (fun () ->
      reads := 0;
      let st, _ = call ("items/" ^ item) in
      Alcotest.(check int) "the item reads" 200 st;
      let st, _ = call "items" in
      Alcotest.(check int) "the Inbox reads" 200 st;
      let st, _ = call "status" in
      Alcotest.(check int) "the status reads" 200 st;
      Alcotest.(check int) "no approvals sync on a read" 0 !synced;
      Alcotest.(check int) "no invite secret read" 0 !reads;
      Alcotest.(check int)
        "no signature opened by the read" 0
        (List.length (opened ()));
      Alcotest.(check bool)
        "no effect taken by the read" true
        (List.for_all (fun (id, _, _) -> effected id = None) invites);
      (* The run loop's pass after the sync opens every signature and takes every effect. *)
      keep_up n;
      Alcotest.(check bool) "the run loop syncs the approvals" true (!synced > 0);
      Alcotest.(check int)
        "the run loop opens them" (List.length invites)
        (List.length (opened ()));
      Alcotest.(check bool)
        "the run loop takes them" true
        (List.for_all (fun (id, _, _) -> effected id <> None) invites))

let inbox_replies_waiting_and_the_clock () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let ben = join_peer n "Ben Ortiz" in
  let pia_id = Keys.public pia.p_identity
  and ben_id = Keys.public ben.p_identity in
  let notice =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      { (question "The fake clock lands next week") with kind = "notice" }
  in
  let _, r = call ("items/" ^ notice) in
  Alcotest.(check bool)
    "a notice waits on nobody" true
    (member "waiting" r = `Null);
  let before = envelopes_of n "item_answer" in
  let st, r =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "Thanks, I will update my branch.") ])
      ("items/" ^ notice ^ "/answers")
  in
  Alcotest.(check int) "the reply is taken" 201 st;
  Alcotest.(check int)
    "it joins the notice" 1
    (List.length (list (member "answers" r)));
  Alcotest.(check bool) "and settles nothing" true (member "done" r = `Null);
  Alcotest.(check int)
    "one reply on the wire" (before + 1)
    (envelopes_of n "item_answer");
  ignore (call ~meth:"POST" ("items/" ^ notice ^ "/read"));
  ignore (call ~meth:"POST" ("items/" ^ notice ^ "/archive"));
  ignore
    (peer_write n pia "item_answer"
       (Item.answer_body ~item:notice ~to_:(Members [ me ])
          ~keys:[ raw_key my_key; pia.p_enc.public ]
          ~text:"Ping me if it breaks." ~voice:"person"));
  let _, r = call ("items/" ^ notice) in
  Alcotest.(check (pair string bool))
    "Pia's reply is New and back in the Inbox" ("new", true)
    (s "status" r, member "archived_at" r = `Null);
  (* Ada's question to Pia and Ben waits on each until they answer. *)
  let _, q =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "question");
             ("title", `String "Who has a spare relay?");
             ("circle", `Bool false);
             ("members", `List [ `String pia_id; `String ben_id ]);
             ("send", `Bool true);
           ])
      "items"
  in
  let q_id = s "id" q and q_hash = s "hash" q in
  let waiting_on () =
    match member "waiting" (snd (call ("items/" ^ q_id))) with
    | `Null -> []
    | w -> List.map (fun m -> s "name" m) (list (member "members" w))
  in
  Alcotest.(check (list string))
    "on both"
    [ "Ben Ortiz"; "Pia Gale" ]
    (List.sort compare (waiting_on ()));
  let answer p text =
    ignore
      (peer_write n p "item_answer"
         (Item.answer_body ~item:q_hash
            ~to_:(Members [ pia_id; ben_id ])
            ~keys:[ raw_key my_key; pia.p_enc.public; ben.p_enc.public ]
            ~text ~voice:"person"))
  in
  answer pia "Mine has room.";
  Alcotest.(check (list string))
    "on Ben alone once Pia answers" [ "Ben Ortiz" ] (waiting_on ());
  answer ben "Take mine.";
  Alcotest.(check (list string)) "on nobody once both answer" [] (waiting_on ());
  (* Ada's circle question, read and archived, comes back New when the clock closes it. *)
  let _, cq =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "question");
             ("title", `String "Anyone on the new relay?");
             ("send", `Bool true);
           ])
      "items"
  in
  let cq_id = s "id" cq in
  ignore (call ~meth:"POST" ("items/" ^ cq_id ^ "/archive"));
  Alcotest.(check string)
    "read when sent" "read"
    (s "status" (snd (call ("items/" ^ cq_id))));
  Store.Items.set_closed n.log cq_id ~closed:false
    ~closes_unix:(Some (Unix.gettimeofday () -. 10.));
  (* The run loop's pass closes it by the clock. *)
  keep_up n;
  let _, r = call ("items/" ^ cq_id) in
  Alcotest.(check (triple string bool bool))
    "closed by the clock: New, out of the Archive, closed" ("new", true, true)
    ( s "status" r,
      member "archived_at" r = `Null,
      member "closed" r = `Bool true )

(* DIG-535: a reply is not a pick, and only a counted follow-up is new activity. *)
let inbox_reply_is_not_a_pick () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let ben = join_peer n "Ben Ortiz" in
  let pia_id = Keys.public pia.p_identity
  and ben_id = Keys.public ben.p_identity in
  let yes_no ?deadline title =
    question ~kind:"choice"
      ~options:
        [
          { Item.id = "yes"; label = "Yes"; recommended = false };
          { id = "no"; label = "No"; recommended = true };
        ]
      ~default:"no" ?deadline title
  in
  let ids = ref 0 in
  (* Ada's own sent choice, named to [named] with the keys [keys]. *)
  let choice ?deadline ?(same_pass = false) named keys =
    incr ids;
    let body =
      Item.item_body ~to_:(Members named) ~keys:(raw_key my_key :: keys)
        (yes_no ?deadline (Printf.sprintf "Dinner %d?" !ids))
    in
    let h, _ =
      ok
        (if same_pass then Core_node.write n ~kind:"item" body
         else Node.write n ~kind:"item" body)
    in
    h
  in
  let reply p ~named ~keys h =
    ignore
      (peer_write n p "item_answer"
         (Item.answer_body ~item:h ~to_:(Members named)
            ~keys:(raw_key my_key :: keys) ~text:"Maybe." ~voice:"person"))
  in
  let pick p h option =
    ignore
      (peer_write n p "decision"
         (Item.pick_body ~item:h
            ~keys:[ (ok (Node.encryption_key n)).public ]
            ~option))
  in
  let both = [ pia_id; ben_id ]
  and both_keys = [ pia.p_enc.public; ben.p_enc.public ] in
  let reply_both p h = reply p ~named:both ~keys:both_keys h in
  let listed ?state id =
    List.exists
      (fun i -> s "id" i = id)
      (list
         (snd
            (call
               ("items?limit=200"
               ^ match state with Some st -> "&state=" ^ st | None -> ""))))
  in
  let waiting id =
    match member "waiting" (snd (call ("items/" ^ id))) with
    | `Null -> []
    | w -> List.map (fun m -> s "name" m) (list (member "members" w))
  in
  let others id = listed ~state:"others" id in
  let status id = s "status" (snd (call ("items/" ^ id))) in
  let kept id =
    let _, r = call ("items/" ^ id) in
    (s "status" r, member "archived_at" r = `Null)
  in
  let sorted l = List.sort compare l in
  (* waiting from the item and state=others read the same; an archived item is in neither view
     of state=others. *)
  let agree label id =
    Alcotest.(check bool)
      (label ^ ": waiting and state=others agree")
      (snd (kept id)
      && (waiting id <> []
         ||
         match member "waiting" (snd (call ("items/" ^ id))) with
         | `Null -> false
         | w -> member "circle" w = `Bool true))
      (others id)
  in
  let digested id =
    List.exists
      (fun (e : Digestif_mail.Digest.entry) -> e.item = id)
      (Api.Inbox.digest_entries (Api.ctx_of n) ~page:(fun id -> id))
  in
  (* 1. A reply only: New, in the Inbox, still waiting on both. *)
  let h = choice both both_keys in
  Alcotest.(check bool) "own choice is out of the Inbox" false (listed h);
  reply_both pia h;
  Alcotest.(check (pair string bool))
    "1: a reply brings it back New" ("new", true) (kept h);
  Alcotest.(check bool) "1: in the Inbox" true (listed h);
  Alcotest.(check (list string))
    "1: waiting names both"
    [ "Ben Ortiz"; "Pia Gale" ]
    (sorted (waiting h));
  Alcotest.(check bool) "1: state=others lists it" true (others h);
  (* 2. Reply then pick. *)
  let h = choice both both_keys in
  reply_both pia h;
  Alcotest.(check (list string))
    "2: after the reply"
    [ "Ben Ortiz"; "Pia Gale" ]
    (sorted (waiting h));
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  pick pia h "yes";
  Alcotest.(check string) "2: the pick freshens it" "new" (status h);
  Alcotest.(check (list string))
    "2: waiting names Ben" [ "Ben Ortiz" ] (waiting h);
  Alcotest.(check bool) "2: state=others lists it" true (others h);
  (* 3. Pick then reply. *)
  let h = choice both both_keys in
  pick pia h "yes";
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  reply_both pia h;
  Alcotest.(check string) "3: the reply freshens again" "new" (status h);
  Alcotest.(check (list string))
    "3: waiting names Ben" [ "Ben Ortiz" ] (waiting h);
  Alcotest.(check bool) "3: state=others lists it" true (others h);
  (* 4. Two replies. *)
  let h = choice both both_keys in
  reply_both pia h;
  reply_both pia h;
  Alcotest.(check (list string))
    "4: Pia once, Ben once"
    [ "Ben Ortiz"; "Pia Gale" ]
    (sorted (waiting h));
  Alcotest.(check bool) "4: state=others lists it" true (others h);
  (* 5 and 6. A non-reader's plaintext answer and sealed pick. *)
  let h = choice [ pia_id ] [ pia.p_enc.public ] in
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/archive"));
  ignore
    (peer_write n ben "item_answer"
       (`Assoc [ ("item", `String h); ("text", `String "Count me in.") ]));
  Alcotest.(check (pair string bool))
    "5: a non-reader's answer leaves it read" ("read", false) (kept h);
  Alcotest.(check bool) "5: not in the Inbox" false (listed h);
  Alcotest.(check bool) "5: not in the digest" false (digested h);
  agree "5" h;
  Alcotest.(check int)
    "5: answers does not list it" 0
    (List.length (list (member "answers" (snd (call ("items/" ^ h))))));
  pick ben h "yes";
  Alcotest.(check (pair string bool))
    "6: a non-reader's pick leaves it read" ("read", false) (kept h);
  Alcotest.(check (list string))
    "6: waiting still names Pia" [ "Pia Gale" ] (waiting h);
  agree "6" h;
  (* 5b and 6b. The same, never archived: still out of the Inbox. *)
  let h = choice [ pia_id ] [ pia.p_enc.public ] in
  ignore (call ("items/" ^ h));
  ignore
    (peer_write n ben "item_answer"
       (`Assoc [ ("item", `String h); ("text", `String "Count me in.") ]));
  pick ben h "yes";
  Alcotest.(check bool) "5b/6b: not in the Inbox" false (listed h);
  Alcotest.(check string) "5b/6b: stays read" "read" (status h);
  agree "5b/6b" h;
  (* 7. An unoffered option. *)
  let h = choice both both_keys in
  pick pia h "maybe";
  Alcotest.(check string) "7: stays read" "read" (status h);
  Alcotest.(check (list string))
    "7: waiting names both"
    [ "Ben Ortiz"; "Pia Gale" ]
    (sorted (waiting h));
  Alcotest.(check bool) "7: state=others lists it" true (others h);
  Alcotest.(check bool) "7: not in the Inbox" false (listed h);
  (* 8. A late pick. *)
  let h = choice ~deadline:(hours_ago 1.) both both_keys in
  (* The clock's own close freshens it once; settle that, then archive. *)
  ignore (call ("items/" ^ h));
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/archive"));
  pick pia h "yes";
  Alcotest.(check (pair string bool))
    "8: a late pick stays archived and read" ("read", false) (kept h);
  Alcotest.(check int)
    "8: picks is empty" 0
    (List.length (list (member "picks" (snd (call ("items/" ^ h))))));
  agree "8" h;
  (* 8b. The same, never archived: a late pick does not bring it into the Inbox. *)
  let h = choice ~deadline:(hours_ago 1.) both both_keys in
  ignore (call ("items/" ^ h));
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  pick pia h "yes";
  Alcotest.(check bool) "8b: not in the Inbox" false (listed h);
  Alcotest.(check string) "8b: stays read" "read" (status h);
  agree "8b" h;
  (* 9. A second pick. *)
  let h = choice both both_keys in
  pick pia h "yes";
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  pick pia h "no";
  Alcotest.(check string) "9: stays read" "read" (status h);
  Alcotest.(check (list string))
    "9: waiting names Ben" [ "Ben Ortiz" ] (waiting h);
  agree "9" h;
  Alcotest.(check (list string))
    "9: the pick shown is yes" [ "yes" ]
    (List.map
       (fun p -> s "option_id" p)
       (list (member "picks" (snd (call ("items/" ^ h))))));
  (* 10. Named but not author: Pia's choice to Ada. *)
  let pc =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (yes_no "Pia's dinner?")
  in
  ignore (call ~meth:"POST" ("items/" ^ pc ^ "/read"));
  ignore (call ~meth:"POST" ("items/" ^ pc ^ "/archive"));
  ignore
    (peer_write n ben "item_answer"
       (`Assoc [ ("item", `String pc); ("text", `String "Me too.") ]));
  pick ben pc "yes";
  Alcotest.(check (pair string bool))
    "10: stays archived and read" ("read", false) (kept pc);
  agree "10" pc;
  (* The member's own reply and own pick freshen nothing. *)
  let h = choice both both_keys in
  ignore (call ("items/" ^ h));
  ignore (call ~meth:"POST" ("items/" ^ h ^ "/read"));
  ignore
    (call ~meth:"POST"
       ~body:(`Assoc [ ("text", `String "Adding a note.") ])
       ("items/" ^ h ^ "/answers"));
  ignore
    (ok
       (Node.write n ~kind:"decision"
          (Item.pick_body ~item:h
             ~keys:[ (ok (Node.encryption_key n)).public ]
             ~option:"yes")));
  Alcotest.(check (pair string bool))
    "own: no New, no Inbox" ("read", true)
    (status h, not (listed h));
  (* Indexed in one pass, an own item and a peer's counted answer: no New (DIG-535). *)
  let h = choice ~same_pass:true both both_keys in
  reply_both pia h;
  Alcotest.(check string) "same pass: the item stays Read" "read" (status h);
  (* 11. A circle choice with a reply only. *)
  incr ids;
  let ch, _ =
    ok
      (Node.write n ~kind:"item"
         (Item.item_body ~to_:Circle ~keys:[] (yes_no "Circle dinner?")))
  in
  ignore
    (peer_write n pia "item_answer"
       (Item.answer_body ~item:ch ~to_:Circle ~keys:[] ~text:"Hm."
          ~voice:"person"));
  Alcotest.(check bool) "11: stays in state=others" true (others ch);
  Alcotest.(check bool)
    "11: waiting is the circle" true
    (match member "waiting" (snd (call ("items/" ^ ch))) with
    | `Null -> false
    | w -> member "circle" w = `Bool true)

let inbox_delivery_and_statuses () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  (* A circle question from Pia is New for Ada until she opens it. *)
  let q = peer_item n pia (question "Which fake clock do you use?") in
  let _, items = call "items" in
  let row = by_id items q in
  Alcotest.(check string) "new" "new" (s "status" row);
  Alcotest.(check string) "from Pia" "Pia Gale" (s "name" (member "author" row));
  Alcotest.(check int) "counted" 1 (int_of "inbox" (snd (call "status")));
  let _, r = call ~meth:"POST" ("items/" ^ q ^ "/read") in
  Alcotest.(check string) "read" "read" (s "status" r);
  Alcotest.(check int)
    "no longer counted" 0
    (int_of "inbox" (snd (call "status")));
  let st, r =
    call ~meth:"POST"
      ~body:(`Assoc [ ("text", `String "The one in lib-util.") ])
      ("items/" ^ q ^ "/answers")
  in
  Alcotest.(check int) "answered" 201 st;
  Alcotest.(check (pair string string))
    "answered, and read" ("read", "answered")
    (s "status" r, s "done" r);
  Alcotest.(check int)
    "the answer listed" 1
    (List.length (list (member "answers" r)));
  Alcotest.(check int) "an answer on the wire" 1 (envelopes_of n "item_answer");
  (* A question sealed to Ada and Pia; one sealed to someone else never shows. *)
  let named =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (question "Ada, can you review my loader?")
  in
  let ben_only =
    peer_item n pia
      ~to_:(`Members ([ "ed25519:someone" ], []))
      (question "Not for Ada")
  in
  let _, items = call "items" in
  Alcotest.(check bool)
    "the sealed one opens" true
    (s "title" (by_id items named) = "Ada, can you review my loader?");
  Alcotest.(check bool)
    "one sealed to others is not shown" false
    (List.exists (fun i -> s "id" i = ben_only) (list items));
  let _, r = call ~meth:"POST" ("items/" ^ named ^ "/not_for_me") in
  Alcotest.(check string) "set aside" "not_for_me" (s "done" r);
  Alcotest.(check int)
    "a notice is acknowledged, not a question" 422
    (fst (call ~meth:"POST" ("items/" ^ named ^ "/acknowledge")));
  let notice =
    peer_item n pia
      { (question "Dinner moved to Thursday") with kind = "notice" }
  in
  let _, r = call ~meth:"POST" ("items/" ^ notice ^ "/acknowledge") in
  Alcotest.(check string) "acknowledged" "acknowledged" (s "done" r);
  Alcotest.(check int)
    "only its author closes it" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("closed", `Bool true) ])
          ("items/" ^ notice ^ "/close")));
  (* Ada's own question: an answer makes it New again for her, and she closes it naming it. *)
  let _, mine =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ("kind", `String "question");
             ("title", `String "Who has a spare relay?");
             ("send", `Bool true);
           ])
      "items"
  in
  let mine_id = s "id" mine and mine_hash = s "hash" mine in
  let listed id =
    List.exists (fun i -> s "id" i = id) (list (snd (call "items?limit=200")))
  in
  (* ISS-64736: her own question stays out of her Inbox until someone acts on it. *)
  Alcotest.(check bool)
    "her own question is not in her Inbox" false (listed mine_id);
  Alcotest.(check int) "nor counted" 0 (int_of "inbox" (snd (call "status")));
  (* ISS-86956 (DIG-476): the state filter reads it anyway; who acts next moves as it is answered. *)
  let states id =
    List.filter
      (fun st ->
        List.exists
          (fun i -> s "id" i = id)
          (list (snd (call ("items?limit=200&state=" ^ st)))))
      [ "you"; "others"; "archived" ]
  in
  Alcotest.(check (list string))
    "unanswered, it waits on others" [ "others" ] (states mine_id);
  Alcotest.(check bool)
    "waiting on the circle" true
    (let w = member "waiting" (snd (call ("items/" ^ mine_id))) in
     s "on" w = "others" && member "circle" w = `Bool true);
  Alcotest.(check (list string))
    "of its kind, it is read with it" [ "others" ]
    (List.filter
       (fun st ->
         List.exists
           (fun i -> s "id" i = mine_id)
           (list
              (snd (call ("items?state=" ^ st ^ "&kind=question&kind=notice")))))
       [ "you"; "others"; "archived" ]);
  Alcotest.(check bool)
    "of another kind, it is not" false
    (List.exists
       (fun i -> s "id" i = mine_id)
       (list (snd (call "items?state=others&kind=notice&subject=intro"))));
  (* DIG-128: From people and From agents read the voice it was written in. *)
  let in_voices q =
    List.exists
      (fun i -> s "id" i = mine_id)
      (list (snd (call ("items?state=others&" ^ q))))
  in
  Alcotest.(check (list bool))
    "she wrote it, so it is from people" [ true; false; true ]
    [
      in_voices "voice=person";
      in_voices "voice=agent&voice=node";
      in_voices "voice=person&voice=agent";
    ];
  Alcotest.(check int)
    "an unknown voice is named" 422
    (fst (call "items?voice=robot"));
  Alcotest.(check int)
    "its page still opens" 200
    (fst (call ("items/" ^ mine_id)));
  Alcotest.(check int)
    "she cannot set her own aside" 422
    (fst (call ~meth:"POST" ("items/" ^ mine_id ^ "/not_for_me")));
  let ans =
    peer_write n pia "item_answer"
      (`Assoc
         [
           ("item", `String mine_hash);
           ("text", `String "Mine has room.");
           ("voice", `String "person");
         ])
  in
  Alcotest.(check bool) "the answer brings it in" true (listed mine_id);
  Alcotest.(check int) "counted as New" 1 (int_of "inbox" (snd (call "status")));
  let _, r = call ("items/" ^ mine_id) in
  Alcotest.(check string) "new again" "new" (s "status" r);
  Alcotest.(check (list string))
    "answered, it waits on nobody" [] (states mine_id);
  Alcotest.(check bool) "no waiting" true (member "waiting" r = `Null);
  Alcotest.(check string)
    "Pia's answer" "Mine has room."
    (s "text" (List.hd (list (member "answers" r))));
  ignore (call ~meth:"POST" ("items/" ^ mine_id ^ "/read"));
  Alcotest.(check bool) "read, it stays in" true (listed mine_id);
  Alcotest.(check (list string))
    "answered and read, it waits on nobody" [] (states mine_id);
  (* ISS-88476: Mark unread, Archive and new activity bringing it back. *)
  let _, r = call ~meth:"POST" ("items/" ^ mine_id ^ "/unread") in
  Alcotest.(check string) "marked unread" "new" (s "status" r);
  Alcotest.(check int) "counted again" 1 (int_of "inbox" (snd (call "status")));
  ignore (call ~meth:"POST" ("items/" ^ mine_id ^ "/read"));
  let _, r = call ~meth:"POST" ("items/" ^ mine_id ^ "/archive") in
  Alcotest.(check bool) "archived" true (member "archived_at" r <> `Null);
  Alcotest.(check bool) "out of her Inbox" false (listed mine_id);
  Alcotest.(check (list string))
    "in the Archive" [ "archived" ] (states mine_id);
  Alcotest.(check (list string))
    "the old name for it reads the Archive" [ mine_id ]
    (List.filter_map
       (fun i -> if s "id" i = mine_id then Some mine_id else None)
       (list (snd (call "items?limit=200&state=done"))));
  let _, r = call ~meth:"DELETE" ("items/" ^ mine_id ^ "/archive") in
  Alcotest.(check bool) "moved back" true (member "archived_at" r = `Null);
  Alcotest.(check bool) "back in her Inbox" true (listed mine_id);
  ignore (call ~meth:"POST" ("items/" ^ mine_id ^ "/archive"));
  ignore
    (peer_write n pia "item_answer"
       (`Assoc
          [
            ("item", `String mine_hash);
            ("text", `String "Or take mine on Friday.");
            ("voice", `String "person");
          ]));
  Alcotest.(check bool) "a new answer brings it back" true (listed mine_id);
  Alcotest.(check string)
    "New on it" "new"
    (s "status" (snd (call ("items/" ^ mine_id))));
  ignore (call ~meth:"POST" ("items/" ^ mine_id ^ "/read"));
  Alcotest.(check int)
    "an unknown state is refused" 422
    (fst (call "items?state=later"));
  (* A choice her agent sent comes back New on Pia's pick. *)
  let own_choice, _ =
    ok
      (Node.write n ~kind:"item"
         (Item.item_body ~to_:Circle ~keys:[]
            (question ~kind:"choice"
               ~options:
                 [
                   { Item.id = "yes"; label = "Yes"; recommended = false };
                   { id = "no"; label = "No"; recommended = true };
                 ]
               ~default:"no" "Dinner on Thursday?")))
  in
  let choice_id = own_choice in
  Alcotest.(check bool)
    "her own choice is not in her Inbox" false (listed choice_id);
  Alcotest.(check (list string))
    "her own choice waits on others" [ "others" ] (states choice_id);
  ignore
    (peer_write n pia "decision"
       (Item.pick_body ~item:own_choice
          ~keys:[ (ok (Node.encryption_key n)).public ]
          ~option:"yes"));
  Alcotest.(check bool) "Pia's pick brings it in" true (listed choice_id);
  (* What her agent wrote to her alone is a message to her: it is in her Inbox. *)
  let to_her, _ =
    ok
      (Node.write n ~kind:"item"
         (Item.item_body ~to_:(Members [ me ])
            ~keys:[ (ok (Node.encryption_key n)).public ]
            { (question "Filed the relay fork as #312") with kind = "notice" }))
  in
  Alcotest.(check bool) "her agent's notice to her is in" true (listed to_her);
  Alcotest.(check (list string)) "a notice waits on nobody" [] (states to_her);
  Alcotest.(check string)
    "New on the pick" "new"
    (s "status" (snd (call ("items/" ^ choice_id))));
  (* A close by anyone but the author counts for nothing. *)
  ignore
    (peer_write n pia "item_close"
       (`Assoc
          [
            ("item", `String mine_hash);
            ("closed", `Bool true);
            ("voice", `String "person");
          ]));
  let _, r = call ("items/" ^ mine_id) in
  Alcotest.(check bool) "still open" false (member "closed" r = `Bool true);
  Alcotest.(check int)
    "an answer that is not one of its own" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("closed", `Bool true); ("answer", `String q) ])
          ("items/" ^ mine_id ^ "/close")));
  (* Her agent closes it; her reopening stands over the agent's close. *)
  ignore
    (ok
       (Node.write n ~kind:"item_close"
          (Item.close_body ~item:mine_hash ~to_:Circle ~keys:[] ~closed:true
             ~answer:ans ~voice:"agent" ())));
  let _, r = call ("items/" ^ mine_id) in
  Alcotest.(check (pair bool string))
    "the agent closed it, naming the answer" (true, ans)
    (member "closed" r = `Bool true, s "answer" (member "close" r));
  let _, r =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("closed", `Bool false) ])
      ("items/" ^ mine_id ^ "/close")
  in
  Alcotest.(check bool) "reopened" false (member "closed" r = `Bool true);
  Alcotest.(check string)
    "the person's stands" "person"
    (s "voice" (member "close" r));
  Alcotest.(check int) "both kept" 2 (List.length (list (member "closes" r)));
  (* A choice to Ada alone closes on her first pick. *)
  let yes_no deadline =
    question ~kind:"choice"
      ~options:
        [
          { Item.id = "yes"; label = "Install"; recommended = false };
          { id = "no"; label = "Not now"; recommended = true };
        ]
      ~default:"no" ?deadline "Install Pia's eval behavior?"
  in
  let choice =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      (yes_no (Some (hours_ago (-48.))))
  in
  Alcotest.(check int)
    "no such option" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "maybe") ])
          ("items/" ^ choice ^ "/picks")));
  let st, r =
    call ~meth:"POST"
      ~body:(`Assoc [ ("option_id", `String "yes") ])
      ("items/" ^ choice ^ "/picks")
  in
  Alcotest.(check int) "picked" 201 st;
  Alcotest.(check (triple string string bool))
    "read, picked, closed" ("read", "picked", true)
    (s "status" r, s "done" r, member "closed" r = `Bool true);
  Alcotest.(check string)
    "the pick, read back from its decision" "yes"
    (s "option_id" (List.hd (list (member "picks" r))));
  Alcotest.(check int)
    "picked already" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "no") ])
          ("items/" ^ choice ^ "/picks")));
  (* A circle choice past its deadline stands on its default, closed for everyone. *)
  let lapsed = peer_item n pia (yes_no (Some (hours_ago 1.))) in
  let _, r = call ("items/" ^ lapsed) in
  Alcotest.(check (pair string string))
    "closed at its deadline, and still unread" ("new", "closed")
    (s "status" r, s "done" r);
  Alcotest.(check int)
    "no pick after it" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "yes") ])
          ("items/" ^ lapsed ^ "/picks")));
  (* A question nobody answered for a week closes by itself; one answered does not. *)
  let old = peer_item n pia ~created_at:(hours_ago 170.) (question "Stale?") in
  let _, r = call ("items/" ^ old) in
  Alcotest.(check bool) "a week unanswered" true (member "closed" r = `Bool true);
  let fresh =
    peer_item n pia ~created_at:(hours_ago 100.) (question "Recent?")
  in
  let _, r = call ("items/" ^ fresh) in
  Alcotest.(check bool) "four days" false (member "closed" r = `Bool true);
  (* A retracted item leaves the Inbox. *)
  let retract =
    peer_write n pia "retract" (Bodies.make_retract ~target:fresh)
  in
  Log.drop_body n.log ~hash:fresh ~retracted_by:retract;
  Alcotest.(check int) "withdrawn" 404 (fst (call ("items/" ^ fresh)));
  (* Paging: Draft and New first, then the newest; a cursor continues after its row. *)
  let _, all = call "items" in
  let ids = List.map (s "id") (list all) in
  let _, first = call "items?limit=2" in
  let _, next = call ("items?limit=2&cursor=" ^ enc (List.nth ids 1)) in
  Alcotest.(check (list string))
    "pages continue"
    (List.filteri (fun i _ -> i < 4) ids)
    (List.map (s "id") (list first @ list next));
  let ranks =
    List.map
      (fun i -> if List.mem (s "status" i) [ "draft"; "new" ] then 0 else 1)
      (list all)
  in
  Alcotest.(check bool)
    "Draft and New lead" true
    (ranks = List.sort compare ranks);
  Alcotest.(check int) "unknown cursor" 422 (fst (call "items?cursor=nope"));
  Alcotest.(check int) "unknown status" 422 (fst (call "items?status=later"));
  Alcotest.(check bool)
    "status filter" true
    (List.for_all
       (fun i -> s "status" i = "read")
       (list (snd (call "items?status=read"))));
  Alcotest.(check int)
    "Done is no status of an item" 422
    (fst (call "items?status=done"));
  ignore pia_id

(* ISS-52611: the Inbox agent. Every node with an agent saves the release's default prompt, which
   Settings edits and resets; a run's review lands on the items and notes it read, an answer goes
   out in the agent's voice only through the guards, and what speaks for the member is a draft. *)
(* ISS-85463: an item the Inbox agent wrote from a message shows the paragraph it came from, the
   words that produced it marked; a quote the message does not hold shows nothing, and a share, an
   intro or a behavior carries none. *)
let inbox_agent_source () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let ben = join_peer n "Ben Ortiz" in
  let ben_id = Keys.public ben.p_identity in
  let note =
    peer_write n pia "summary"
      (Content.summary_body
         ~text:
           "Worked on the loader.\n\n\
            Learned that retries need a backoff,\n\
            or the relay throttles us. Next is the cache.\n\n\
            Stuck on nothing."
         ~voice:"agent" ())
  in
  let item ?(extra = []) subject title quote =
    `Assoc
      ([
         ("subject", `String subject);
         ("title", `String title);
         ("about", `String note);
         ("quote", `String quote);
       ]
      @ extra)
  in
  let st, r =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ( "items",
               `List
                 [
                   item "work" "Add a backoff"
                     "retries need a backoff, or the relay";
                   item "work" "Unfounded" "words Pia never wrote";
                   item
                     ~extra:
                       [ ("members", `List [ `String pia_id; `String ben_id ]) ]
                     "intro" "Pia, meet Ben" "Worked on the loader.";
                 ] );
           ])
      "inbox_agent/runs"
  in
  Alcotest.(check int) "recorded" 200 st;
  let written = list (member "items" r) in
  let page title =
    let i = List.find (fun i -> s "title" i = title) written in
    snd (call ("items/" ^ s "id" i))
  in
  let source = member "source" (page "Add a backoff") in
  Alcotest.(check (list string))
    "the paragraph around the quote, its line break kept"
    [
      "Learned that ";
      "retries need a backoff,\nor the relay";
      " throttles us. Next is the cache.";
    ]
    [ s "before" source; s "quote" source; s "after" source ];
  Alcotest.(check bool)
    "a quote the message does not hold: the link alone" true
    (member "source" (page "Unfounded") = `Null);
  Alcotest.(check string) "with the link" note (s "about" (page "Unfounded"));
  Alcotest.(check bool)
    "an intro carries no quote" true
    (member "source" (page "Pia, meet Ben") = `Null)

(* DIG-124: where a work notice's idea was filed is a field of the item, on its page and its row,
   and only work and a credit carry it. *)
let inbox_agent_link () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let ben = join_peer n "Ben Ortiz" in
  let ben_id = Keys.public ben.p_identity in
  let note =
    peer_write n pia "summary"
      (Content.summary_body ~text:"Retries need a backoff." ~voice:"agent" ())
  in
  let item ?(extra = []) subject title =
    `Assoc
      ([
         ("subject", `String subject);
         ("title", `String title);
         ("about", `String note);
       ]
      @ extra)
  in
  let link = "https://github.com/acme/digestif/issues/12" in
  let st, r =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [
             ( "items",
               `List
                 [
                   item
                     ~extra:[ ("link", `String link) ]
                     "work" "Filed Pia's idea: Add a backoff";
                   item
                     ~extra:[ ("link", `String "ISS-96977") ]
                     "work" "Already filed Pia's idea: Cache the feed";
                   item "work" "Could not file Pia's idea: Shard the tests";
                   item
                     ~extra:
                       [
                         ("link", `String link);
                         ("members", `List [ `String pia_id; `String ben_id ]);
                       ]
                     "intro" "Pia, meet Ben";
                 ] );
           ])
      "inbox_agent/runs"
  in
  Alcotest.(check int) "recorded" 200 st;
  let written = list (member "items" r) in
  let id title = s "id" (List.find (fun i -> s "title" i = title) written) in
  let page title = snd (call ("items/" ^ id title)) in
  let link_of j =
    match member "link" j with `String l -> Some l | _ -> None
  in
  Alcotest.(check (option string))
    "filed: the link on its page" (Some link)
    (link_of (page "Filed Pia's idea: Add a backoff"));
  Alcotest.(check (option string))
    "already filed: the key on its page" (Some "ISS-96977")
    (link_of (page "Already filed Pia's idea: Cache the feed"));
  Alcotest.(check (option string))
    "could not file: no link" None
    (link_of (page "Could not file Pia's idea: Shard the tests"));
  Alcotest.(check (option string))
    "an intro carries none" None
    (link_of (page "Pia, meet Ben"));
  let rows = list (snd (call "items")) in
  let row title = List.find (fun i -> s "id" i = id title) rows in
  Alcotest.(check (option string))
    "and on its row" (Some link)
    (link_of (row "Filed Pia's idea: Add a backoff"))

let source_find () =
  let f quote text =
    Option.map
      (fun (t : Source.t) -> [ t.before; t.quote; t.after ])
      (Source.find ~quote text)
  in
  Alcotest.(check (option (list string)))
    "verbatim, in its paragraph"
    (Some [ "One "; "two"; " three." ])
    (f "two" "Zero.\n\nOne two three.\n\nFour.");
  Alcotest.(check (option (list string)))
    "a quote across a blank line takes both paragraphs"
    (Some [ "One "; "two.\n\nThree"; " four." ])
    (f "two. Three" "One two.\n\nThree four.");
  Alcotest.(check (option (list string)))
    "at the start and end of the text"
    (Some [ ""; "All of it"; "" ])
    (f "  All of it " "All of it");
  Alcotest.(check (option (list string))) "absent" None (f "five" "One two.")

let inbox_agent () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  Alcotest.(check int)
    "no agent, no Inbox agent" 404
    (fst (call "settings/inbox_agent"));
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  Alcotest.(check int)
    "a release with no default" 404
    (fst (call "settings/inbox_agent"));
  let prompts =
    Filename.concat (Filename.concat n.dir "good") "behaviors/prompts"
  in
  Node.mkdir_p prompts;
  let default = "Read what reaches me.\n" in
  Out_channel.with_open_bin (Filename.concat prompts "inbox.md") (fun oc ->
      output_string oc default);
  let st, p = call "settings/inbox_agent" in
  Alcotest.(check int) "the default" 200 st;
  Alcotest.(check string) "its text" default (s "text" p);
  (* ISS-65250: Settings says when the agent cannot run. *)
  let cannot_run () = member "cannot_run" (snd (call "settings/inbox_agent")) in
  Alcotest.(check bool) "the demo's read hook: runs" true (cannot_run () = `Null);
  Behaviors.unset_executable n.log Read;
  Alcotest.(check bool)
    "no read hook: cannot run" true
    (match cannot_run () with
    | `String m -> String.starts_with ~prefix:"No read hook" m
    | _ -> false);
  ok (Behaviors.set_executable n.log Read claude);
  Alcotest.(check bool) "a read hook: runs" true (cannot_run () = `Null);
  ignore (Store.Problems.report n.log ~job:"read_circle" ~kind:"failed" ());
  Alcotest.(check bool)
    "its last run failed" true
    (match cannot_run () with
    | `String m ->
        String.starts_with ~prefix:"The Inbox agent's last run failed" m
    | _ -> false);
  Store.Problems.resolve n.log ~job:"read_circle" ();
  Alcotest.(check bool) "a run that read" true (cannot_run () = `Null);
  Alcotest.(check bool)
    "is the default" true
    (member "is_default" p = `Bool true);
  Alcotest.(check (option string))
    "saved on the node" (Some default)
    (Log.get_config n.log "inbox_prompt");
  Alcotest.(check int)
    "an empty prompt" 422
    (fst
       (call ~meth:"PUT"
          ~body:(`Assoc [ ("text", `String "  ") ])
          "settings/inbox_agent"));
  let _, p =
    call ~meth:"PUT"
      ~body:(`Assoc [ ("text", `String "File work with gh.") ])
      "settings/inbox_agent"
  in
  Alcotest.(check bool) "edited" false (member "is_default" p = `Bool true);
  Alcotest.(check bool) "when" true (member "updated_at" p <> `Null);
  Alcotest.(check string) "the default beside it" default (s "default_text" p);
  Alcotest.(check string)
    "kept" "File work with gh."
    (s "text" (snd (call "settings/inbox_agent")));
  let _, p = call ~meth:"DELETE" "settings/inbox_agent" in
  Alcotest.(check bool) "reset" true (member "is_default" p = `Bool true);
  Alcotest.(check bool)
    "the default has no time" true
    (member "updated_at" p = `Null);
  (* A run over what Pia sent. *)
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let ben = join_peer n "Ben Ortiz" in
  let ben_id = Keys.public ben.p_identity in
  let q = peer_item n pia (question "Which fake clock do you use?") in
  let q2 = peer_item n pia (question "Where is the relay key?") in
  let q3 = peer_item n pia (question "What did you ship?") in
  let note =
    peer_write n pia "summary"
      (Content.summary_body ~text:"Shipped the loader." ~voice:"agent" ())
  in
  let run body = call ~meth:"POST" ~body "inbox_agent/runs" in
  (* ISS-65274: the credit to the idea's author, sent when the behavior says it may be. *)
  let credit title send =
    `Assoc
      [
        ("subject", `String "credit");
        ("members", `List [ `String pia_id ]);
        ("title", `String title);
        ("detail", `String "Back off retries, from your note.");
        ("about", `String note);
        ("send", `Bool send);
      ]
  in
  let st, r =
    run
      (`Assoc
         [
           ( "reviews",
             `List
               [
                 `Assoc
                   [
                     ("hash", `String q);
                     ("review", `String "Answered: lib-util's clock.");
                   ];
                 `Assoc
                   [
                     ("hash", `String note);
                     ("review", `String "Filed digestif-ai/digestif#12.");
                   ];
                 `Assoc
                   [ ("hash", `String "sha256:nope"); ("review", `String "") ];
               ] );
           ( "answers",
             `List
               [
                 `Assoc
                   [
                     ("item", `String q);
                     ("text", `String "The one in lib-util.");
                   ];
                 `Assoc
                   [
                     ("item", `String q2);
                     ("text", `String "It is at internal.example.com.");
                   ];
                 `Assoc
                   [
                     ("item", `String q3);
                     ("text", `String "The loader.");
                     ("send", `Bool false);
                   ];
               ] );
           ( "items",
             `List
               [
                 `Assoc
                   [
                     ("subject", `String "intro");
                     ("members", `List [ `String pia_id; `String ben_id ]);
                     ("title", `String "Pia, meet Ben");
                     ("about", `String note);
                   ];
                 `Assoc
                   [
                     ("subject", `String "work");
                     ("title", `String "Review Pia's loader");
                     ("detail", `String "She asked in her note.");
                     ("about", `String note);
                   ];
                 `Assoc
                   [
                     ("subject", `String "behavior");
                     ("circle", `Bool true);
                     ("title", `String "Share the eval harness?");
                   ];
                 `Assoc
                   [ ("subject", `String "join"); ("title", `String "Admit?") ];
                 credit "Filed: digestif-ai/digestif#12" true;
                 credit "Filed: digestif-ai/digestif#13" false;
                 credit "Filed: https://internal.example.com/issues/1" true;
                 `Assoc
                   [
                     ("subject", `String "credit");
                     ("circle", `Bool true);
                     ("title", `String "Filed: digestif-ai/digestif#14");
                     ("about", `String note);
                     ("send", `Bool true);
                   ];
               ] );
         ])
  in
  Alcotest.(check int) "recorded" 200 st;
  Alcotest.(check int) "two reviewed" 2 (int_of "reviewed" r);
  Alcotest.(check int)
    "the unknown message, the join and the credit to the circle named" 3
    (List.length (list (member "problems" r)));
  let outcome item =
    s "outcome"
      (List.find (fun a -> s "item" a = item) (list (member "answers" r)))
  in
  Alcotest.(check (list string))
    "sent, refused by the deny layer and kept, past the brief and kept"
    [ "sent"; "kept"; "kept" ]
    [ outcome q; outcome q2; outcome q3 ];
  Alcotest.(check int)
    "one answer on the wire, in the agent's voice" 1
    (envelopes_of n "item_answer");
  let _, qi = call ("items/" ^ q) in
  Alcotest.(check string)
    "Reviewed" "Answered: lib-util's clock." (s "review" qi);
  Alcotest.(check bool) "with its time" true (member "reviewed_at" qi <> `Null);
  Alcotest.(check string)
    "the agent's answer" "agent"
    (s "voice" (List.hd (list (member "answers" qi))));
  let _, q2i = call ("items/" ^ q2) in
  Alcotest.(check string)
    "a review does not make it Read" "new" (s "status" q2i);
  Alcotest.(check string)
    "the refused answer waits for the member" "It is at internal.example.com."
    (s "text" (member "agent_answer" q2i));
  let _, q3i = call ("items/" ^ q3) in
  Alcotest.(check bool)
    "no reason on one the agent kept" true
    (member "reason" (member "agent_answer" q3i) = `Null);
  let feed = list (snd (call "feed")) in
  let fn = List.find (fun f -> s "hash" f = note) feed in
  Alcotest.(check string)
    "the note's review in the Feed" "Filed digestif-ai/digestif#12."
    (s "review" fn);
  let _, p = call "settings/inbox_agent" in
  (* Two this run reviewed, and the demo's review of Ben's note. *)
  Alcotest.(check int) "three reviewed in all" 3 (int_of "reviewed" p);
  Alcotest.(check bool) "and when" true (member "last_reviewed_at" p <> `Null);
  let written = list (member "items" r) in
  let by_subject sub = List.find (fun i -> s "subject" i = sub) written in
  let by_title t = List.find (fun i -> s "title" i = t) written in
  Alcotest.(check int) "six written" 6 (List.length written);
  Alcotest.(check (list string))
    "a credit the behavior may send is sent; one past the brief, or one the \
     deny layer refuses, waits for the member as a draft"
    [ "sent"; "draft"; "draft" ]
    (List.map
       (fun t ->
         let st = s "status" (by_title t) in
         if st = "draft" then "draft" else "sent")
       [
         "Filed: digestif-ai/digestif#12";
         "Filed: digestif-ai/digestif#13";
         "Filed: https://internal.example.com/issues/1";
       ]);
  let credit = by_title "Filed: digestif-ai/digestif#12" in
  Alcotest.(check string)
    "to the idea's author alone" pia_id
    (s "identity" (List.hd (list (member "members" (member "to" credit)))));
  Alcotest.(check string)
    "the intro is a draft" "draft"
    (s "status" (by_subject "intro"));
  Alcotest.(check string)
    "the behavior is a draft" "draft"
    (s "status" (by_subject "behavior"));
  let work = by_subject "work" in
  Alcotest.(check string) "work is sent" "read" (s "status" work);
  (* ISS-85464: the Inbox row names the note it came from, which is its thread. *)
  Alcotest.(check string)
    "about the note, on its Inbox row" note (s "about" work);
  Alcotest.(check string)
    "to the member alone" me
    (s "identity" (List.hd (list (member "members" (member "to" work)))));
  let _, b = call ("items/" ^ s "id" (by_subject "behavior")) in
  Alcotest.(check (list string))
    "Install or Not now" [ "install"; "not_now" ]
    (List.map (s "id") (list (member "options" b)));
  Alcotest.(check string) "Not now by default" "not_now" (s "default_option" b);
  (* Nothing is sent in the member's name while they are Paused: the answer waits for them. *)
  Store.Stages.set n.log "paused";
  let q4 = peer_item n pia (question "Coffee?") in
  let _, r =
    run
      (`Assoc
         [
           ("reviews", `List []);
           ( "answers",
             `List [ `Assoc [ ("item", `String q4); ("text", `String "Yes.") ] ]
           );
         ])
  in
  Alcotest.(check string)
    "kept while Paused" "kept"
    (s "outcome" (List.hd (list (member "answers" r))));
  Alcotest.(check int) "still one on the wire" 1 (envelopes_of n "item_answer")

(* ISS-80159: a practice the reading run saw working for another member's agent. Offered to the
   member as a notice while adopting is off; adopted into their practices, with a notice saying so,
   once they turn it on. The node reads its author from the message it names, never the run, and
   refuses the member's own message, a link and a repeat. The member removes one on Settings. *)
let inbox_practices () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let prompts =
    Filename.concat (Filename.concat n.dir "good") "behaviors/prompts"
  in
  Node.mkdir_p prompts;
  Out_channel.with_open_bin (Filename.concat prompts "inbox.md") (fun oc ->
      output_string oc "Read what reaches me.\n");
  let _, p = call "settings/inbox_agent" in
  Alcotest.(check bool)
    "off by default" true
    (member "adopt_practices" p = `Bool false);
  Alcotest.(check int)
    "none adopted" 0
    (List.length (list (member "practices" p)));
  let pia = join_peer n "Pia Gale" in
  let note =
    peer_write n pia "summary"
      (Content.summary_body
         ~text:"My agent answers a scheduling question with two times."
         ~voice:"agent" ())
  in
  let own_hash, _ =
    ok
      (Node.write n ~kind:"summary"
         (Content.summary_body ~text:"My own way." ~voice:"agent" ()))
  in
  let practice ?(about = note) text =
    `Assoc [ ("text", `String text); ("about", `String about) ]
  in
  let run ps =
    let st, r =
      call ~meth:"POST"
        ~body:(`Assoc [ ("reviews", `List []); ("practices", `List ps) ])
        "inbox_agent/runs"
    in
    Alcotest.(check int) "recorded" 200 st;
    r
  in
  let two = "Answer a scheduling question with two times\nthat suit me." in
  let r = run [ practice two ] in
  Alcotest.(check int)
    "off: nothing adopted" 0
    (List.length (list (member "adopted" r)));
  let offered = List.hd (list (member "items" r)) in
  Alcotest.(check string) "a practice notice" "practice" (s "subject" offered);
  Alcotest.(check string)
    "offering it, on one line, naming who"
    "A practice you could adopt, from Pia Gale: Answer a scheduling question \
     with two times that suit me."
    (s "title" offered);
  Alcotest.(check string)
    "to the member alone" me
    (s "identity" (List.hd (list (member "members" (member "to" offered)))));
  Alcotest.(check int)
    "still none adopted" 0
    (List.length
       (list (member "practices" (snd (call "settings/inbox_agent")))));
  let _, p =
    call ~meth:"PUT"
      ~body:
        (`Assoc
           [
             ("text", `String "Read what reaches me.");
             ("adopt_practices", `Bool true);
           ])
      "settings/inbox_agent"
  in
  Alcotest.(check bool)
    "turned on" true
    (member "adopt_practices" p = `Bool true);
  let r =
    run
      [
        practice two;
        practice "Answer a scheduling question with two  times that suit me.";
        practice "Read https://example.com/rules first.";
        practice ~about:own_hash "Keep my own way.";
        practice ~about:"sha256:nope" "From nowhere.";
        practice "";
      ]
  in
  Alcotest.(check (list string))
    "the first adopted"
    [ "Answer a scheduling question with two times that suit me." ]
    (List.map (function `String t -> t | _ -> "") (list (member "adopted" r)));
  Alcotest.(check int)
    "the repeat, the link, the member's own, the unknown and the empty refused"
    5
    (List.length (list (member "problems" r)));
  let adopted = List.hd (list (member "items" r)) in
  Alcotest.(check string)
    "the notice says so"
    "Adopted a practice from Pia Gale: Answer a scheduling question with two \
     times that suit me."
    (s "title" adopted);
  let _, p = call "settings/inbox_agent" in
  let ps = list (member "practices" p) in
  Alcotest.(check int) "one practice" 1 (List.length ps);
  let pr = List.hd ps in
  Alcotest.(check string)
    "its author, from the message"
    (Keys.public pia.p_identity)
    (s "identity" (member "author" pr));
  Alcotest.(check string) "the message it was seen in" note (s "about" pr);
  Alcotest.(check bool)
    "reset keeps the practices" true
    (let _, p = call ~meth:"DELETE" "settings/inbox_agent" in
     List.length (list (member "practices" p)) = 1);
  Alcotest.(check int)
    "an unknown practice" 404
    (fst (call ~meth:"DELETE" "settings/inbox_agent/practices/practice-nope"));
  let st, p =
    call ~meth:"DELETE" ("settings/inbox_agent/practices/" ^ s "id" pr)
  in
  Alcotest.(check int) "removed" 200 st;
  Alcotest.(check int) "none left" 0 (List.length (list (member "practices" p)))

(* ISS-85004: an idea adopted into how the member's agent works credits its author, as one filed as
   work does. The run's credit is held beside the line and sent only once the line is saved: at once
   with adopting on, on Adopt with it off; Not now, a lapsed offer, words already held and a full
   list send nothing. A line removed later retracts nothing. *)
let inbox_practice_credits () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let bin = tmpdir () in
  let claude = Filename.concat bin "claude" in
  Out_channel.with_open_bin claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o755;
  Log.set_config n.log Api.Agent.k_agent claude;
  let prompts =
    Filename.concat (Filename.concat n.dir "good") "behaviors/prompts"
  in
  Node.mkdir_p prompts;
  Out_channel.with_open_bin (Filename.concat prompts "inbox.md") (fun oc ->
      output_string oc "Read what reaches me.\n");
  ignore (call "settings/inbox_agent");
  let pia = join_peer n "Pia Gale" in
  let pia_id = Keys.public pia.p_identity in
  let note =
    peer_write n pia "summary"
      (Content.summary_body
         ~text:"My agent answers a scheduling question with two times."
         ~voice:"agent" ())
  in
  let practice ?(send = true) text =
    `Assoc
      [
        ("text", `String text);
        ("about", `String note);
        ( "credit",
          `Assoc
            [
              ("title", `String ("Ada is adopting your idea: " ^ text));
              ( "detail",
                `String "Taken into how their agent works, from your note." );
              ("send", `Bool send);
            ] );
      ]
  in
  let run ps =
    let st, r =
      call ~meth:"POST"
        ~body:(`Assoc [ ("reviews", `List []); ("practices", `List ps) ])
        "inbox_agent/runs"
    in
    Alcotest.(check int) "recorded" 200 st;
    r
  in
  (* Every credit the node holds: a sent one to another member is not in the member's Inbox. *)
  let credits () =
    Store.Items.page n.log ~now:(Unix.gettimeofday ()) ~limit:200 ()
    |> List.filter (fun (r : Store.Items.row) -> r.item.subject = Some "credit")
    |> List.map (fun (r : Store.Items.row) -> snd (call ("items/" ^ r.id)))
  in
  let held () =
    List.length (list (member "practices" (snd (call "settings/inbox_agent"))))
  in
  let pick id option =
    call ~meth:"POST"
      ~body:(`Assoc [ ("option_id", `String option) ])
      ("items/" ^ id ^ "/picks")
  in
  let offers () = Log.get_config n.log Api.Inbox_agent.k_offers in
  (* Adopting off: an offer of Adopt or Not now, naming the author and the credit; nothing sent. *)
  let r = run [ practice "Answer with two times." ] in
  let offered = List.hd (list (member "items" r)) in
  let _, o = call ("items/" ^ s "id" offered) in
  Alcotest.(check string) "a choice" "choice" (s "kind" o);
  Alcotest.(check string) "the node's" "node" (s "voice" o);
  Alcotest.(check (list string))
    "Adopt or Not now" [ "adopt"; "not_now" ]
    (List.map (s "id") (list (member "options" o)));
  Alcotest.(check string) "Not now by default" "not_now" (s "default_option" o);
  Alcotest.(check bool) "a week to pick" true (member "deadline_at" o <> `Null);
  Alcotest.(check string)
    "names the author and the credit"
    "Adopt this from Pia Gale? Adopting also tells Pia Gale their idea is in \
     how your agent works."
    (s "detail" o);
  Alcotest.(check int) "no credit yet" 0 (List.length (credits ()));
  (* Not now: nothing saved, the credit dropped. *)
  Alcotest.(check int)
    "Not now picked" 201
    (fst (pick (s "id" offered) "not_now"));
  Alcotest.(check int) "nothing adopted" 0 (held ());
  Alcotest.(check int) "no credit on Not now" 0 (List.length (credits ()));
  Alcotest.(check bool) "the offer dropped" true (offers () = None);
  (* A lapsed offer: dropped at the next run, with nothing sent. *)
  let r = run [ practice "Remember who asked what." ] in
  let lapsing = s "id" (List.hd (list (member "items" r))) in
  Store.Items.set_closed n.log lapsing ~closed:false
    ~closes_unix:(Some (Unix.gettimeofday () -. 1.0));
  ignore (run []);
  Alcotest.(check bool) "the lapsed offer dropped" true (offers () = None);
  Alcotest.(check int) "no credit on a lapse" 0 (List.length (credits ()));
  (* Adopt, with a credit past the brief: the line saved and the credit kept as a draft. *)
  let r = run [ practice ~send:false "Draft replies, never send them." ] in
  let offered = List.hd (list (member "items" r)) in
  let _, o = call ("items/" ^ s "id" offered) in
  Alcotest.(check string)
    "says the credit is the member's draft"
    "Adopt this from Pia Gale? Adopting also keeps a credit to Pia Gale as \
     your draft to send."
    (s "detail" o);
  Alcotest.(check int) "Adopt picked" 201 (fst (pick (s "id" offered) "adopt"));
  Alcotest.(check int) "adopted on Adopt" 1 (held ());
  (match credits () with
  | [ cr ] ->
      Alcotest.(check string) "kept as a draft" "draft" (s "status" cr);
      Alcotest.(check string)
        "to the author" pia_id
        (s "identity" (List.hd (list (member "members" (member "to" cr)))));
      let _, cr = call ("items/" ^ s "id" cr) in
      Alcotest.(check string)
        "adopted into how the agent works" "as_how_agent_works" (s "adopted" cr)
  | l -> Alcotest.failf "one credit, not %d" (List.length l));
  (* Words already held: no offer and no credit. *)
  let r = run [ practice "Draft  replies, never send them." ] in
  Alcotest.(check int)
    "no offer for held words" 0
    (List.length (list (member "items" r)));
  Alcotest.(check int)
    "refused as held" 1
    (List.length (list (member "problems" r)));
  (* Adopt with a credit within the brief: sent at once. *)
  let r = run [ practice "Keep answers to two lines." ] in
  let offered = s "id" (List.hd (list (member "items" r))) in
  Alcotest.(check int) "Adopt" 201 (fst (pick offered "adopt"));
  Alcotest.(check int) "two adopted" 2 (held ());
  let sent = List.filter (fun i -> s "status" i <> "draft") (credits ()) in
  Alcotest.(check int) "the credit sent" 1 (List.length sent);
  Alcotest.(check bool)
    "on the wire" true
    (member "hash" (List.hd sent) <> `Null);
  (* A full list: an offer's Adopt is refused, and sends nothing until a line is removed. *)
  let fill k =
    Log.set_config n.log Api.Inbox_agent.k_practices
      (Yojson.Safe.to_string
         (`List
            (List.init k (fun i ->
                 `Assoc
                   [
                     ("id", `String (Printf.sprintf "practice-%d" i));
                     ("text", `String (Printf.sprintf "Line %d." i));
                     ("author", `String pia_id);
                     ("about", `String note);
                     ("adopted_at", `String "2026-11-13T00:00:00Z");
                   ]))))
  in
  fill Api.Inbox_agent.max_practices;
  let before = List.length (credits ()) in
  let r = run [ practice "Say when you are unsure." ] in
  let offered = s "id" (List.hd (list (member "items" r))) in
  let st, e = pick offered "adopt" in
  Alcotest.(check int) "Adopt refused while full" 422 st;
  Alcotest.(check string)
    "saying what to do" "practices_full"
    (s "code" (List.hd (list e)));
  Alcotest.(check int)
    "nothing sent while full" before
    (List.length (credits ()));
  ignore (call ~meth:"DELETE" "settings/inbox_agent/practices/practice-0");
  Alcotest.(check int)
    "Adopt once there is room" 201
    (fst (pick offered "adopt"));
  Alcotest.(check int) "and its credit" (before + 1) (List.length (credits ()));
  (* Adopting on: the credit goes at once; a full list adopts and sends nothing. *)
  let _, _ =
    call ~meth:"PUT"
      ~body:
        (`Assoc
           [
             ("text", `String "Read what reaches me.");
             ("adopt_practices", `Bool true);
           ])
      "settings/inbox_agent"
  in
  let before = List.length (credits ()) in
  let r = run [ practice "Name the next step." ] in
  Alcotest.(check int)
    "full: nothing adopted" 0
    (List.length (list (member "adopted" r)));
  Alcotest.(check int) "full: nothing sent" before (List.length (credits ()));
  fill 3;
  let r = run [ practice "Name the next step." ] in
  Alcotest.(check (list string))
    "adopted by the run" [ "Name the next step." ]
    (List.map (function `String t -> t | _ -> "") (list (member "adopted" r)));
  let cr =
    List.find (fun i -> s "subject" i = "credit") (list (member "items" r))
  in
  Alcotest.(check bool) "sent at once" true (s "status" cr <> "draft");
  (* A line removed later: the credit already sent stands. *)
  let _, p = call "settings/inbox_agent" in
  let last = List.nth (list (member "practices" p)) 3 in
  ignore (call ~meth:"DELETE" ("settings/inbox_agent/practices/" ^ s "id" last));
  Alcotest.(check bool)
    "nothing retracted" true
    (List.exists (fun i -> s "id" i = s "id" cr) (credits ()));
  (* DIG-307: several lines one run saves from one message are one credit to its author, naming
     each line; sent only when every line's own credit would have been, else one draft. *)
  fill 0;
  let run_credits r =
    List.filter (fun i -> s "subject" i = "credit") (list (member "items" r))
  in
  let before = List.length (credits ()) in
  let r =
    run
      [
        practice "Lead with the answer.";
        practice "Name who asked.";
        practice "Close with the next step.";
      ]
  in
  Alcotest.(check int)
    "three adopted" 3
    (List.length (list (member "adopted" r)));
  (match run_credits r with
  | [ cr ] ->
      let _, cr = call ("items/" ^ s "id" cr) in
      Alcotest.(check string)
        "one credit counting them" "Ada Park is adopting 3 of your ideas"
        (s "title" cr);
      Alcotest.(check string)
        "each line in the detail"
        "Taken into how their agent works, from your note:\n\
         - Lead with the answer.\n\
         - Name who asked.\n\
         - Close with the next step."
        (s "detail" cr);
      Alcotest.(check bool) "sent at once" true (s "status" cr <> "draft");
      Alcotest.(check string)
        "adopted into how the agent works" "as_how_agent_works" (s "adopted" cr)
  | l -> Alcotest.failf "one credit, not %d" (List.length l));
  Alcotest.(check int) "one credit held" (before + 1) (List.length (credits ()));
  (* DIG-309: and one notice to the member, counting them, each line in its detail. *)
  (match
     List.filter (fun i -> s "subject" i = "practice") (list (member "items" r))
   with
  | [ nt ] ->
      let _, nt = call ("items/" ^ s "id" nt) in
      Alcotest.(check string)
        "one notice counting them" "Adopted 3 of Pia Gale's practices"
        (s "title" nt);
      Alcotest.(check string)
        "each line in the notice"
        "- Lead with the answer.\n\
         - Name who asked.\n\
         - Close with the next step.\n\
         Your Inbox agent works these ways from its next run. Settings, Inbox \
         agent lists them, where you remove them."
        (s "detail" nt)
  | l -> Alcotest.failf "one practice notice, not %d" (List.length l));
  (* One line past the brief: the one credit is a draft. *)
  let r =
    run
      [
        practice "Quote the question back.";
        practice ~send:false "Sign as the agent.";
      ]
  in
  match run_credits r with
  | [ cr ] ->
      Alcotest.(check string)
        "counting both" "Ada Park is adopting 2 of your ideas" (s "title" cr);
      Alcotest.(check string) "kept as a draft" "draft" (s "status" cr)
  | l -> Alcotest.failf "one draft credit, not %d" (List.length l)

(* ISS-71225: a notice from the node clears itself, settled as resolved, once what it told of no
   longer holds: the note it told of approved or dismissed, the problem resolved. A notice for a
   note still waiting stays. The Inbox reads several statuses at once. *)
(* ISS-74093: the page a node's notice points at is the member's own node's alone, typed at the
   node's own address, and a notice raised before it carried a line reads the line its subject
   fixes. *)
let inbox_notice_page () =
  let n = demo () in
  let call_as = call in
  let c = session n in
  let call = call n c in
  let me = Option.get (Log.get_config n.log Node.k_identity) in
  let my_key = Keys.encryption_public (Result.get_ok (Node.encryption_key n)) in
  let item id = snd (call ("items/" ^ enc id)) in
  let older =
    Result.get_ok
      (Api.Inbox.raise_notice (Api.ctx_of n) ~subject:"note_ready"
         ~title:"A note waits for you to approve on your machine." ())
  in
  Alcotest.(check string)
    "an older notice reads its subject's line"
    "Read the note and approve it, edit it or dismiss it."
    (s "detail" (item older));
  Alcotest.(check string) "its page" "/feed" (s "path" (item older));
  Alcotest.(check bool)
    "no address before the node names its own" true
    (member "address" (item older) = `Null);
  Log.set_config n.log Api.k_ui_url "http://127.0.0.1:7070";
  (* The node at 7070 reads its own cookie (DIG-275), so the browser opens it again. *)
  let call = call_as n (session n) in
  let item id = snd (call ("items/" ^ enc id)) in
  Alcotest.(check string)
    "the address carries the node's own port" "http://127.0.0.1:7070/feed"
    (s "address" (item older));
  let pia = join_peer n "Pia Gale" in
  let forged =
    peer_item n pia
      ~to_:(`Members ([ me ], [ raw_key my_key ]))
      {
        (question "A note waits for you to approve on your machine.") with
        kind = "notice";
        subject = Some "note_ready";
        voice = "node";
      }
  in
  let r = item forged in
  Alcotest.(check string) "a peer's node notice shows" "notice" (s "kind" r);
  Alcotest.(check bool)
    "with no page on this machine" true
    (member "path" r = `Null);
  Alcotest.(check bool) "and no address" true (member "address" r = `Null);
  Alcotest.(check string) "and no line of ours" "" (s "detail" r)

(* ISS-81607 (docs/design.md, Folder access): the folders macOS keeps behind Full Disk Access,
   tried with an injected opendir. A refused folder with a session project under it is one local
   notice from the node, raised once, settled once the folder lists again and raised again on a new
   refusal; one with no project under it raises nothing; and nothing that leaves the machine (an
   envelope for the relay, the digest's Inbox part or its lines) names the folder. *)
let folder_access_notice () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module F = Folder_access in
  let module L = Digest_lines in
  Log.exec log "DELETE FROM ui_problems" [];
  Store.Stages.set log "active";
  let home = "/Users/fda-member" in
  let documents = Filename.concat home "Documents"
  and desktop = Filename.concat home "Desktop" in
  (* The chosen Claude Code source: one project under ~/Documents, none under ~/Desktop. *)
  let projects = tmpdir () in
  List.iter
    (fun name -> Unix.mkdir (Filename.concat projects name) 0o700)
    [
      Sources.encode_segment (Filename.concat documents "secret-plans");
      Sources.encode_segment (Filename.concat home "code/app");
      Sources.encode_segment (home ^ "/Desktopper");
    ];
  Store.set_offered log
    [ { (Sources.claude_source [ projects ]) with selected = true } ];
  (* The probe: a folder in [refusing] is refused at its open, every other one lists [projects]. *)
  let refusing = ref [ documents; desktop ] in
  let opened = ref [] and reads = ref 0 in
  let probe : F.probe =
    {
      opendir =
        (fun d ->
          opened := d :: !opened;
          if List.mem d !refusing then
            raise (Unix.Unix_error (Unix.EPERM, "opendir", d))
          else Unix.opendir projects);
      readdir =
        (fun h ->
          incr reads;
          Unix.readdir h);
      closedir = Unix.closedir;
    }
  in
  let real = Unix.gettimeofday () in
  let now = ref real in
  let pass () =
    F.check_if_due ~probe ~home log ~now:!now;
    L.raise_notices n ~now:!now;
    now := !now +. (2. *. 86400.)
  in
  let node_items () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "subject" i = "folder_access")
  in
  let open_ () =
    List.filter (fun i -> member "done" i = `Null) (node_items ())
  in
  (* Unit: a refusal with a project under it, and none with no project under it. *)
  Alcotest.(check (list (pair string int)))
    "only the refused folder holding a project"
    [ (documents, 1) ]
    (F.check ~probe ~home ~names:(F.session_project_names log) ());
  Alcotest.(check bool)
    "a folder with no project under it is never tried" false
    (List.mem desktop !opened);
  Alcotest.(check (list (pair string int)))
    "a folder that lists is not refused" []
    (F.check
       ~probe:{ probe with opendir = (fun _ -> Unix.opendir projects) }
       ~home
       ~names:(F.session_project_names log)
       ());
  Alcotest.(check bool)
    "a refusal at the read counts too" true
    (F.refused
       {
         probe with
         opendir = (fun _ -> Unix.opendir projects);
         readdir =
           (fun _ -> raise (Unix.Unix_error (Unix.EACCES, "readdir", "")));
       }
       documents);
  reads := 0;
  ignore
    (F.refused { probe with opendir = (fun _ -> Unix.opendir projects) } home);
  Alcotest.(check int) "one readdir, never a walk" 1 !reads;
  Alcotest.(check bool)
    "a folder that is not there is not refused" false
    (F.refused
       {
         probe with
         opendir =
           (fun d -> raise (Unix.Unix_error (Unix.ENOENT, "opendir", d)));
       }
       documents);
  (* The notice: raised once on the first pass after a start. *)
  F.checked_since_start := false;
  pass ();
  let first =
    match open_ () with
    | [ i ] -> i
    | l -> Alcotest.failf "one notice, got %d" (List.length l)
  in
  Alcotest.(check string)
    "it names the folder"
    (Printf.sprintf
       "Digestif cannot open %s, where 1 of your session projects is" documents)
    (s "title" first);
  Alcotest.(check bool)
    "and the step" true
    (contains
       (s "detail" (snd (call ("items/" ^ enc (s "id" first)))))
       "Privacy and Security, Full Disk Access");
  Alcotest.(check bool)
    "local" true
    (member "local" (snd (call ("items/" ^ enc (s "id" first)))) = `Bool true);
  Alcotest.(check bool)
    "the Desktop raises nothing" false
    (List.exists (fun i -> contains (s "title" i) "Desktop") (node_items ()));
  (* Nothing that leaves the machine names the folder. *)
  let digest = Log.transaction log (fun () -> L.machine n ~now:!now) in
  let entries =
    List.map
      (fun e -> Yojson.Safe.to_string (Digestif_mail.Digest.entry_json e []))
      digest.inbox
  in
  Alcotest.(check bool)
    "the digest counts it" true
    (List.exists
       (fun e -> contains e "Digestif cannot read some of your sessions")
       entries);
  List.iter
    (fun t ->
      Alcotest.(check bool)
        "the digest never names the folder" false
        (contains t "Documents" || contains t "secret-plans"))
    (entries @ digest.lines);
  List.iter
    (fun row ->
      match row with
      | [| e; b |] ->
          let t = Log.text e ^ Option.value (Log.text_opt b) ~default:"" in
          Alcotest.(check bool)
            "no envelope for the relay names the folder" false
            (contains t "Documents" || contains t "fda-member")
      | _ -> ())
    (Log.rows log "SELECT envelope, body FROM envelopes" []);
  (* Unchanged: no second notice, on a restart or a day later. *)
  F.checked_since_start := false;
  pass ();
  pass ();
  Alcotest.(check int) "raised once" 1 (List.length (node_items ()));
  (* Access back: settled by itself. *)
  refusing := [];
  pass ();
  Alcotest.(check (list string))
    "settled once it lists" []
    (List.map (s "id") (open_ ()));
  Alcotest.(check string)
    "as resolved" "resolved"
    (s "done" (snd (call ("items/" ^ enc (s "id" first)))));
  pass ();
  Alcotest.(check int)
    "nothing new while it lists" 1
    (List.length (node_items ()));
  (* A new refusal: raised again. *)
  refusing := [ documents ];
  pass ();
  Alcotest.(check int) "raised again" 1 (List.length (open_ ()));
  Alcotest.(check int) "a second notice" 2 (List.length (node_items ()));
  (* While a refusal stands it is tried within the hour, not the next day. *)
  Alcotest.(check bool)
    "due within the hour" true
    (F.due log ~now:(!now -. (2. *. 86400.) +. 3601.));
  (* Shared with ISS-81609: a reading's no access at or under a folder this check tells of is not a
     second item; any other folder it skipped still is. *)
  let skipped_open () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i ->
        s "subject" i = "skipped_projects" && member "done" i = `Null)
  in
  Skipped.record log
    {
      Skipped.projects = 1;
      folders =
        [ (Filename.concat documents "secret-plans", Skipped.No_access) ];
    };
  L.raise_notices n ~now:!now;
  Alcotest.(check int)
    "a refused folder is one item" 0
    (List.length (skipped_open ()));
  Skipped.record log
    {
      Skipped.projects = 2;
      folders =
        [ (documents, Skipped.No_access); ("/srv/huge", Skipped.Too_many) ];
    };
  L.raise_notices n ~now:!now;
  (match skipped_open () with
  | [ i ] ->
      let d = s "detail" (snd (call ("items/" ^ enc (s "id" i)))) in
      Alcotest.(check bool)
        "the other folder told" true (contains d "/srv/huge");
      Alcotest.(check bool)
        "the refused one left to its own notice" false (contains d "Documents")
  | l -> Alcotest.failf "one skipped notice, got %d" (List.length l));
  (* A member who reads no sessions has nothing a refusal could skip. *)
  Log.exec log "UPDATE ui_sources SET selected = 0" [];
  Alcotest.(check (list (pair string int)))
    "no chosen sessions, no notice" []
    (F.check ~probe ~home ~names:(F.session_project_names log) ())

let inbox_node_notices_clear () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module L = Digest_lines in
  let module N = Store.Notes in
  let real = Unix.gettimeofday () in
  Log.exec log "DELETE FROM ui_problems" [];
  Store.Stages.set log "active";
  L.raise_notices n ~now:real;
  let node_items () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "voice" i = "node")
  in
  let known = List.map (s "id") (node_items ()) in
  let raised subject =
    List.find
      (fun i -> s "subject" i = subject && not (List.mem (s "id" i) known))
      (node_items ())
  in
  let item id = snd (call ("items/" ^ enc id)) in
  let waiting_ids () = List.map (fun (w : N.note) -> w.n_id) (N.waiting log) in
  let added text =
    let before = waiting_ids () in
    ignore (N.add log ~status:"waiting" text);
    List.find (fun id -> not (List.mem id before)) (waiting_ids ())
  in
  let first = added "Worked on: the clearing." in
  L.raise_notices n ~now:real;
  let one = s "id" (raised "note_ready") in
  let known = one :: known in
  let second = added "Worked on: the second." in
  L.raise_notices n ~now:real;
  let two =
    List.find
      (fun i -> s "subject" i = "note_ready" && not (List.mem (s "id" i) known))
      (node_items ())
    |> s "id"
  in
  Alcotest.(check string)
    "New while its note waits" "new"
    (s "status" (item one));
  Alcotest.(check string) "it carries its page" "/feed" (s "path" (item one));
  Alcotest.(check string)
    "and what to do there"
    "Read the note and approve it, edit it or dismiss it."
    (s "detail" (item one));
  Alcotest.(check bool) "dismissed" true (N.dismiss log ~note_id:first);
  L.raise_notices n ~now:real;
  Alcotest.(check string)
    "Read once its note is dismissed" "read"
    (s "status" (item one));
  Alcotest.(check string) "as resolved" "resolved" (s "done" (item one));
  Alcotest.(check string)
    "the other note still waits" "new"
    (s "status" (item two));
  ignore (N.dismiss log ~note_id:second);
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 1.))
       ~job:"rules_check" ~kind:"model_unavailable" ());
  L.raise_notices n ~now:real;
  Alcotest.(check string) "its note dismissed" "resolved" (s "done" (item two));
  let failed = s "id" (raised "could_not_run") in
  Alcotest.(check string)
    "New while the problem is open" "new"
    (s "status" (item failed));
  Alcotest.(check string) "could not run: page" "/feed" (s "path" (item failed));
  Alcotest.(check string)
    "could not run: what to do" "Open it to see why Digestif could not run."
    (s "detail" (item failed));
  Store.Problems.resolve log ~job:"rules_check" ();
  L.raise_notices n ~now:real;
  Alcotest.(check string)
    "settled once it is resolved" "resolved"
    (s "done" (item failed));
  (* Every status, in one page. *)
  let st, open_ = call "items?limit=200&status=draft&status=new&status=read" in
  Alcotest.(check int) "several statuses" 200 st;
  Alcotest.(check bool)
    "the cleared notice stays, read" true
    (List.exists
       (fun i -> s "id" i = failed && s "status" i = "read")
       (list open_));
  let st, _ = call "items?limit=200&status=new&status=gone" in
  Alcotest.(check int) "an unknown one refused" 422 st

(* ISS-81609: the projects a reading skipped are one local notice from the node: its title a count,
   its detail each folder and why, told once while the same folders are skipped for the same
   reasons, New again for a folder not told before, settled by itself once a reading skips nothing.
   Nothing of it is signed, and the digest carries its title alone. *)
(* ISS-85467: a failed run of the Inbox agent is a notice from the node, one a failure streak: in
   the member's words, with the error the run reported and the log as its page, local, its words
   following the newest failure, and settled once the next run succeeds. *)
let inbox_agent_failed_notice () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module L = Digest_lines in
  let real = Unix.gettimeofday () in
  Log.exec log "DELETE FROM ui_problems" [];
  Store.Stages.set log "active";
  L.raise_notices n ~now:real;
  let failed () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "subject" i = "inbox_agent_failed")
  in
  Alcotest.(check int) "no failure, no notice" 0 (List.length (failed ()));
  ignore
    (Store.Problems.report log ~job:"read_circle" ~kind:"model_unavailable"
       ~detail:"The agent's answer could not be used: the answer is not JSON."
       ());
  L.raise_notices n ~now:real;
  let id =
    match failed () with
    | [ i ] -> s "id" i
    | l -> Alcotest.failf "one notice, got %d" (List.length l)
  in
  let item () = snd (call ("items/" ^ enc id)) in
  Alcotest.(check string) "New" "new" (s "status" (item ()));
  Alcotest.(check string)
    "in plain words" "Your Inbox agent's last run failed."
    (s "title" (item ()));
  Alcotest.(check bool)
    "with the error" true
    (contains (s "detail" (item ())) "the answer is not JSON");
  Alcotest.(check string)
    "its page is the log" "/settings/inbox-agent/log"
    (s "path" (item ()));
  Alcotest.(check bool)
    "local: never signed" true
    (match
       Log.rows log "SELECT local FROM ui_items WHERE id = ?" [ Log.s id ]
     with
    | [ [| l |] ] -> Log.int l = 1
    | _ -> false);
  (* The same streak, failing again and another way: the one notice, saying the newest. *)
  ignore
    (Store.Problems.report log ~job:"read_circle" ~kind:"model_unavailable" ());
  ignore
    (Store.Problems.report log ~job:"read_circle" ~kind:"signed_out"
       ~detail:"The agent gave no answer (signed_out)." ());
  L.raise_notices n ~now:real;
  Alcotest.(check int) "one notice a streak" 1 (List.length (failed ()));
  Alcotest.(check bool)
    "its words follow the newest failure" true
    (contains (s "detail" (item ())) "signed out");
  (* Settings says it too, and the log page reads behaviors/read.log. *)
  Alcotest.(check bool)
    "Settings: the error" true
    (contains
       (s "cannot_run" (snd (call "settings/inbox_agent/log")))
       "last run failed");
  (* The next run succeeds: the streak is over and the notice settled. *)
  Store.Problems.resolve log ~job:"read_circle" ();
  L.raise_notices n ~now:real;
  Alcotest.(check string) "settled" "resolved" (s "done" (item ()));
  ignore (Store.Problems.report log ~job:"read_circle" ~kind:"failed" ());
  L.raise_notices n ~now:real;
  Alcotest.(check int)
    "a new streak, a new notice" 1
    (List.length (List.filter (fun i -> member "done" i = `Null) (failed ())))

(* ISS-85467: Settings, Inbox agent, Log: the read behavior's log, its last lines, oldest first. *)
let inbox_agent_log () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let lines () =
    List.map
      (function `String l -> l | _ -> "")
      (list (member "lines" (snd (call "settings/inbox_agent/log"))))
  in
  Alcotest.(check (list string)) "no log yet" [] (lines ());
  let dir = Filename.concat n.Node.dir "behaviors" in
  Node.mkdir_p dir;
  Out_channel.with_open_bin (Filename.concat dir "read.log") (fun oc ->
      for i = 1 to 250 do
        Printf.fprintf oc "line %d\n" i
      done);
  let got = lines () in
  Alcotest.(check int) "its last 200 lines" 200 (List.length got);
  Alcotest.(check string) "oldest first" "line 51" (List.hd got);
  Alcotest.(check string) "to the newest" "line 250" (List.nth got 199)

let inbox_skipped_projects () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module L = Digest_lines in
  let real = Unix.gettimeofday () in
  let docs = Filename.concat (Sources.home ()) "Documents/ledger-books" in
  let big = "/srv/huge-archive" in
  let envelopes () =
    match Log.rows log "SELECT COUNT(*) FROM envelopes" [] with
    | [ [| x |] ] -> Log.int x
    | _ -> -1
  in
  let skipped () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "subject" i = "skipped_projects")
  in
  let item id = snd (call ("items/" ^ enc id)) in
  let reading projects folders =
    Skipped.record log { Skipped.projects; folders };
    L.raise_notices n ~now:real
  in
  L.raise_notices n ~now:real;
  let before = envelopes () in
  reading 2 [ (docs, Skipped.No_access); (big, Skipped.Too_many) ];
  let id =
    match skipped () with
    | [ i ] -> s "id" i
    | l -> Alcotest.failf "one notice, not %d" (List.length l)
  in
  let r = item id in
  Alcotest.(check string) "New" "new" (s "status" r);
  Alcotest.(check string)
    "its title a count"
    "2 projects were not read: Digestif could not look at a folder they are in."
    (s "title" r);
  let detail = s "detail" r in
  Alcotest.(check bool)
    "the folder and why" true
    (contains detail "~/Documents/ledger-books: no access.");
  Alcotest.(check bool)
    "with the step for no access" true
    (contains detail
       (Skipped.why ~macos:(Keystore.is_macos ()) Skipped.No_access));
  Alcotest.(check bool)
    "too many entries" true
    (contains detail "/srv/huge-archive: too many entries");
  Alcotest.(check bool) "local" true (member "local" r = `Bool true);
  Alcotest.(check int) "nothing signed" before (envelopes ());
  Alcotest.(check bool)
    "no Ask your agent: nothing of it reaches an agent" true
    (member "path" r = `Null);
  (* The digest: the notice's title, a count, and no folder anywhere in it. *)
  let m = L.machine n ~now:real in
  let mailed =
    m.lines
    @ List.concat_map
        (fun (e : Digestif_mail.Digest.entry) -> [ e.title; e.line ])
        m.inbox
  in
  Alcotest.(check bool)
    "the digest carries the notice" true
    (List.exists
       (fun (e : Digestif_mail.Digest.entry) ->
         e.subject = Some "skipped_projects")
       m.inbox);
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("the digest names no " ^ needle)
        false
        (List.exists (fun l -> contains l needle) mailed))
    [ "Documents"; "ledger-books"; "huge-archive"; "no access" ];
  Alcotest.(check int) "still nothing signed" before (envelopes ());
  (* The same folders for the same reasons on the next reading: told once. *)
  Store.Items.read log id ~at:(Time_fmt.of_unix real);
  reading 2 [ (big, Skipped.Too_many); (docs, Skipped.No_access) ];
  Alcotest.(check int) "still one notice" 1 (List.length (skipped ()));
  Alcotest.(check string) "and not New again" "read" (s "status" (item id));
  (* A folder that clears drops out of its words, and is not news. *)
  reading 1 [ (docs, Skipped.No_access) ];
  Alcotest.(check string) "read still" "read" (s "status" (item id));
  Alcotest.(check bool)
    "the cleared folder dropped" false
    (contains (s "detail" (item id)) "huge-archive");
  Alcotest.(check string)
    "counted anew"
    "1 project was not read: Digestif could not look at a folder it is in."
    (s "title" (item id));
  (* A folder not told before makes it New again. *)
  reading 2 [ (docs, Skipped.No_access); (big, Skipped.Too_long) ];
  Alcotest.(check int) "the same notice" 1 (List.length (skipped ()));
  Alcotest.(check string) "New again" "new" (s "status" (item id));
  Alcotest.(check bool)
    "with the new reason" true
    (contains (s "detail" (item id)) "huge-archive: took too long to list.");
  (* The member settles it: the same skips do not bring it back. *)
  Store.Items.settle log id ~why:"done" ~at:(Time_fmt.of_unix real);
  reading 2 [ (docs, Skipped.No_access); (big, Skipped.Too_long) ];
  Alcotest.(check int)
    "not raised again" 0
    (List.length (List.filter (fun i -> member "done" i = `Null) (skipped ())));
  (* A reading that skips nothing: settled by itself. *)
  reading 1 [ (docs, Skipped.Could_not_read) ];
  let again =
    match
      List.filter
        (fun i -> s "status" i = "new" && member "done" i = `Null)
        (skipped ())
    with
    | [ i ] -> s "id" i
    | l -> Alcotest.failf "a new reason is told: %d" (List.length l)
  in
  reading 0 [];
  Alcotest.(check string)
    "settled once a reading skips nothing" "resolved"
    (s "done" (item again));
  Alcotest.(check int) "and nothing signed, ever" before (envelopes ())

(* ISS-81609: what `digestif skipped report` is handed, read back the way it was written. *)
let skipped_json () =
  let t =
    {
      Skipped.projects = 3;
      folders = [ ("/a", Skipped.No_access); ("/b", Skipped.Too_many) ];
    }
  in
  Alcotest.(check bool)
    "round trip" true
    (Skipped.of_json (Skipped.to_json t) = Ok t);
  Alcotest.(check bool)
    "an unknown reason is a folder that could not be read" true
    (Skipped.of_json
       (Yojson.Safe.from_string
          {|{"projects":1,"folders":[{"folder":"/c","reason":"cosmic_rays"}]}|})
    = Ok { Skipped.projects = 1; folders = [ ("/c", Skipped.Could_not_read) ] }
    );
  Alcotest.(check bool)
    "a clean reading" true
    (Skipped.of_json (Yojson.Safe.from_string {|{"projects":0}|})
    = Ok Skipped.none);
  Alcotest.(check bool)
    "a negative count refused" true
    (Result.is_error
       (Skipped.of_json (Yojson.Safe.from_string {|{"projects":-1}|})))

(* ISS-71859: the rest of what clears a notice from the node. Repositories clear once the ones
   it counted are decided, read against the range it stored, the empty start on a fresh node
   included. A pause warning stays open once the pause lands. A notice raised before what it told
   of was kept clears from the state now. Settling uses the pass's own time and drops what the
   notice told of. *)
let inbox_node_notices_settle () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module L = Digest_lines in
  let module N = Store.Notes in
  let module P = Store.Pause in
  let real = Unix.gettimeofday () in
  let day = 86400. in
  Log.exec log "DELETE FROM ui_problems" [];
  Log.exec log "UPDATE ui_repositories SET status = 'approved'" [];
  List.iter
    (fun (w : N.note) -> ignore (N.dismiss log ~note_id:w.n_id))
    (N.waiting log);
  Log.unset_config log "ui_unpaused_at";
  Store.Stages.set log "active";
  L.raise_notices n ~now:real;
  let node_items () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "voice" i = "node")
  in
  let known = ref (List.map (s "id") (node_items ())) in
  let raised subject =
    let id =
      List.find
        (fun i -> s "subject" i = subject && not (List.mem (s "id" i) !known))
        (node_items ())
      |> s "id"
    in
    known := id :: !known;
    id
  in
  let item id = snd (call ("items/" ^ enc id)) in
  let about id = Log.get_config log ("digest_notice_about:" ^ id) in
  let status what want id =
    Alcotest.(check string) what want (s "status" (item id))
  in
  let resolved what id =
    Alcotest.(check string) what "resolved" (s "done" (item id));
    Alcotest.(check (option string))
      (what ^ ": what it told of dropped")
      None (about id)
  in
  let undecided id at =
    Log.exec log
      "INSERT INTO ui_repositories (id, organization_id, name, status, \
       found_at, paths) VALUES (?, 'acme-labs', ?, 'undecided', ?, '[]')"
      Log.[ s id; s ("prototype-" ^ id); s (Time_fmt.of_unix at) ]
  in
  let decide id =
    Log.exec log "UPDATE ui_repositories SET status = 'approved' WHERE id = ?"
      [ Log.s id ]
  in
  (* Repositories, from nothing told: the range starts empty. *)
  Log.unset_config log L.k_repositories;
  undecided "f1" (real -. 60.);
  L.raise_notices n ~now:real;
  let first = raised "repositories" in
  Alcotest.(check string)
    "repositories: page" "/settings/repositories/edit"
    (s "path" (item first));
  Alcotest.(check string)
    "repositories: what to do"
    "Decide whether Digestif may read it. Nothing is read until you say so."
    (s "detail" (item first));
  Alcotest.(check (option string))
    "the range starts empty"
    (Some ("|" ^ Time_fmt.of_unix (real -. 60.)))
    (about first);
  L.raise_notices n ~now:real;
  status "New while it waits undecided" "new" first;
  decide "f1";
  L.raise_notices n ~now:(real +. 7.);
  resolved "settled once decided" first;
  Alcotest.(check (option string))
    "at the pass's own time"
    (Some (Time_fmt.of_unix (real +. 7.)))
    (match
       Log.rows log "SELECT done_at FROM ui_items WHERE id = ?" [ Log.s first ]
     with
    | [ [| d |] ] -> Log.text_opt d
    | _ -> None);
  (* A later one, counted after the last told: one found before that range is not its own. *)
  undecided "f2" (real -. 30.);
  L.raise_notices n ~now:real;
  let second = raised "repositories" in
  undecided "f0" (real -. 90.);
  L.raise_notices n ~now:real;
  status "New while the one it counted waits" "new" second;
  decide "f2";
  L.raise_notices n ~now:real;
  resolved "settled once the one in its range is decided" second;
  decide "f0";
  (* A pause warning stays once the pause lands. *)
  let added text =
    let before = List.map (fun (w : N.note) -> w.n_id) (N.waiting log) in
    ignore (N.add log ~status:"waiting" text);
    List.find (fun (w : N.note) -> not (List.mem w.n_id before)) (N.waiting log)
  in
  let late = added "Worked on: the pause." in
  P.set_readable_at log ~note_id:late.n_id (real -. (28. *. day));
  L.raise_notices n ~now:real;
  let warned = raised "pause_coming" in
  Alcotest.(check string) "pause coming: page" "/feed" (s "path" (item warned));
  Alcotest.(check string)
    "pause coming: what to do"
    "Approve the waiting note before the pause, or Digestif pauses."
    (s "detail" (item warned));
  L.raise_notices n ~now:(real +. (1.5 *. day));
  status "New while the pause is coming" "new" warned;
  let later = real +. (2.5 *. day) in
  Alcotest.(check bool) "the 30 days run out" true (P.due log ~now:later <> None);
  Alcotest.(check bool)
    "paused" true
    (P.pause log ~now:later ~reason:"note_waited");
  L.raise_notices n ~now:later;
  status "New once the pause landed" "new" warned;
  Alcotest.(check bool) "unpaused" true (P.unpause log ~now:later);
  Log.unset_config log "ui_unpaused_at";
  ignore (N.dismiss log ~note_id:late.n_id);
  L.raise_notices n ~now:later;
  resolved "settled once its note no longer waits" warned;
  (* Notices raised before what they told of was kept. *)
  let legacy subject =
    let id = raised subject in
    Log.unset_config log ("digest_notice_about:" ^ id);
    L.raise_notices n ~now:real;
    status ("a " ^ subject ^ " raised without what it told of stays") "new" id;
    id
  in
  undecided "f3" (real -. 20.);
  L.raise_notices n ~now:real;
  let old_repositories = legacy "repositories" in
  decide "f3";
  L.raise_notices n ~now:real;
  resolved "an old repositories notice clears" old_repositories;
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 1.))
       ~job:"rules_check" ~kind:"model_unavailable" ());
  L.raise_notices n ~now:real;
  let old_failed = legacy "could_not_run" in
  Store.Problems.resolve log ~job:"rules_check" ();
  L.raise_notices n ~now:real;
  resolved "an old could-not-run notice clears" old_failed;
  let waits = added "Worked on: the old warning." in
  P.set_readable_at log ~note_id:waits.n_id (real -. (28. *. day));
  L.raise_notices n ~now:real;
  let old_pause = legacy "pause_coming" in
  ignore (N.dismiss log ~note_id:waits.n_id);
  L.raise_notices n ~now:real;
  resolved "an old pause warning clears" old_pause

(* ISS-52614: the node's own items and the digest's Inbox part. What the digest said On your
   machine is a notice from the node, New in the Inbox and sealed to the member alone, New
   repositories kept on the machine; the digest carries every Draft and New item with a page link,
   answer links or Acknowledge; an Acknowledge from the email settles the notice; and Your agent
   did is the review lines of what reached the member. *)
let inbox_node_items_and_digest () =
  let n = demo () in
  let log = n.Node.log in
  let c = session n in
  let call = call n c in
  let module L = Digest_lines in
  let real = Unix.gettimeofday () in
  let me = Option.get (Log.get_config log Node.k_identity) in
  Log.exec log "DELETE FROM ui_problems" [];
  Store.Stages.set log "active";
  L.raise_notices n ~now:real;
  let node_items () =
    list (snd (call "items?limit=200"))
    |> List.filter (fun i -> s "voice" i = "node")
  in
  let before = List.length (node_items ()) in
  Log.exec log
    "INSERT INTO ui_repositories (id, organization_id, name, status, found_at, \
     paths) VALUES ('r9', 'acme-labs', 'prototype-r9', 'undecided', ?, '[]')"
    [ Log.s (Time_fmt.of_unix (real -. 1.)) ];
  ignore
    (Store.Problems.report log
       ~at:(Time_fmt.of_unix (real -. 1.))
       ~job:"rules_check" ~kind:"model_unavailable" ());
  L.raise_notices n ~now:real;
  let raised = node_items () in
  Alcotest.(check int) "two notices raised" (before + 2) (List.length raised);
  let notice subject = List.find (fun i -> s "subject" i = subject) raised in
  let repos = notice "repositories" and failed = notice "could_not_run" in
  Alcotest.(check string) "a notice" "notice" (s "kind" failed);
  Alcotest.(check string) "New" "new" (s "status" failed);
  Alcotest.(check string)
    "its words are the digest line's"
    "Digestif could not run today. Open it on your machine to see why."
    (s "title" failed);
  let failed_id = s "id" failed in
  (match (Option.get (Log.find log failed_id)).signed with
  | { envelope = { kind = "item"; _ }; body = Some body } ->
      Alcotest.(check bool)
        "sealed, to the member alone" true
        (member "to" body = `List [ `String me ] && member "item" body = `Null)
  | _ -> Alcotest.fail "the notice is an item envelope");
  let st, r = call ("items/" ^ enc (s "id" repos)) in
  Alcotest.(check int) "the local one is in the Inbox" 200 st;
  Alcotest.(check bool)
    "kept on the machine" true
    (member "local" r = `Bool true && member "hash" r = `Null);
  L.raise_notices n ~now:real;
  Alcotest.(check int)
    "each raised once" (List.length raised)
    (List.length (node_items ()));
  (* The digest's Inbox part: Draft and New, each with what its reader does with it. *)
  let st, draft =
    call ~meth:"POST"
      ~body:
        (`Assoc
           [ ("kind", `String "question"); ("title", `String "Fake clocks?") ])
      "items"
  in
  Alcotest.(check int) "a draft" 201 st;
  let entries =
    Api.Inbox.digest_entries (Api.ctx_of n) ~page:(fun id -> "PAGE/" ^ id)
  in
  let entry id =
    List.find (fun (e : Digestif_mail.Digest.entry) -> e.item = id) entries
  in
  (match (entry (s "id" draft)).action with
  | Page { label = "Read the draft"; url } ->
      Alcotest.(check string) "its page" ("PAGE/" ^ s "id" draft) url
  | _ -> Alcotest.fail "a draft links to its page");
  (match (entry failed_id).action with
  | Acknowledge { keys = [ _ ] } -> ()
  | _ -> Alcotest.fail "a notice carries Acknowledge, sealed to the member");
  Alcotest.(check string)
    "from the node" "Notice from your node" (entry failed_id).line;
  (match (entry (s "id" repos)).action with
  | Page _ -> ()
  | _ -> Alcotest.fail "a local notice has no envelope to acknowledge");
  Alcotest.(check bool)
    "Read stays off it" false
    (List.exists
       (fun (e : Digestif_mail.Digest.entry) ->
         List.mem e.item
           (List.filter_map
              (fun i -> if s "status" i = "read" then Some (s "id" i) else None)
              (list (snd (call "items?limit=200")))))
       entries);
  (* An Acknowledge from the email is a decision under one of the member's keys. *)
  let enc_key = ok (Node.encryption_key n) in
  ignore
    (ok
       (Node.write n ~kind:"decision"
          (Digestif_mail.Ask.pick_body ~keys:[ enc_key.public ] ~item:failed_id
             ~option:Digestif_mail.Ask.acknowledge)));
  let _, f = call ("items/" ^ enc failed_id) in
  Alcotest.(check (pair string bool))
    "acknowledged from the email: read and archived" ("read", true)
    (s "status" f, member "archived_at" f <> `Null);
  Alcotest.(check string) "why" "acknowledged" (s "done" f);
  (* Your agent did: the review lines on what reached the member, never on their own. *)
  let pax = join_peer n "Pax Rowe" in
  let theirs = peer_item n pax (question "Which TLS stack on Fedora?") in
  let _, q = call ("items/" ^ enc theirs) in
  Alcotest.(check string) "their question is New" "new" (s "status" q);
  Alcotest.(check bool)
    "a question links to its page to be answered" true
    (match
       (List.find
          (fun (e : Digestif_mail.Digest.entry) -> e.item = theirs)
          (Api.Inbox.digest_entries (Api.ctx_of n) ~page:(fun id -> id)))
         .action
     with
    | Page { label = "Answer"; _ } -> true
    | _ -> false);
  Store.Items.set_review log theirs ~at:(Time_fmt.now ())
    ~review:(Some "remembered that his team holds out a vendor.");
  Store.Items.set_review log (s "id" draft) ~at:(Time_fmt.now ())
    ~review:(Some "an own item is never reviewed");
  (* ISS-52683: another member's note, by its envelope hash, ordered with the items by when the
     run reviewed it; the member's own note is never read. *)
  let pax_note =
    peer_write n pax "summary"
      (Content.summary_body ~text:"Shipped the loader." ~voice:"agent" ())
  in
  Store.Reviews.set log pax_note
    ~at:(Time_fmt.of_unix (real -. 60.))
    ~review:(Some "drafted the intro above.");
  let own_note =
    Node.write n ~kind:"summary"
      (Content.summary_body ~text:"My own note." ~voice:"agent" ())
  in
  Store.Reviews.set log
    (fst (ok own_note))
    ~at:(Time_fmt.now ()) ~review:(Some "an own note is never reviewed");
  let did = Api.Inbox.agent_did (Api.ctx_of n) ~since:None in
  Alcotest.(check (list string))
    "the review lines, on what reached the member alone, oldest first"
    [
      "Ben Ortiz's note: Filed the flaky clock tests as \
       digestif-ai/digestif#318, as your Inbox prompt says for work on \
       Digestif.";
      "Pax Rowe's note: drafted the intro above.";
      "Pax Rowe's question: remembered that his team holds out a vendor.";
    ]
    (List.map fst did);
  (* ISS-78222: each line links to what it reviewed, where the run's draft is read. *)
  Alcotest.(check (list string))
    "each line's page on this machine"
    [ "/feed/" ^ pax_note; "/inbox/" ^ theirs ]
    (List.tl (List.map snd did));
  Alcotest.(check (list string))
    "only since the last digest" []
    (List.map fst
       (Api.Inbox.agent_did (Api.ctx_of n)
          ~since:(Some (Time_fmt.of_unix (real +. 3600.)))))

(* ISS-86960: GET /search reads the full text the node holds, kind by kind, and keeps only what each
   list would show. *)
let search () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let pia = join_peer n "Pia Gale" in
  let groups q = snd (call ("search?q=" ^ enc q)) in
  let hits kind q = list (member kind (groups q)) in
  let hashes kind q = List.map (s "hash") (hits kind q) in
  (* A word deep in a note's body, past the line its preview shows. *)
  let long =
    "Worked on: the relay.\nLearned: "
    ^ String.concat " " (List.init 40 (fun _ -> "filler"))
    ^ " the zeppelin migration finally ran."
  in
  let h =
    peer_write n pia "summary"
      (Content.summary_body ~text:long ~voice:"agent" ())
  in
  Alcotest.(check bool)
    "the preview does not hold the word" false
    (contains
       (s "preview"
          (List.find (fun f -> s "hash" f = h) (list (snd (call "feed")))))
       "zeppelin");
  Alcotest.(check (list string))
    "a word in the body" [ h ] (hashes "feed" "zeppelin");
  Alcotest.(check bool)
    "the excerpt is where the word is" true
    (List.exists
       (fun e ->
         s "ref" e = h
         && String.starts_with ~prefix:"…" (s "text" e)
         && contains (s "text" e) "zeppelin migration")
       (list (member "excerpts" (groups "zepp"))));
  Alcotest.(check (list string)) "a word's start" [ h ] (hashes "feed" "zepp");
  Alcotest.(check (list string)) "in any case" [ h ] (hashes "feed" "ZEPPELIN");
  Alcotest.(check (list string))
    "every word is needed" []
    (hashes "feed" "zeppelin quinoa");
  Alcotest.(check (list string))
    "a quote in the query is punctuation, not syntax" [ h ]
    (hashes "feed" "zeppelin\" migr");
  (* A retracted message leaves the feed, and the search with it. *)
  let r = peer_write n pia "retract" (Bodies.make_retract ~target:h) in
  Log.drop_body n.log ~hash:h ~retracted_by:r;
  Alcotest.(check (list string)) "retracted" [] (hashes "feed" "zeppelin");
  (* An Inbox item by the words of its detail. *)
  let _ =
    peer_item n pia
      { (question "A quick one") with detail = "Which hovercraft vendor won?" }
  in
  Alcotest.(check (list string))
    "an item by its detail" [ "A quick one" ]
    (List.map (s "title") (hits "inbox" "hovercraft"));
  (* DIG-128: each hit says where it matched. *)
  let excerpt q ref_ =
    List.find_map
      (fun e -> if s "ref" e = ref_ then Some (s "text" e) else None)
      (list (member "excerpts" (groups q)))
  in
  let item_id = s "id" (List.hd (hits "inbox" "hovercraft")) in
  Alcotest.(check (option string))
    "an item's excerpt is its title and detail on one line"
    (Some "A quick one Which hovercraft vendor won?")
    (excerpt "hovercraft" item_id);
  (* The member's own note, in Notes and, waiting, in the feed. *)
  let id = ok (Api.submit_note_text n "Worked on: the quokka tracker.") in
  Alcotest.(check (list string))
    "a note" [ id ]
    (List.map (s "id") (hits "notes" "quokka"));
  Alcotest.(check (list string))
    "the waiting note in the feed" [ id ] (hashes "feed" "quokka");
  (* Members by name. *)
  Alcotest.(check (list string))
    "a member" [ "Pia Gale" ]
    (List.map (s "name") (hits "members" "pia"));
  (* Nothing asked is nothing found; a bad limit is named. *)
  List.iter
    (fun q ->
      List.iter
        (fun kind ->
          Alcotest.(check int)
            (kind ^ " for " ^ q)
            0
            (List.length (hits kind q)))
        [ "inbox"; "feed"; "notes"; "members" ])
    [ ""; "  "; "!!" ];
  Alcotest.(check int) "limit" 422 (fst (call "search?q=a&limit=0"));
  Alcotest.(check bool)
    "limit one" true
    (List.for_all
       (fun kind ->
         List.length (list (member kind (snd (call "search?q=a&limit=1")))) <= 1)
       [ "inbox"; "feed"; "notes"; "members" ]);
  (* A log the index has not seen is filled from its tables when the index is made. *)
  Log.unset_config n.log Store.Search.k_version;
  Store.Search.init n.log;
  Alcotest.(check (list string))
    "refilled" [ "A quick one" ]
    (List.map (s "title") (hits "inbox" "hovercraft"));
  Alcotest.(check (list string))
    "refilled notes" [ id ]
    (List.map (s "id") (hits "notes" "quokka"));
  Alcotest.(check (list string))
    "a retract stays out of a refill" [] (hashes "feed" "zeppelin")

(* DIG-238: the note queries a pass or a search runs read through an index, never a scan of every
   note or an index SQLite builds for one query. *)
let notes_query_plans () =
  let n = demo () in
  let plan sql params =
    List.map
      (fun r -> Log.text r.(3))
      (Log.rows n.log ("EXPLAIN QUERY PLAN " ^ sql) params)
  in
  let holds want lines = List.exists (fun l -> contains l want) lines in
  let search = plan Store.Search.notes_sql [ Log.s "quokka*"; Log.i 10 ] in
  Alcotest.(check bool)
    "the search builds no index" false (holds "AUTOMATIC" search);
  Alcotest.(check bool)
    "the search reads a version by its key" true
    (holds "SEARCH v USING INDEX sqlite_autoindex_ui_note_versions_1 (id=?)"
       search);
  List.iter
    (fun (name, cond) ->
      Alcotest.(check bool)
        (name ^ " reads through ui_notes_status")
        true
        (holds "USING INDEX ui_notes_status"
           (plan (Store.Notes.handed_over_sql cond) [])))
    [
      ("waiting", Store.Notes.waiting_cond); ("unsent", Store.Notes.unsent_cond);
    ]

(* DIG-128: a search hit's excerpt starts a little before the first word the query matches the
   start of, on one line, cut with an ellipsis. *)
let excerpt () =
  let check name want ~q text =
    Alcotest.(check string) name want (Excerpt.of_text ~q text)
  in
  check "short, whole" "Which hovercraft vendor won?" ~q:"hover"
    "Which hovercraft\nvendor won?";
  check "no match reads from the start" "abc def" ~q:"xyz" "abc def";
  let long = String.concat " " (List.init 30 (fun _ -> "filler")) in
  let got = Excerpt.of_text ~q:"ZEPP" (long ^ " the zeppelin ran " ^ long) in
  Alcotest.(check bool)
    "cut before, at a word" true
    (String.starts_with ~prefix:"…filler" got);
  Alcotest.(check bool) "holds the match" true (contains got "the zeppelin ran");
  Alcotest.(check bool) "cut after" true (String.ends_with ~suffix:"…" got);
  Alcotest.(check (list string))
    "words the search keeps" [ "a"; "b2" ]
    (Excerpt.words "  A !! b2 ")

let () =
  (* Hermetic: nothing reads the machine's own ~/.config/digestif/signer.json, whose release key
     would make the test node an admin (Signer_halt.own_key). *)
  Unix.putenv "XDG_CONFIG_HOME" (Filename.temp_dir "digestif-test-config" "");
  Ci_alcotest.run "web"
    [
      ( "server",
        [
          Alcotest.test_case "access" `Quick access;
          Alcotest.test_case "second node cookie" `Quick second_node_cookie;
          Alcotest.test_case "signers and the halt" `Quick signers_and_the_halt;
          Alcotest.test_case "deny layer" `Quick deny;
          Alcotest.test_case "deny list for the phone" `Quick deny_share;
          Alcotest.test_case "api" `Quick api;
          Alcotest.test_case "the Inbox: drafts and sending" `Quick
            inbox_drafts_and_sending;
          Alcotest.test_case "the Inbox: a read racing a send" `Quick
            inbox_send_raced_by_a_read;
          Alcotest.test_case "approvals" `Quick approvals;
          Alcotest.test_case "an item read leaves approval effects" `Quick
            item_read_leaves_approval_effects;
          Alcotest.test_case "the Inbox: delivery and statuses" `Quick
            inbox_delivery_and_statuses;
          Alcotest.test_case "the Inbox: replies, Waiting on and the clock"
            `Quick inbox_replies_waiting_and_the_clock;
          Alcotest.test_case "the Inbox: a reply is not a pick" `Quick
            inbox_reply_is_not_a_pick;
          Alcotest.test_case "search" `Quick search;
          Alcotest.test_case "search excerpt" `Quick excerpt;
          Alcotest.test_case "note query plans" `Quick notes_query_plans;
          Alcotest.test_case "the Inbox: a prompt suggestion" `Quick
            inbox_suggestion;
          Alcotest.test_case "the Inbox: no reply to self" `Quick
            inbox_no_reply_to_self;
          Alcotest.test_case "the Inbox: a closed question takes no answer"
            `Quick inbox_closed_question_takes_no_answer;
          Alcotest.test_case "the Inbox: a late answer reopens nothing" `Quick
            inbox_late_answer_reopens_nothing;
          Alcotest.test_case "the Inbox: late answer boundary and order" `Quick
            inbox_late_answer_boundary_and_order;
          Alcotest.test_case
            "the Inbox: an answer is refused at its signed time" `Quick
            inbox_answer_refused_at_its_signed_time;
          Alcotest.test_case "the Inbox: a follow-up's membership is the cutoff"
            `Quick inbox_follow_up_membership_is_the_cutoff;
          Alcotest.test_case
            "the Inbox: a revoke after the decision decides again" `Quick
            inbox_follow_up_revoke_after_decision;
          Alcotest.test_case "the Inbox: a fold change is narrowed to its keys"
            `Quick inbox_fold_change_is_narrowed;
          Alcotest.test_case "the Inbox: a follow-up before its admission"
            `Quick inbox_follow_up_before_its_admission;
          Alcotest.test_case
            "the Inbox: an item and an approval before their admission" `Quick
            item_and_approval_before_their_admission;
          Alcotest.test_case "the Inbox: a revoked own key does not count"
            `Quick inbox_follow_up_own_key_revoked;
          Alcotest.test_case "the Inbox: a bare upgrade decides every row"
            `Quick inbox_follow_up_bare_upgrade;
          Alcotest.test_case
            "the Inbox: a follow-up decided when its item arrives" `Quick
            inbox_follow_up_decided_when_the_item_arrives;
          Alcotest.test_case "the Inbox: a rule version bump recomputes" `Quick
            inbox_follow_up_rule_version_recomputes;
          Alcotest.test_case
            "the Inbox: every copy of the follow-up rule agrees" `Quick
            follow_up_agreement;
          Alcotest.test_case "the Inbox: a pick, a close and New, decided again"
            `Quick inbox_follow_up_decided_again;
          Alcotest.test_case "the Inbox: a late answer is not new activity"
            `Quick inbox_late_answer_is_not_new_activity;
          Alcotest.test_case "an item's own time is in the Z form" `Quick
            item_created_z_form;
          Alcotest.test_case "an item's deadline is in the Z form" `Quick
            item_deadline_z_form;
          Alcotest.test_case "the Inbox: a reply's about" `Quick
            inbox_reply_about;
          Alcotest.test_case "the Inbox agent" `Quick inbox_agent;
          Alcotest.test_case "the Inbox agent's source paragraph" `Quick
            inbox_agent_source;
          Alcotest.test_case "the Inbox agent's filed link" `Quick
            inbox_agent_link;
          Alcotest.test_case "a quote's paragraph" `Quick source_find;
          Alcotest.test_case "the Inbox agent: replies to notes" `Quick
            inbox_agent_note_replies;
          Alcotest.test_case "the Inbox agent: practices from the circle" `Quick
            inbox_practices;
          Alcotest.test_case
            "the Inbox agent: a practice's credit to its author" `Quick
            inbox_practice_credits;
          Alcotest.test_case "the note's Questions part" `Quick
            note_questions_parsed;
          Alcotest.test_case "the note's questions and their closer" `Quick
            note_questions_and_closer;
          Alcotest.test_case "the Inbox: the node's items and the digest" `Quick
            inbox_node_items_and_digest;
          Alcotest.test_case "the Inbox: the node's notices clear themselves"
            `Quick inbox_node_notices_clear;
          Alcotest.test_case "the Inbox: a failed Inbox agent run" `Quick
            inbox_agent_failed_notice;
          Alcotest.test_case "the Inbox agent's log" `Quick inbox_agent_log;
          Alcotest.test_case "the Inbox: the node checks folder access" `Quick
            folder_access_notice;
          Alcotest.test_case "the projects a reading skipped" `Quick
            inbox_skipped_projects;
          Alcotest.test_case "skipped report json" `Quick skipped_json;
          Alcotest.test_case "the Inbox: a node notice's page and line" `Quick
            inbox_notice_page;
          Alcotest.test_case "the Inbox: what else clears the node's notices"
            `Quick inbox_node_notices_settle;
          Alcotest.test_case "invited names" `Quick invited_names;
          Alcotest.test_case "demo reset" `Quick reset;
          Alcotest.test_case "demo new member" `Quick demo_new_member;
          Alcotest.test_case "phones" `Quick phones;
          Alcotest.test_case "stages and the clock" `Quick stages_and_clock;
          Alcotest.test_case "pause" `Quick pause;
          Alcotest.test_case "the Paused ask" `Quick paused_ask;
          Alcotest.test_case "the digest's lines without an ask" `Quick
            digest_lines;
          Alcotest.test_case "the Send invite notice" `Quick send_invite_notice;
          Alcotest.test_case "previews skip the note's headings" `Quick previews;
          Alcotest.test_case "the digest previews past the headings" `Quick
            digest_gist;
          Alcotest.test_case "the reader skips status notes" `Quick
            reader_skips_status_notes;
          Alcotest.test_case "note ticks" `Quick note_ticks;
          Alcotest.test_case "signing backstop" `Quick signing_backstop;
          Alcotest.test_case "note edit" `Quick note_edit;
          Alcotest.test_case "approval setting" `Quick approval_setting;
          Alcotest.test_case "note log" `Quick note_log;
          Alcotest.test_case "note log passages" `Quick note_log_passages;
          Alcotest.test_case "held reason column" `Quick held_reason_column;
          Alcotest.test_case "feed pages" `Quick feed_pages;
          Alcotest.test_case "threads and self by key" `Quick threads_by_key;
          Alcotest.test_case "reply_to backfill" `Quick reply_to_backfill;
          Alcotest.test_case "post deny layer" `Quick post_deny;
          Alcotest.test_case "quiet hours" `Quick quiet_hours_api;
          Alcotest.test_case "the problem record" `Quick problem_record;
          Alcotest.test_case "sync health" `Quick sync_health;
          Alcotest.test_case "the Inbox count is one per thread" `Quick
            inbox_count_threads;
          Alcotest.test_case "inbox: the index's watermark" `Quick
            inbox_index_mark;
          Alcotest.test_case "a check that cannot finish" `Quick
            check_could_not_finish;
          Alcotest.test_case "command sources" `Quick command_sources;
          Alcotest.test_case "session titles" `Quick session_titles;
          Alcotest.test_case "transcript head bounded" `Quick
            transcript_head_bounded;
          Alcotest.test_case "machine scan stored" `Quick machine_scan_stored;
          Alcotest.test_case "repository found by" `Quick repository_found_by;
          Alcotest.test_case "record start found" `Quick record_start_found;
          Alcotest.test_case "work run scan" `Quick work_run_scan;
          Alcotest.test_case "machine scan incremental" `Quick
            (cleaned machine_scan_incremental);
          Alcotest.test_case "machine scan holds no lock" `Quick
            machine_scan_holds_no_lock;
          Alcotest.test_case "sort keys backfilled" `Quick sort_keys_backfilled;
          Alcotest.test_case "machine scan read rescans" `Quick
            machine_scan_read_rescans;
          Alcotest.test_case "session titles skip financial projects" `Quick
            session_titles_skip_financial;
          Alcotest.test_case "session titles remember a financial project"
            `Quick session_titles_remember_financial;
          Alcotest.test_case "judging rules: temp roots, cap, give up" `Quick
            (cleaned judging_rules);
          Alcotest.test_case "judging: fails closed" `Quick
            (cleaned judging_fail_closed);
          Alcotest.test_case "judging: round three" `Quick
            (cleaned judging_round_three);
          Alcotest.test_case "judging: home under a temp root" `Quick
            (cleaned judging_home_under_temp);
          Alcotest.test_case "judging: the sessions corpus" `Quick
            (cleaned sessions_corpus);
          Alcotest.test_case "judging: a refusal keeps its reason" `Quick
            (cleaned judging_refusal_keeps_its_reason);
          Alcotest.test_case "machine scan: cannot judge" `Quick
            (cleaned machine_scan_cannot_judge);
          Alcotest.test_case "project dirs" `Quick (cleaned project_dirs);
          Alcotest.test_case "many repos" `Quick many_repos;
          Alcotest.test_case "brief draft" `Quick brief_draft;
          Alcotest.test_case "demo behaviors" `Quick demo_behaviors;
          Alcotest.test_case "member experience routes" `Quick
            member_experience_routes;
          Alcotest.test_case "setup chat" `Quick setup_chat;
          Alcotest.test_case "setup prompt" `Quick setup_prompt;
          Alcotest.test_case "first note states" `Quick first_note_states;
          Alcotest.test_case "first run: a node that created its circle" `Quick
            first_run_creator;
          Alcotest.test_case "first note emptied" `Quick first_note_emptied;
          Alcotest.test_case "remotes" `Quick remotes;
          Alcotest.test_case "repository choices" `Quick repository_choices;
          Alcotest.test_case "setup chat repositories" `Quick
            setup_chat_repositories;
          Alcotest.test_case "commit authors owned" `Quick commit_authors_owned;
          Alcotest.test_case "author proposal" `Quick author_proposal;
          Alcotest.test_case "author proposal bounded" `Quick
            author_proposal_bounded;
          Alcotest.test_case "author proposal off the request" `Quick
            author_proposal_off_request;
          Alcotest.test_case "repositories api" `Quick repositories_api;
          Alcotest.test_case "repositories raise no ask" `Quick
            repositories_raise_no_ask;
          Alcotest.test_case "list pages" `Quick list_pages;
          Alcotest.test_case "note time" `Quick note_time;
          Alcotest.test_case "digest settings" `Quick digest_settings;
          Alcotest.test_case "names" `Quick names;
          Alcotest.test_case "names: the first card" `Quick names_first_card;
          Alcotest.test_case "agent" `Quick agent;
          Alcotest.test_case "ask your agent" `Quick ask_agent;
          Alcotest.test_case "ask your agent: prompt and stop" `Quick
            ask_agent_prompt_and_stop;
          Alcotest.test_case "concurrent server" `Quick concurrent_server;
          Alcotest.test_case "a note on its message" `Quick note_on_its_message;
          Alcotest.test_case "the UI's bind waits for its port" `Quick
            bind_waits;
          Alcotest.test_case "serve: a log connection per request" `Quick
            serve_own_log;
          Alcotest.test_case "serve: reads answer while the log is held" `Quick
            reads_answer_while_log_is_held;
          Alcotest.test_case "concurrent passes sign a note once" `Quick
            send_once_under_concurrency;
          Alcotest.test_case "member review: the rules" `Quick
            member_review_rules;
          Alcotest.test_case "member review: Last note" `Quick
            last_note_counts_no_status_note;
          Alcotest.test_case "member review" `Quick (cleaned member_review);
          Alcotest.test_case "member review: an admin removes a member" `Quick
            (cleaned admin_removes_member);
          Alcotest.test_case "member review: a sitting admin is not removed"
            `Quick
            (cleaned admin_removal_refuses_sitting_admin);
          Alcotest.test_case "member review: the member's notice" `Quick
            member_review_notice;
          Alcotest.test_case "Members lists a revoked member" `Quick
            members_list_a_revoked_member;
          Alcotest.test_case "member review: the removed member's notice" `Quick
            member_review_removed_words;
          Alcotest.test_case "suggestion rounds" `Quick suggestion_rounds;
          Alcotest.test_case "a suggestion adopted" `Quick suggestion_flow;
          Alcotest.test_case "a suggestion with judges" `Quick suggestion_judges;
        ] );
      ( "behaviors",
        [
          Alcotest.test_case "nightly due" `Quick nightly_due;
          Alcotest.test_case "note time" `Quick note_time_setting;
          Alcotest.test_case "record points" `Quick record_points;
          Alcotest.test_case "note ends" `Quick note_ends;
          Alcotest.test_case "note revise" `Quick note_revise;
          Alcotest.test_case "install" `Quick behavior_install;
          Alcotest.test_case "spawn" `Quick behavior_spawn;
          Alcotest.test_case "deadline" `Quick behavior_deadline;
          Alcotest.test_case "exit watched" `Quick behavior_exit_watched;
          Alcotest.test_case "read left more" `Quick behavior_read_left_more;
          Alcotest.test_case "retry" `Quick behavior_retry;
          Alcotest.test_case "read settles its problem" `Quick
            behavior_read_settle;
          Alcotest.test_case "first note stopped" `Quick
            behavior_stopped_first_note;
          Alcotest.test_case "run now lapses" `Quick behavior_run_now_lapses;
          Alcotest.test_case "check" `Quick behavior_check;
          Alcotest.test_case "revise" `Quick behavior_revise;
        ] );
    ]
