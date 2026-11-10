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

let member name = function
  | `Assoc f -> (
      match List.assoc_opt name f with Some v -> v | None -> `Null)
  | _ -> `Null

let s name j = match member name j with `String v -> v | _ -> ""
let list = function `List l -> l | _ -> []

(* who may call *)

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
    "Done in the Inbox" "done"
    (s "status" (snd (call n c ("items/" ^ enc hash))));
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

(* A member with no card reads as the name their invite gave them, not as a key. *)
let invited_names () =
  let n = demo () in
  let c =
    {
      Api.node = n;
      fold = Node.fold n;
      now = Unix.gettimeofday ();
      on_write = ignore;
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
    String.sub cookie
      (String.length Server.cookie_name + 1)
      (String.length cookie - String.length Server.cookie_name - 1)
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
  (* Writing a note is the job's success: the problem closes. *)
  ignore (ok (Api.submit_note_text n "A note."));
  Alcotest.(check bool) "a written note closes it" true (failure () = None)

(* ISS-48141: the first note goes through the nightly's catch-up. Starting it reopens the nightly
   even when today's note was written, and it is due all of that day until a run handles it: a run
   the node's stopping ended is not a failed try, and the node's next pass runs it again. Its page
   says nothing is writing it rather than the step the run stopped at. *)
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

(* A project directory's name decodes to the paths it can name that exist. *)
let project_dirs () =
  let root = tmpdir () in
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
  let home = tmpdir () in
  let repo = Filename.concat home "Claude/Projects/fetcher" in
  Node.mkdir_p (Filename.concat repo ".git");
  Node.mkdir_p (Filename.concat home "Claude/Projects/notes");
  List.iter
    (fun p ->
      Node.mkdir_p
        (Filename.concat home
           (".claude/projects/"
           ^ Sources.encode_segment (Filename.concat home p))))
    [ "Claude/Projects/fetcher"; "Claude/Projects/notes"; "Claude/gone" ];
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  let repos =
    Fun.protect
      ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
      Sources.discover_repos
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
      Sources.discover_repos
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
let member_experience_routes () =
  let n = demo () in
  let c = session n in
  let not_built issue (meth, path, body) =
    let st, e = call n c ~meth ?body path in
    Alcotest.(check int) (meth ^ " " ^ path) 501 st;
    Alcotest.(check string)
      (meth ^ " " ^ path ^ " names its issue")
      ("Not built yet: " ^ issue ^ ".")
      (s "message" (List.hd (list e)))
  in
  ignore not_built;
  Alcotest.(check int)
    "ISS-52609's Inbox is built: an unknown item is not found" 404
    (fst (call n c "items/i1"));
  Alcotest.(check int)
    "ISS-52611's Inbox agent is built: a node with no agent has none" 404
    (fst (call n c "settings/inbox_agent"));
  Alcotest.(check int)
    "ISS-38782's Notes are built: an unknown note is not found" 404
    (fst (call n c "notes/n1"));
  Alcotest.(check int)
    "the approved notes are gone with the first five" 404
    (fst (call n c "approvals"));
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
  let home = tmpdir () in
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
  Node.mkdir_p (Filename.concat projects (Sources.encode_segment app));
  settle home;
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect
    ~finally:(fun () -> Option.iter (Unix.putenv "HOME") saved)
    (fun () ->
      let log = fresh_log () in
      let pass () = Option.get (Machine_scan.scan_stats ~now:1000. log) in
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

let serve_own_log () =
  let n = demo () in
  let fd = Result.get_ok (Server.start ~port:0 n) in
  let port =
    match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | _ -> 0
  in
  let token = Store.new_launch_token n.log in
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
        let i = index_of launched "digestif_session=" in
        let rest = String.sub launched i (String.length launched - i) in
        String.sub rest 0 (String.index rest ';')
      in
      let answers =
        List.map
          (fun target ->
            let r = ref "" in
            let t =
              Thread.create
                (fun () ->
                  r :=
                    raw_get
                      ~headers:[ ("Cookie", cookie); ("Digestif-Local", "1") ]
                      port target)
                ()
            in
            (t, r))
          [ "/api/v0/status"; "/api/v0/feed"; "/"; "/api/v0/members" ]
      in
      List.iter
        (fun (t, r) ->
          Thread.join t;
          Alcotest.(check bool) "answered 200" true (contains !r "200 OK"))
        answers)

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

let peer_write n p ?(created_at = Time_fmt.now ()) kind body =
  let sg =
    Envelope.create ~key:p.p_device ~seq:p.p_seq ?prev:p.p_prev ~created_at
      ~epoch:(Node.fold n).epoch ~kind body
  in
  let h = Envelope.hash sg.envelope in
  p.p_seq <- p.p_seq + 1;
  p.p_prev <- Some h;
  ignore (ok (Node.import n sg));
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
let peer_item n p ?created_at ?(to_ = `Circle) (item : Item.t) =
  let body =
    match to_ with
    | `Circle -> Item.item_body ~to_:Circle ~keys:[] item
    | `Members (ids, keys) ->
        Item.item_body ~to_:(Members ids) ~keys:(p.p_enc.public :: keys) item
  in
  peer_write n p ?created_at "item" body

