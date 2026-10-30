(* The localhost server: who may call it, the deny layer, and the API over a demo circle. *)

open Digestif_core
open Digestif_web

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
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

let deny () =
  let entry kind value : Store.deny_entry =
    { d_id = kind; d_kind = kind; value; created_at = ""; trips = 0 }
  in
  let check ?(allowed = []) entries text =
    match Deny.check ~entries ~allowed text with
    | Deny.Pass -> "pass"
    | Tripped { rule; _ } -> rule
  in
  Alcotest.(check string)
    "domain" "deny: domain"
    (check
       [ entry "domain" "internal.example.com" ]
       "see wiki.internal.example.com/x");
  Alcotest.(check string)
    "a name is a word" "pass"
    (check [ entry "name" "Ann" ] "Annual review");
  Alcotest.(check string)
    "a name" "deny: name"
    (check [ entry "name" "Acme Corp" ] "shipped for acme corp today");
  Alcotest.(check string)
    "a circle name is allowed" "pass"
    (check ~allowed:[ "Ben Ortiz" ]
       [ entry "name" "Ben Ortiz" ]
       "paired with Ben Ortiz");
  Alcotest.(check string)
    "a pattern" "deny: pattern"
    (check [ entry "pattern" "proj-[0-9]+" ] "PROJ-42 is late");
  Alcotest.(check string)
    "aws" "detector: Key and token shapes"
    (check [] "key AKIAABCDEFGHIJKLMNOP");
  Alcotest.(check string)
    "pem" "detector: Private keys"
    (check [] "-----BEGIN RSA PRIVATE KEY-----");
  Alcotest.(check string)
    "url" "detector: Connection strings"
    (check [] "postgres://app:hunter2@db:5432/x");
  Alcotest.(check string)
    "entropy" "detector: High-entropy strings"
    (check [] "token Zx9Qm2Lr7Tb4Wv8Ks1Hn6Pd3Gf5Jc0Ya2Xe");
  Alcotest.(check string)
    "a hash is not a secret" "pass"
    (check []
       "see \
        sha256:82255e8d0aa8276fbe441bc62d2fad5160ad22118ee94750ea3623d4be552674");
  Alcotest.(check bool)
    "a broken pattern" true
    (Result.is_error (Deny.compile_pattern "("))

(* the API over the demo circle *)

