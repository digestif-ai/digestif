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
    (Result.is_error (Deny.compile_pattern "("));
  (* The financial detectors: always on, each shape verified by its checksum. *)
  let twelve =
    String.concat " " (List.init 11 (fun _ -> "abandon")) ^ " about"
  in
  List.iter
    (fun (text, rule) -> Alcotest.(check string) text rule (check [] text))
    [
      ("card 4111 1111 1111 1111", "detector: Payment card numbers");
      ("card 4111-1111-1111-1111 then 2026", "detector: Payment card numbers");
      ("amex 3782 822463 10005", "detector: Payment card numbers");
      ("mastercard 2223000048410010", "detector: Payment card numbers");
      ("card 4111 1111 1111 1112", "pass");
      ("epoch 1761700000000 and 1234567812345670", "pass");
      ("a 20-digit run 41111111111111111111", "pass");
      ("IBAN GB82 WEST 1234 5698 7654 32", "detector: Bank account numbers");
      ("IBAN DE89370400440532013000 EUR", "detector: Bank account numbers");
      ("IBAN GB82 WEST 1234 5698 7654 33", "pass");
      ("routing 123456780, account 9876543210", "detector: Bank account numbers");
      ("routing 123456780 alone", "pass");
      ("routing 123456781, account 9876543210", "pass");
      ("account 9876543210 then routing 123456780", "pass");
      ("to 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "detector: Crypto wallets");
      ("P2SH 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", "detector: Crypto wallets");
      ( "WIF 5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ",
        "detector: Crypto wallets" );
      ( "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8",
        "detector: Crypto wallets" );
      ("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", "detector: Crypto wallets");
      ( "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
        "detector: Crypto wallets" );
      ( "eth 0xde0B295669a9FD93d5F28D9Ec85E40f4cb697BAe",
        "detector: Crypto wallets" );
      (* A checksum that fails is no wallet; the secret detectors still read the token. *)
      ( "a typo 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb",
        "detector: High-entropy strings" );
      ("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5", "pass");
      ("commit de0b295669a9fd93d5f28d9ec85e40f4cb697bae", "pass");
      ("my seed: " ^ twelve ^ ", keep it", "detector: Recovery phrases");
      ( String.concat "\n"
          (List.mapi
             (fun i w -> Printf.sprintf "%d. %s" (i + 1) w)
             (String.split_on_char ' ' twelve)),
        "detector: Recovery phrases" );
      (String.concat " " (List.init 12 (fun _ -> "abandon")), "pass");
      ( "Worked on the wallet app's send screen and the bank feed; paid $1,200.",
        "pass" );
    ]

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
    [ "waiting"; "approved"; "approved" ]
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
    "three unchanged in a row: the suggestion" true
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
  Store.add_tick log ~at:(ago 2.) Store.Quiet;
  ignore (Store.Problems.report log ~job:"write_version" ~kind:"signed_out" ());
  check "an open problem: the agent is signed out" "harness_signed_out";
  Store.Problems.resolve log ~job:"write_version" ();
  ignore (Store.Problems.report log ~job:"send" ~kind:"signing_refused" ());
  check "signing refused the note" "deny_refusing";
  Store.Problems.resolve log ~job:"send" ();
  Store.add_tick log ~at:(ago 0.5) Store.Posted;
  check "posted, and every relay accepting" "none";
  Log.add_relay log "https://relay-1.example";
  Log.record_sync log "https://relay-1.example" (Some "403 not admitted");
  check "a relay rejecting" "relay_rejecting";
  Store.select_sources log [];
  check "no sources wins" "no_sources"

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
       (Api.Notes.Could_not_finish { check = "rules"; signed_out = true }));
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
      (Api.submit_note_text ~approve:true ~could_not_finish:("rules", true) n
         "Shipped the importer.")
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
      (Api.submit_note_text ~could_not_finish:("pii", false) n
         "Paid the invoice.")
  in
  Alcotest.(check bool)
    "model unavailable" true
    (List.mem ("pii_check", "model_unavailable") (open_jobs ()));
  let v2 = List.hd (N.versions log ~note_id:id2) in
  ok
    (Api.version_checked_text n ~version:v2.v_id
       (Api.Notes.Passed { text = ""; removed = true }));
  Alcotest.(check bool) "no note" true (N.find log id2 = None)