let question ?(kind = "question") ?(options = []) ?default ?deadline title :
    Item.t =
  {
    kind;
    subject = None;
    voice = "agent";
    title;
    detail = "";
    about = None;
    options;
    default;
    deadline;
  }

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
  let inbox () = list (snd (call "items?kind=question")) in
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
  ignore
    (peer_write n pia "summary"
       (Content.summary_body ~text:"Short too." ~voice:"agent"
          ~prompt:(Suggestions.prompt_id pias_prompt)
          ~suggestion:theirs ()));
  let _, row = call ("items/" ^ theirs) in
  Alcotest.(check (pair bool string))
    "the round adopts it and closes the choice" (true, "done")
    (member "closed" row = `Bool true, s "status" row);
  let _, sg = call ("suggestions/" ^ theirs) in
  Alcotest.(check string) "adopted" "adopted" (s "status" sg)

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
    "done, answered" ("done", "answered")
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
  Alcotest.(check string)
    "Pia's answer" "Mine has room."
    (s "text" (List.hd (list (member "answers" r))));
  ignore (call ~meth:"POST" ("items/" ^ mine_id ^ "/read"));
  Alcotest.(check bool) "read, it stays in" true (listed mine_id);
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
    "done, picked, closed" ("done", "picked", true)
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
    "closed at its deadline" ("done", "closed")
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
       (fun i -> s "status" i = "done")
       (list (snd (call "items?status=done"))));
  ignore pia_id

(* ISS-52611: the Inbox agent. Every node with an agent saves the release's default prompt, which
   Settings edits and resets; a run's review lands on the items and notes it read, an answer goes
   out in the agent's voice only through the guards, and what speaks for the member is a draft. *)
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

(* ISS-71225: a notice from the node clears itself, Done as resolved, once what it told of no
   longer holds: the note it told of approved or dismissed, the problem resolved. A notice for a
   note still waiting stays. The Inbox reads several statuses at once. *)
(* ISS-74093: the page a node's notice points at is the member's own node's alone, typed at the
   node's own address, and a notice raised before it carried a line reads the line its subject
   fixes. *)
let inbox_notice_page () =
  let n = demo () in
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
    "Done once its note is dismissed" "done"
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
    "Done once it is resolved" "resolved"
    (s "done" (item failed));
  (* Every status but Done, in one page. *)
  let st, open_ = call "items?limit=200&status=draft&status=new&status=read" in
  Alcotest.(check int) "several statuses" 200 st;
  Alcotest.(check bool)
    "none Done" false
    (List.exists (fun i -> s "status" i = "done") (list open_));
  Alcotest.(check bool)
    "the cleared notice left out" false
    (List.exists (fun i -> s "id" i = failed) (list open_));
  let st, _ = call "items?limit=200&status=new&status=gone" in
  Alcotest.(check int) "an unknown one refused" 422 st

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
  resolved "Done once decided" first;
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
  resolved "Done once the one in its range is decided" second;
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
  resolved "Done once its note no longer waits" warned;
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
    "Read and Done stay off it" false
    (List.exists
       (fun (e : Digestif_mail.Digest.entry) ->
         List.mem e.item
           (List.filter_map
              (fun i ->
                if List.mem (s "status" i) [ "read"; "done" ] then
                  Some (s "id" i)
                else None)
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
  Alcotest.(check string) "acknowledged from the email" "done" (s "status" f);
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
    did;
  Alcotest.(check (list string))
    "only since the last digest" []
    (Api.Inbox.agent_did (Api.ctx_of n)
       ~since:(Some (Time_fmt.of_unix (real +. 3600.))))

let () =
  Ci_alcotest.run "web"
    [
      ( "server",
        [
          Alcotest.test_case "access" `Quick access;
          Alcotest.test_case "deny layer" `Quick deny;
          Alcotest.test_case "deny list for the phone" `Quick deny_share;
          Alcotest.test_case "api" `Quick api;
          Alcotest.test_case "the Inbox: drafts and sending" `Quick
            inbox_drafts_and_sending;
          Alcotest.test_case "the Inbox: a read racing a send" `Quick
            inbox_send_raced_by_a_read;
          Alcotest.test_case "the Inbox: delivery and statuses" `Quick
            inbox_delivery_and_statuses;
          Alcotest.test_case "the Inbox: a prompt suggestion" `Quick
            inbox_suggestion;
          Alcotest.test_case "the Inbox agent" `Quick inbox_agent;
          Alcotest.test_case "the note's Questions part" `Quick
            note_questions_parsed;
          Alcotest.test_case "the note's questions and their closer" `Quick
            note_questions_and_closer;
          Alcotest.test_case "the Inbox: the node's items and the digest" `Quick
            inbox_node_items_and_digest;
          Alcotest.test_case "the Inbox: the node's notices clear themselves"
            `Quick inbox_node_notices_clear;
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
          Alcotest.test_case "held reason column" `Quick held_reason_column;
          Alcotest.test_case "feed pages" `Quick feed_pages;
          Alcotest.test_case "reply_to backfill" `Quick reply_to_backfill;
          Alcotest.test_case "post deny layer" `Quick post_deny;
          Alcotest.test_case "quiet hours" `Quick quiet_hours_api;
          Alcotest.test_case "the problem record" `Quick problem_record;
          Alcotest.test_case "sync health" `Quick sync_health;
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
            machine_scan_incremental;
          Alcotest.test_case "machine scan holds no lock" `Quick
            machine_scan_holds_no_lock;
          Alcotest.test_case "sort keys backfilled" `Quick sort_keys_backfilled;
          Alcotest.test_case "machine scan read rescans" `Quick
            machine_scan_read_rescans;
          Alcotest.test_case "session titles skip financial projects" `Quick
            session_titles_skip_financial;
          Alcotest.test_case "session titles remember a financial project"
            `Quick session_titles_remember_financial;
          Alcotest.test_case "project dirs" `Quick project_dirs;
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
          Alcotest.test_case "repositories api" `Quick repositories_api;
          Alcotest.test_case "repositories raise no ask" `Quick
            repositories_raise_no_ask;
          Alcotest.test_case "list pages" `Quick list_pages;
          Alcotest.test_case "note time" `Quick note_time;
          Alcotest.test_case "digest settings" `Quick digest_settings;
          Alcotest.test_case "names" `Quick names;
          Alcotest.test_case "names: the first card" `Quick names_first_card;
          Alcotest.test_case "agent" `Quick agent;
          Alcotest.test_case "concurrent server" `Quick concurrent_server;
          Alcotest.test_case "a note on its message" `Quick note_on_its_message;
          Alcotest.test_case "the UI's bind waits for its port" `Quick
            bind_waits;
          Alcotest.test_case "serve: a log connection per request" `Quick
            serve_own_log;
          Alcotest.test_case "concurrent passes sign a note once" `Quick
            send_once_under_concurrency;
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
          Alcotest.test_case "install" `Quick behavior_install;
          Alcotest.test_case "spawn" `Quick behavior_spawn;
          Alcotest.test_case "deadline" `Quick behavior_deadline;
          Alcotest.test_case "retry" `Quick behavior_retry;
          Alcotest.test_case "first note stopped" `Quick
            behavior_stopped_first_note;
          Alcotest.test_case "check" `Quick behavior_check;
        ] );
    ]