let api () =
  let n = demo () in
  let c = session n in
  let call = call n c in
  let st, status = call "status" in
  Alcotest.(check int) "status" 200 st;
  Alcotest.(check string) "member" "Ada Park" (s "member_name" status);
  Alcotest.(check bool) "first run" true (member "first_run" status = `Bool true);
  Alcotest.(check bool)
    "four to approve" true
    (member "approvals_required" status = `Int 4);
  let _, feed = call "feed" in
  let question = List.find (fun i -> s "kind" i = "question") (list feed) in
  Alcotest.(check string)
    "a sealed question opens for its recipient"
    "Has Ada tried a fake clock for timer tests? Ben is stuck on the same \
     thing."
    (s "preview" question);
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
  (* a reply to another member is an answer sealed to them and to us *)
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
  Alcotest.(check string) "answer" "answer" (s "kind" answer);
  Alcotest.(check string)
    "to Cy" "Cy Lund"
    (s "name" (member "recipient" answer));
  Alcotest.(check string)
    "we read our own" "Yes, a fake clock works." (s "text" answer);
  (match Log.find n.log (s "hash" answer) with
  | Some { signed = { body = Some b; _ }; _ } ->
      Alcotest.(check bool)
        "sealed on the wire" true
        (member "sealed" b <> `Null && member "text" b = `Null)
  | _ -> Alcotest.fail "answer not in the log");
  let _, q = call ("messages/" ^ enc (s "hash" question)) in
  Alcotest.(check int)
    "both replies are listed, the refused one too" 2
    (List.length (list (member "replies" q)));
  (* asks *)
  let _, asks = call "asks" in
  let open_ask = List.hd (list asks) in
  Alcotest.(check string) "open first" "open" (s "status" open_ask);
  Alcotest.(check string) "kind" "intro" (s "kind" open_ask);
  Alcotest.(check string) "from" "Cy Lund" (s "name" (member "from" open_ask));
  Alcotest.(check int)
    "unknown option" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "maybe") ])
          ("asks/" ^ s "id" open_ask ^ "/answers")));
  let st, a =
    call ~meth:"POST"
      ~body:(`Assoc [ ("option_id", `String "yes") ])
      ("asks/" ^ s "id" open_ask ^ "/answers")
  in
  Alcotest.(check int) "answered" 201 st;
  Alcotest.(check string) "status" "answered" (s "status" a);
  Alcotest.(check string) "the answer" "yes" (s "option_id" (member "answer" a));
  Alcotest.(check int)
    "not open" 422
    (fst
       (call ~meth:"POST"
          ~body:(`Assoc [ ("option_id", `String "no") ])
          ("asks/" ^ s "id" open_ask ^ "/answers")));
  Alcotest.(check int)
    "filter" 0
    (List.length (list (snd (call "asks?status=open"))));
  (* members *)
  let _, members = call "members" in
  let by name = List.find (fun m -> s "name" m = name) (list members) in
  Alcotest.(check string) "silent" "silent" (s "status" (by "Dee Rao"));
  Alcotest.(check string) "active" "active" (s "status" (by "Ben Ortiz"));
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
  (* dinners *)
  let _, dinners = call "dinners" in
  let d2 = List.hd (list dinners) in
  Alcotest.(check string) "newest first" "AI Dinner 2: autonomy" (s "label" d2);
  let _, d = call ("dinners/" ^ s "hash" d2) in
  let guest name =
    s "status"
      (List.find (fun g -> s "name" g = name) (list (member "guests" d)))
  in
  Alcotest.(check string) "invited" "invited" (guest "Eve Moss");
  Alcotest.(check string) "expired" "expired" (guest "Fay Kim");
  let d1 = List.nth (list dinners) 1 in
  Alcotest.(check bool) "joined" true (member "joined" d1 = `Int 3);
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
  let _, p =
    call ~meth:"POST"
      ~body:(`Assoc [ ("selected", `List [ `String "git" ]) ])
      "sources/preview"
  in
  Alcotest.(check bool)
    "extracts commit subjects" true
    (List.mem (`String "commit: Add a retry queue to the importer")
       (list (member "extracted" p)));
  Alcotest.(check bool) "drafts" true (contains (s "text" p) "Worked on");
  let _, p0 =
    call ~meth:"POST"
      ~body:(`Assoc [ ("selected", `List []) ])
      "sources/preview"
  in
  Alcotest.(check bool) "nothing chosen, no text" true (member "text" p0 = `Null);
  ignore
    (call ~meth:"PUT"
       ~body:(`Assoc [ ("selected", `List [ `String "git" ]) ])
       "sources");
  Alcotest.(check bool)
    "first run ends" true
    (member "first_run" (snd (call "status")) = `Bool false);
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
    "four detectors" 4
    (List.length (list (member "detectors" rules)));
  (* the first five *)
  let _, q = call "approvals" in
  let held = List.hd (list (member "notes" q)) in
  Alcotest.(check string) "awaiting first" "awaiting_approval" (s "status" held);
  let st, approved =
    call ~meth:"POST" ("approvals/" ^ s "hash" held ^ "/approve")
  in
  Alcotest.(check int) "approve" 200 st;
  Alcotest.(check string) "posted" "posted" (s "status" approved);
  Alcotest.(check bool)
    "signed as the agent" true
    (Log.find n.log (s "hash" approved) <> None);
  Alcotest.(check int)
    "twice" 422
    (fst (call ~meth:"POST" ("approvals/" ^ s "hash" held ^ "/approve")));
  Alcotest.(check string)
    "the held id still reads" "posted"
    (s "status" (snd (call ("approvals/" ^ s "hash" held))));
  Alcotest.(check bool)
    "two approved" true
    (member "approved" (snd (call "approvals")) = `Int 2);
  let id = ok (Api.submit_note_text n "Worked on: tests.") in
  let _, dropped = call ~meth:"POST" ("approvals/" ^ id ^ "/refuse") in
  Alcotest.(check string) "dropped" "retracted" (s "status" dropped);
  Alcotest.(check bool) "dropped text" true (member "text" dropped = `Null);
  Alcotest.(check int) "unknown" 404 (fst (call "approvals/sha256:00"))

(* Pairing a phone through the local API: 201 with the device row, 422 naming the wrong field, and
   the phrase never in an answer. *)
let phones () =
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  let phrase = Phrase.generate () in
  ok (Demo.seed ~phrase n);
  let c = session n in
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
    (List.mem (Keys.public phone) devices)

(* Why this node is silent, one reason at a time. Ada (this node) last posted 26 hours before the
   demo's now, so four days on she is silent. *)
let silence () =
  let n = demo () in
  let log = n.Node.log in
  let now = Unix.gettimeofday () +. (4. *. 86400.) in
  let ago h = Time_fmt.of_unix (now -. (h *. 3600.)) in
  let reason () =
    let c : Api.ctx =
      { node = n; fold = Node.fold n; now; on_write = (fun () -> ()) }
    in
    Option.value (Api.silence_reason c) ~default:"none"
  in
  let check name want = Alcotest.(check string) name want (reason ()) in
  Store.select_sources log [];
  check "no sources" "no_sources";
  Store.select_sources log
    (List.map (fun (x : Store.source) -> x.id) (Store.sources log));
  check "no tick at all" "asleep";
  Store.add_tick log ~at:(ago 40.) Store.Posted;
  check "no tick in a day and a half" "asleep";
  Store.add_tick log ~at:(ago 20.) Store.Harness_signed_out;
  Store.add_tick log ~at:(ago 2.) Store.Quiet;
  check "the harness signed out, then nothing to say" "harness_signed_out";
  Store.add_tick log ~at:(ago 1.) Store.Refused;
  check "the deny layer refused the note" "deny_refusing";
  Store.add_tick log ~at:(ago 0.5) Store.Posted;
  check "posted, and every relay accepting" "none";
  Log.add_relay log "https://relay-1.example";
  Log.record_sync log "https://relay-1.example" (Some "403 not admitted");
  check "a relay rejecting" "relay_rejecting";
  Store.select_sources log [];
  check "no sources wins" "no_sources"

(* `digestif note` records the run's tick: refused, held for approval, or posted. *)
let note_ticks () =
  let n = demo () in
  let log = n.Node.log in
  let outcomes () =
    List.map
      (fun (t : Store.tick) -> Store.tick_outcome_name t.outcome)
      (Store.ticks log ~limit:10)
  in
  ignore (ok (Api.submit_note_text n "Worked on: internal.example.com."));
  ignore (ok (Api.submit_note_text n "Worked on: the tick record."));
  Store.set_approved log Store.required_approvals;
  ignore (ok (Api.submit_note_text n "Worked on: the members page."));
  Alcotest.(check (list string))
    "newest first"
    [ "posted"; "held"; "refused" ]
    (outcomes ())

(* `digestif post` runs the deny layer on every content kind a behavior hands it, a sealed reply
   included, and refuses a sealed body it cannot open rather than signing it unchecked. *)
let post_deny () =
  let n = demo () in
  let log = n.Node.log in
  let fold = Node.fold n in
  let me = Option.get (Log.get_config log Node.k_identity) in
  let key id =
    let (k : Bodies.card), _ = Hashtbl.find fold.cards id in
    k.encryption_key
  in
  let other =
    Hashtbl.fold
      (fun id _ acc -> if id = me then acc else id :: acc)
      fold.cards []
    |> List.hd
  in
  let directed ?(self = key me) text =
    ok
      (Content.directed_body ~to_identity:other ~to_key:(key other)
         ~self_key:self ~text ~voice:"agent" ())
  in
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
  Alcotest.(check bool)
    "a clean sealed answer signs" true
    (signed (post "answer" (directed "A fake clock works.")));
  Alcotest.(check string)
    "a sealed answer that trips" "deny: domain"
    (refused (post "answer" (directed "see internal.example.com")));
  Alcotest.(check string)
    "a sealed question carrying a key" "detector: Key and token shapes"
    (refused (post "question" (directed "use sk-abcdefghijklmnopqrstuv")));
  Alcotest.(check string)
    "sealed to someone else, unreadable here" "deny: unreadable"
    (refused (post "proposal" (directed ~self:(key other) "anything")));
  let refusals = refused_rows () in
  Alcotest.(check int)
    "every refusal is kept" (before + 4) (List.length refusals);
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

(* A behavior records, in its own words, why a run handed over no note. *)
let silence_notes_api () =
  let n = demo () in
  let c = session n in
  let log = n.Node.log in
  let post text =
    call n c ~meth:"POST"
      ~body:(`Assoc [ ("text", `String text) ])
      "silence_notes"
  in
  let code (_, j) = s "code" (List.hd (list j)) in
  Alcotest.(check string) "empty" "empty" (code (post "  "));
  Alcotest.(check string)
    "too long" "too_long"
    (code (post (String.make 281 'x')));
  Alcotest.(check string)
    "the deny layer" "denied"
    (code (post "Blocked on internal.example.com."));
  let before = List.length (Store.ticks log ~limit:64) in
  let st, j = post "  The harness timed out after ten minutes.  " in
  Alcotest.(check int) "recorded" 201 st;
  Alcotest.(check string)
    "trimmed" "The harness timed out after ten minutes." (s "text" j);
  Alcotest.(check int)
    "a tick with it" (before + 1)
    (List.length (Store.ticks log ~limit:64));
  Alcotest.(check bool)
    "the run was quiet" true
    ((List.hd (Store.ticks log ~limit:1)).outcome = Store.Quiet);
  Alcotest.(check (list string))
    "listed"
    [ "The harness timed out after ten minutes." ]
    (List.map (s "text") (list (snd (call n c "silence_notes"))))

(* The digest's silence report: while silent, since when, the fixed reason and the notes; otherwise
   only the notes since the last digest. Ada last posted 26 hours before the demo's now. *)
let silence_report () =
  let n = demo () in
  let log = n.Node.log in
  let real = Unix.gettimeofday () in
  let report ~now ~since =
    Option.map
      (fun (sec : Digestif_mail.Digest.section) -> sec.lines)
      (Api.silence_section n ~now ~since)
  in
  Alcotest.(check bool)
    "nothing to say" true
    (report ~now:real ~since:None = None);
  Store.select_sources log [];
  ignore
    (Store.add_silence_note log
       ~at:(Time_fmt.of_unix (real -. 60.))
       "Nothing new since Friday.");
  (match report ~now:real ~since:None with
  | Some [ l ] ->
      Alcotest.(check bool)
        "the note, by the agent" true
        (contains l ": Nothing new since Friday.")
  | _ -> Alcotest.fail "one note line while posting");
  Alcotest.(check bool)
    "carried once" true
    (report ~now:real ~since:(Some (Time_fmt.of_unix real)) = None);
  match
    report ~now:(real +. (2.5 *. 86400.)) ~since:(Some (Time_fmt.of_unix real))
  with
  | Some (head :: reason :: notes) ->
      Alcotest.(check bool)
        "since when" true
        (contains head "has not posted since");
      Alcotest.(check bool)
        "the fixed reason" true
        (contains reason "No source is chosen");
      Alcotest.(check int) "the note again while silent" 1 (List.length notes)
  | _ -> Alcotest.fail "a silent node's report"

let reset () =
  let n = demo () in
  let c = session n in
  ignore
    (call n c ~meth:"PUT" ~body:(`Assoc [ ("selected", `List []) ]) "sources");
  let r =
    Server.handler
      ~reset:(fun () -> ok (Demo.seed n))
      n
      (request ~meth:"POST"
         ~headers:[ ("cookie", c); ("digestif-local", "1") ]
         "/api/v0/_reset")
  in
  Alcotest.(check int) "reset" 204 r.status;
  Alcotest.(check bool)
    "first run again, same session" true
    (member "first_run" (snd (call n c "status")) = `Bool true);
  Alcotest.(check int)
    "no reset outside a demo" 404
    (fst (call n c ~meth:"POST" "_reset"))

(* Behaviors: the nightly one is due once per local date after the fixed minute, and a spawned
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
  let due ?last_date ~day ~hour ~min () =
    Behaviors.nightly_due_at ~minute:17 ~last_date
      ~now:(local_time ~day ~hour ~min)
  in
  let check name want got = Alcotest.(check bool) name want got in
  check "before the minute" false (due ~day:29 ~hour:3 ~min:16 ());
  check "at the minute" true (due ~day:29 ~hour:3 ~min:17 ());
  check "before 3:00" false
    (due ~last_date:"2026-10-28" ~day:29 ~hour:1 ~min:0 ());
  check "a closed laptop wakes at noon" true
    (due ~last_date:"2026-10-28" ~day:29 ~hour:12 ~min:0 ());
  check "already ran today" false
    (due ~last_date:"2026-10-29" ~day:29 ~hour:23 ~min:59 ())

let script dir body =
  let p = Filename.concat dir "behavior.sh" in
  Out_channel.with_open_gen [ Open_creat; Open_trunc; Open_wronly ] 0o700 p
    (fun oc -> output_string oc ("#!/bin/sh\n" ^ body));
  p

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
  n

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
  let t =
    Behaviors.create ~digestif:"/bin/digestif" ~api_url:"http://127.0.0.1:7420"
      n
  in
  Alcotest.(check bool)
    "nothing new, no read behavior" true
    (Behaviors.after_pass ~now t ~stored:3 |> List.map fst = [ Nightly ]);
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
  let t = Behaviors.create ~digestif:"/bin/digestif" n in
  let now = Unix.gettimeofday () in
  Alcotest.(check bool)
    "read spawns after new envelopes" true
    (Behaviors.after_pass ~now t ~stored:1 |> List.map fst = [ Behaviors.Read ]);
  Alcotest.(check bool) "nothing finished" true (Behaviors.reap ~now t = []);
  ignore (Behaviors.reap ~now:(now +. Behaviors.timeout Read +. 1.) t);
  match Behaviors.wait_all t with
  | [ f ] -> Alcotest.(check string) "ended" "killed by SIGTERM" f.status
  | _ -> Alcotest.fail "one behavior finished"

let () =
  Alcotest.run "web"
    [
      ( "server",
        [
          Alcotest.test_case "access" `Quick access;
          Alcotest.test_case "deny layer" `Quick deny;
          Alcotest.test_case "api" `Quick api;
          Alcotest.test_case "demo reset" `Quick reset;
          Alcotest.test_case "phones" `Quick phones;
          Alcotest.test_case "silence reasons" `Quick silence;
          Alcotest.test_case "note ticks" `Quick note_ticks;
          Alcotest.test_case "post deny layer" `Quick post_deny;
          Alcotest.test_case "quiet hours" `Quick quiet_hours_api;
          Alcotest.test_case "silence notes" `Quick silence_notes_api;
          Alcotest.test_case "silence report" `Quick silence_report;
        ] );
      ( "behaviors",
        [
          Alcotest.test_case "nightly due" `Quick nightly_due;
          Alcotest.test_case "spawn" `Quick behavior_spawn;
          Alcotest.test_case "deadline" `Quick behavior_deadline;
        ] );
    ]