(* The digest's silence report: while silent, since when and the fixed reason; nothing otherwise.
   Ada last posted 26 hours before the demo's now. *)
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
  Alcotest.(check bool)
    "posting: still nothing" true
    (report ~now:real ~since:None = None);
  match
    report ~now:(real +. (2.5 *. 86400.)) ~since:(Some (Time_fmt.of_unix real))
  with
  | Some [ head; reason ] ->
      Alcotest.(check bool)
        "since when" true
        (contains head "has not posted since");
      Alcotest.(check bool)
        "the fixed reason" true
        (contains reason "No source is chosen")
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
  Alcotest.(check int) "same session" 200 (fst (call n c "status"));
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
  let armed = local_time ~day:28 ~hour:12 ~min:0 in
  let due ?last_date ?(armed_since = armed) ~day ~hour ~min () =
    Behaviors.nightly_due_at ~minute:17 ~last_date ~armed_since
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
  Alcotest.(check bool)
    "armed after the slot: nothing tonight" false
    (Behaviors.nightly_due n.log ~now);
  Log.set_config n.log Behaviors.k_armed_since
    (Printf.sprintf "%.0f" (local_time ~day:28 ~hour:12 ~min:0));
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
  Alcotest.(check bool)
    "a sleep past the deadline is a pause, not time spent" true
    (Behaviors.reap ~now:(now +. Behaviors.timeout Read +. 1.) t = []
    && Behaviors.busy t);
  (* Awake: the run loop reaps every few seconds. *)
  let awake = ref (now +. Behaviors.timeout Read +. 1.) in
  let until = !awake +. Behaviors.timeout Read +. 5. in
  while !awake < until do
    awake := !awake +. 5.;
    ignore (Behaviors.reap ~now:!awake t)
  done;
  match Behaviors.wait_all t with
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
  let t = Behaviors.create ~digestif:"/bin/digestif" n in
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
  let t = Behaviors.create ~digestif:"/bin/digestif" n in
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
  let form = Some (`Assoc []) in
  ignore form;
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
  List.iter (not_built "ISS-38778")
    [
      ("GET", "organizations", None);
      ("PUT", "organizations/o1", form);
      ("GET", "repositories?q=x", None);
      ("PUT", "repositories/r1", form);
      ("GET", "commit_authors", None);
      ("POST", "commit_authors", form);
      ("PUT", "commit_authors/a1", form);
      ("DELETE", "commit_authors/a1", None);
    ];
  List.iter (not_built "ISS-38780")
    [ ("GET", "settings/note_time", None); ("PUT", "settings/note_time", form) ];
  not_built "ISS-38784" ("GET", "invitees", None);
  List.iter (not_built "ISS-38785")
    [
      ("GET", "paused", None);
      ("POST", "paused", None);
      ("DELETE", "paused", None);
    ];
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
  refused "an empty name" (Setup_chat.save_names n ~name:" " ~agent_name:"Wren");
  ignore (ok (Setup_chat.save_names n ~name:"Dana Ruiz" ~agent_name:"Wren"));
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
  (match
     Setup_chat.last_words ~exe:"~/.local/bin/digestif" ~browser:true ~host:"h"
   with
  | [ _; back; phrase ] ->
      Alcotest.(check bool)
        "the way back" true
        (contains back "~/.local/bin/digestif open");
      Alcotest.(check bool)
        "close the window" true
        (contains phrase "close it once your note is open")
  | _ -> Alcotest.fail "three last lines");
  match
    Setup_chat.last_words ~exe:"~/.local/bin/digestif" ~browser:false ~host:"h"
  with
  | [ _; back; _ ] ->
      Alcotest.(check bool)
        "no browser: a link and the tunnel" true
        (contains back "~/.local/bin/digestif open --print"
        && contains back "ssh -L 7420:127.0.0.1:7420 h")
  | _ -> Alcotest.fail "three last lines"

let setup_prompt () =
  let p =
    Setup_chat.prompt
      ~text:"run {{digestif}} setup found.\n{{always_on_rules}}\n"
      ~rule:"Never touch money.\n" ~digestif:"/x/digestif"
  in
  Alcotest.(check string)
    "both filled in" "run /x/digestif setup found.\nNever touch money.\n" p

(* status.first_note: the note page's states, and when the navigation shows. *)
let first_note_states () =
  let n = fresh () in
  let c = session n in
  let status () = snd (call n c "status") in
  let first_run () = member "first_run" (status ()) = `Bool true in
  let state () = s "state" (member "first_note" (status ())) in
  Alcotest.(check bool) "hidden from the start" true (first_run ());
  Alcotest.(check bool)
    "no first note yet" true
    (member "first_note" (status ()) = `Null);
  Store.Setup.start_first_note n.log;
  Alcotest.(check string) "writing" "writing" (state ());
  Alcotest.(check bool) "still hidden" true (first_run ());
  let progress = Filename.concat n.dir "behaviors/nightly" in
  Node.mkdir_p progress;
  Out_channel.with_open_bin (Filename.concat progress "progress.json")
    (fun oc ->
      output_string oc {|{"step":"reading","sources":["Git repositories"]}|});
  Alcotest.(check string)
    "its step" "reading"
    (s "step" (member "first_note" (status ())));
  let later = Time_fmt.of_unix (Unix.gettimeofday () +. 5.) in
  Store.add_tick n.log ~at:later Store.Quiet;
  Alcotest.(check string) "nothing found" "no_activity" (state ());
  Alcotest.(check bool) "the navigation opens" false (first_run ());
  ignore
    (Store.Problems.report n.log
       ~at:(Time_fmt.of_unix (Unix.gettimeofday () +. 6.))
       ~job:"write_version" ~kind:"signed_out" ());
  Alcotest.(check string) "says why" "failed" (state ());
  Alcotest.(check bool)
    "a message" true
    (contains (s "message" (member "first_note" (status ()))) "signed out")

let () =
  Alcotest.run "web"
    [
      ( "server",
        [
          Alcotest.test_case "access" `Quick access;
          Alcotest.test_case "deny layer" `Quick deny;
          Alcotest.test_case "api" `Quick api;
          Alcotest.test_case "invited names" `Quick invited_names;
          Alcotest.test_case "demo reset" `Quick reset;
          Alcotest.test_case "phones" `Quick phones;
          Alcotest.test_case "silence reasons" `Quick silence;
          Alcotest.test_case "note ticks" `Quick note_ticks;
          Alcotest.test_case "signing backstop" `Quick signing_backstop;
          Alcotest.test_case "note edit" `Quick note_edit;
          Alcotest.test_case "approval setting" `Quick approval_setting;
          Alcotest.test_case "note log" `Quick note_log;
          Alcotest.test_case "held reason column" `Quick held_reason_column;
          Alcotest.test_case "post deny layer" `Quick post_deny;
          Alcotest.test_case "quiet hours" `Quick quiet_hours_api;
          Alcotest.test_case "the problem record" `Quick problem_record;
          Alcotest.test_case "a check that cannot finish" `Quick
            check_could_not_finish;
          Alcotest.test_case "silence report" `Quick silence_report;
          Alcotest.test_case "command sources" `Quick command_sources;
          Alcotest.test_case "session titles" `Quick session_titles;
          Alcotest.test_case "session titles skip financial projects" `Quick
            session_titles_skip_financial;
          Alcotest.test_case "project dirs" `Quick project_dirs;
          Alcotest.test_case "many repos" `Quick many_repos;
          Alcotest.test_case "brief draft" `Quick brief_draft;
          Alcotest.test_case "demo behaviors" `Quick demo_behaviors;
          Alcotest.test_case "member experience routes" `Quick
            member_experience_routes;
          Alcotest.test_case "setup chat" `Quick setup_chat;
          Alcotest.test_case "setup prompt" `Quick setup_prompt;
          Alcotest.test_case "first note states" `Quick first_note_states;
        ] );
      ( "behaviors",
        [
          Alcotest.test_case "nightly due" `Quick nightly_due;
          Alcotest.test_case "spawn" `Quick behavior_spawn;
          Alcotest.test_case "deadline" `Quick behavior_deadline;
          Alcotest.test_case "retry" `Quick behavior_retry;
          Alcotest.test_case "check" `Quick behavior_check;
        ] );
    ]
