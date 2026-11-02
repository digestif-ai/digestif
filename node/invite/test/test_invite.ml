open Digestif_invite
open Digestif_core

let time s = Option.get (Dinner.parse_time s)
let now = time "2026-10-28T02:00:00.000Z"
let hours h = Option.get (Ptime.add_span now (Ptime.Span.of_int_s (h * 3600)))
let fresh_key () = Crypto.generate_signing_key ()
let relays = [ "https://relay-1.example"; "https://relay-2.example" ]

let guests =
  [
    { Dinner.name = "Roman Cherkasov"; email = "roman@example.com" };
    { Dinner.name = "Phong Nguyen"; email = "phong@example.com" };
  ]

let host_identity = fresh_key ()
let host_device = fresh_key ()

let make_dinner () =
  match
    Dinner.create
      ~host:(Keys.public host_identity)
      ~date:"2026-10-27" ~label:"AI Dinner 2: autonomy" ~relays ~now guests
  with
  | Ok d -> d
  | Error e -> Alcotest.fail e

let signed_dinner () =
  let d = make_dinner () in
  let env =
    Dinner.sign ~host_device ~seq:3
      ~prev:("sha256:" ^ String.make 64 '0')
      ~epoch:6 ~now d
  in
  (d, env)

(* ---- invite codes ---- *)

let code () =
  { Invite_code.relay = "https://relay-1.example"; secret = Crypto.random 16 }

let parse_ok s =
  match Invite_code.parse s with
  | Ok c -> c
  | Error e -> Alcotest.failf "%s: %s" s e

let test_code_roundtrip () =
  for _ = 1 to 200 do
    let c = code () in
    let text = Invite_code.to_text c in
    Alcotest.(check bool) "text round-trips" true (parse_ok text = c);
    Alcotest.(check bool)
      "url round-trips" true
      (parse_ok (Invite_code.to_url c) = c)
  done

let test_code_shape () =
  let c = code () in
  let code = Invite_code.code c in
  Alcotest.(check int) "27 symbols in groups of four" 33 (String.length code);
  Alcotest.(check bool)
    "starts with the relay host" true
    (String.starts_with ~prefix:"relay-1.example/" (Invite_code.to_text c))

let test_code_forgiving () =
  let c = code () in
  let sloppy =
    "  DIGESTIF://JOIN/"
    ^ String.lowercase_ascii
        ("relay-1.example/ "
        ^ String.concat " " (String.split_on_char '-' (Invite_code.code c)))
    ^ "\n"
  in
  Alcotest.(check bool)
    "case, spaces and the URL prefix are forgiven" true
    (parse_ok sloppy = c);
  let with_o =
    String.map
      (fun ch -> if ch = '0' then 'O' else if ch = '1' then 'l' else ch)
      (Invite_code.code c)
  in
  Alcotest.(check bool)
    "O and l read as 0 and 1" true
    (parse_ok ("relay-1.example/" ^ with_o) = c)

let test_code_typo () =
  let c = code () in
  let code = Invite_code.code c in
  let i = 5 in
  let swapped = if code.[i] = 'A' then 'B' else 'A' in
  let typo = String.mapi (fun j ch -> if j = i then swapped else ch) code in
  (match Invite_code.parse ("relay-1.example/" ^ typo) with
  | Ok _ -> Alcotest.fail "a typo parsed"
  | Error _ -> ());
  (match Invite_code.parse code with
  | Ok _ -> Alcotest.fail "no relay parsed"
  | Error _ -> ());
  match Invite_code.parse ("relay-1.example/" ^ String.sub code 0 20) with
  | Ok _ -> Alcotest.fail "a short code parsed"
  | Error _ -> ()

let test_code_local_relay () =
  let c = { (code ()) with relay = "http://localhost:8787" } in
  Alcotest.(check string)
    "http relay keeps its scheme" "http://localhost:8787"
    (parse_ok (Invite_code.to_text c)).relay

let test_invite_key_per_code () =
  let a = code () and b = code () in
  Alcotest.(check bool)
    "each code its own key" true
    (Invite_code.invite_public_key a <> Invite_code.invite_public_key b);
  Alcotest.(check string)
    "the key is a function of the code"
    (Invite_code.invite_public_key a)
    (Invite_code.invite_public_key (parse_ok (Invite_code.to_text a)))

let test_token () =
  for _ = 1 to 200 do
    let c = code () in
    let t = Invite_code.to_token c in
    Alcotest.(check bool)
      "dg1. prefix" true
      (String.starts_with ~prefix:"dg1." t);
    Alcotest.(check bool)
      "one shell-safe word" true
      (String.for_all
         (fun ch ->
           match ch with
           | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
           | _ -> false)
         t);
    Alcotest.(check bool) "token round-trips" true (parse_ok t = c);
    Alcotest.(check bool)
      "surrounding space forgiven" true
      (parse_ok (" " ^ t ^ "\n") = c)
  done;
  let local = { (code ()) with relay = "http://localhost:8787" } in
  Alcotest.(check string)
    "an http relay keeps its scheme" "http://localhost:8787"
    (parse_ok (Invite_code.to_token local)).relay;
  let t = Invite_code.to_token (code ()) in
  let i = String.length t - 6 in
  let typo =
    String.mapi
      (fun j ch -> if j = i then if ch = 'A' then 'B' else 'A' else ch)
      t
  in
  (match Invite_code.parse typo with
  | Ok _ -> Alcotest.fail "a retyped token parsed"
  | Error _ -> ());
  match Invite_code.parse (String.sub t 0 20) with
  | Ok _ -> Alcotest.fail "a token cut short parsed"
  | Error _ -> ()

(* ---- dinner ---- *)

let test_dinner () =
  let d, env = signed_dinner () in
  Alcotest.(check int)
    "a key per guest" 2
    (List.length
       (List.sort_uniq compare
          (List.map (fun (i : Dinner.invite) -> i.invite_key) d.invites)));
  List.iter
    (fun (i : Dinner.invite) ->
      Alcotest.(check string)
        "72-hour expiry" "2026-10-31T02:00:00.000Z"
        (Dinner.iso8601 i.expires_at))
    d.invites;
  Alcotest.(check bool)
    "the dinner envelope verifies" true
    (Envelope.verify env = Ok ());
  Alcotest.(check string)
    "signed by the host's device key" (Keys.public host_device)
    env.envelope.author;
  Alcotest.(check string)
    "the body is the core dinner body"
    (Jcs.encode (Dinner.body d))
    (Jcs.encode (Option.get env.body));
  match Dinner.parse (Dinner.body d) with
  | Error e -> Alcotest.fail e
  | Ok p ->
      Alcotest.(check (list string)) "relays" relays p.parsed_relays;
      Alcotest.(check (list string))
        "guests"
        [ "Roman Cherkasov"; "Phong Nguyen" ]
        (List.map (fun (g : Dinner.listed_guest) -> g.listed_name) p.guests)

let test_dinner_refusals () =
  let create gs relays =
    Dinner.create ~host:"ed25519:x" ~date:"2026-10-27" ~label:"x" ~relays ~now
      gs
  in
  let g n = { Dinner.name = n; email = "a@example.com" } in
  Alcotest.(check bool) "no guests" true (Result.is_error (create [] relays));
  Alcotest.(check bool) "no relays" true (Result.is_error (create [ g "A" ] []));
  Alcotest.(check bool)
    "duplicate names" true
    (Result.is_error (create [ g "Ann Lee"; g "ann lee " ] relays))

(* ---- join ---- *)

let invite_of (d : Dinner.t) n = List.nth d.invites n

let test_join () =
  let d, env = signed_dinner () in
  let inv = invite_of d 0 in
  let code = parse_ok (Invite_code.to_text inv.code) in
  match Join.check_dinner ~now:(hours 1) ~code env with
  | Error e -> Alcotest.fail (Join.error_message e)
  | Ok (dinner_hash, parsed, _) ->
      Alcotest.(check (option string))
        "the joiner's card name is the one the host gave them"
        (Some "Roman Cherkasov")
        (Invite_node.own_guest_name parsed code);
      Alcotest.(check string)
        "an agent name until the member picks one" "Roman's agent"
        (Invite_node.default_agent_name "Roman Cherkasov");
      Alcotest.(check string)
        "a one-word name" "Cher's agent"
        (Invite_node.default_agent_name "Cher");
      Alcotest.(check string)
        "the dinner hash is the envelope's"
        (Envelope.hash env.envelope)
        dinner_hash;
      let identity = fresh_key () and device = fresh_key () in
      let body = Join.body ~dinner_hash ~code ~identity ~device in
      let jenv = Join.envelope ~now:(hours 1) ~code body in
      Alcotest.(check (pair int (option string)))
        "seq 1, no prev" (1, None)
        (jenv.envelope.seq, jenv.envelope.prev);
      (match Join.verify jenv with
      | Error e -> Alcotest.fail e
      | Ok j ->
          Alcotest.(check string)
            "authored by the invite key" inv.invite_key j.invite_key;
          Alcotest.(check string)
            "names the identity" (Keys.public identity) j.identity_key;
          Alcotest.(check string)
            "names the device" (Keys.public device) j.device_key);
      let tampered =
        match body with
        | `Assoc fs ->
            `Assoc
              (List.map
                 (fun (k, v) ->
                   if k = "identity_key" then
                     (k, `String (Keys.public (fresh_key ())))
                   else (k, v))
                 fs)
        | v -> v
      in
      let tenv = Join.envelope ~now:(hours 1) ~code tampered in
      Alcotest.(check bool)
        "a swapped identity does not verify" true
        (Result.is_error (Join.verify tenv))

let test_join_refusals () =
  let d, env = signed_dinner () in
  let inv = invite_of d 1 in
  let check ~now ?(body = Dinner.body d) code =
    Join.check_dinner ~now ~code { env with body = Some body }
  in
  (match check ~now:(hours 73) inv.code with
  | Error (Join.Expired _) -> ()
  | _ -> Alcotest.fail "an expired invite was accepted");
  (match check ~now:(hours 1) (code ()) with
  | Error Join.Not_this_invite -> ()
  | _ -> Alcotest.fail "a code the dinner does not name was accepted");
  let forged =
    match Dinner.body d with
    | `Assoc fs -> `Assoc (("host", `String "ed25519:forged") :: List.tl fs)
    | v -> v
  in
  match check ~now:(hours 1) ~body:forged inv.code with
  | Error (Join.Bad_dinner _) -> ()
  | _ -> Alcotest.fail "a dinner that does not verify was accepted"

let test_bootstrap_path () =
  let c = code () in
  Alcotest.(check string)
    "the invite key reads its own dinner"
    ("/v0/invites/" ^ Invite_code.invite_public_key c)
    (Join.bootstrap_path c)

(* ---- host watch ---- *)

let join_for (d : Dinner.t) env n =
  let inv = invite_of d n in
  let identity = fresh_key () in
  let body =
    Join.body
      ~dinner_hash:(Envelope.hash env.Envelope.envelope)
      ~code:inv.code ~identity ~device:(fresh_key ())
  in
  let jenv = Join.envelope ~now:(hours 2) ~code:inv.code body in
  Result.get_ok (Join.verify jenv)

let test_host_watch () =
  let d, env = signed_dinner () in
  let ledger =
    Host_watch.records_of_dinner
      ~dinner_hash:(Envelope.hash env.envelope)
      ~message:"Great talking with you." d
  in
  let ledger =
    Host_watch.mark_expected ledger ~invite_key:(invite_of d 0).invite_key
  in
  let roman = join_for d env 0 and phong = join_for d env 1 in
  let ledger, o = Host_watch.observe ~now:(hours 2) ledger roman in
  (match o with
  | Host_watch.Shown r ->
      Alcotest.(check string) "expected" "Roman Cherkasov" r.guest_name
  | _ -> Alcotest.fail "an expected join asked");
  let ledger, o = Host_watch.observe ~now:(hours 2) ledger roman in
  (match o with
  | Host_watch.Already_handled _ -> ()
  | _ -> Alcotest.fail "a repeat on another relay was not recognized");
  let ledger, o = Host_watch.observe ~now:(hours 2) ledger phong in
  (match o with
  | Host_watch.Asked (_, ask) ->
      Alcotest.(check string)
        "one ask per invite"
        ("join:" ^ (invite_of d 1).invite_key)
        ask.key;
      Alcotest.(check bool)
        "an unanswered ask revokes" true
        (ask.default = Host_watch.Revoke);
      Alcotest.(check string)
        "lapses in 72 hours" "2026-10-31T04:00:00.000Z"
        (Dinner.iso8601 ask.lapses_at)
  | _ -> Alcotest.fail "an unexpected join did not ask");
  (* Raised late, the ask still lapses inside the dinner device's revoke window. *)
  let fresh_ledger =
    Host_watch.records_of_dinner
      ~dinner_hash:(Envelope.hash env.envelope)
      ~message:"Great talking with you." d
  in
  (match Host_watch.observe ~now:(hours (2 + (5 * 24))) fresh_ledger phong with
  | _, Host_watch.Asked (_, ask) ->
      Alcotest.(check string)
        "an ask raised five days late lapses six days after the join"
        "2026-11-03T04:00:00.000Z"
        (Dinner.iso8601 ask.lapses_at)
  | _ -> Alcotest.fail "an unexpected join did not ask");
  (* A lapse inside the window is revoked by the node's device key; past it, it needs the phrase. *)
  (match
     Host_watch.lapsed ledger ~invite_key:phong.invite_key
       ~identity_key:phong.identity_key ~now:(hours 74)
       ~joined_at:phong.created_at
   with
  | l, Host_watch.Revoke_as_device ->
      Alcotest.(check bool)
        "the lapse marks the record revoked" true
        (List.exists
           (fun (r : Host_watch.record) ->
             r.state = Host_watch.Revoked { identity_key = phong.identity_key })
           l)
  | _ -> Alcotest.fail "a lapse inside the window needs the phrase");
  (match
     Host_watch.lapsed ledger ~invite_key:phong.invite_key
       ~identity_key:phong.identity_key
       ~now:(hours (2 + (7 * 24) + 1))
       ~joined_at:phong.created_at
   with
  | l, Host_watch.Needs_phrase ->
      Alcotest.(check bool)
        "past the window the ledger is unchanged" true (l = ledger)
  | _ -> Alcotest.fail "a lapse past the window was revoked by the device key");
  let second =
    { (join_for d env 0) with Join.invite_key = (invite_of d 0).invite_key }
  in
  let _, o = Host_watch.observe ~now:(hours 2) ledger second in
  (match o with
  | Host_watch.Asked _ -> ()
  | _ -> Alcotest.fail "a second identity on one invite did not ask");
  let stranger = { roman with Join.invite_key = Keys.public (fresh_key ()) } in
  let _, o = Host_watch.observe ~now:(hours 2) ledger stranger in
  (match o with
  | Host_watch.Not_ours -> ()
  | _ -> Alcotest.fail "another host's join was claimed");
  let _, confirmed =
    Host_watch.answer ledger ~invite_key:phong.invite_key
      ~identity_key:phong.identity_key Host_watch.Confirm
  in
  Alcotest.(check (option string)) "a confirm revokes nothing" None confirmed;
  let ledger', revoke =
    Host_watch.answer ledger ~invite_key:phong.invite_key
      ~identity_key:phong.identity_key Host_watch.Revoke
  in
  Alcotest.(check (option string))
    "revoke names the identity that joined" (Some phong.identity_key) revoke;
  Alcotest.(check bool)
    "the ledger records it" true
    (List.exists
       (fun (r : Host_watch.record) ->
         r.state = Host_watch.Revoked { identity_key = phong.identity_key })
       ledger');
  (match Host_watch.of_json (Host_watch.to_json ledger') with
  | Ok back ->
      Alcotest.(check bool) "the ledger round-trips" true (back = ledger')
  | Error e -> Alcotest.fail e);
  let without_message =
    match Host_watch.to_json ledger' with
    | `List items ->
        `List
          (List.map
             (function
               | `Assoc fs -> `Assoc (List.remove_assoc "message" fs) | j -> j)
             items)
    | j -> j
  in
  match Host_watch.of_json without_message with
  | Ok back ->
      Alcotest.(check (list string))
        "a record with no lines reads as none" [ ""; "" ]
        (List.map (fun (r : Host_watch.record) -> r.message) back)
  | Error e -> Alcotest.fail e

(* ---- email ---- *)

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let message = "Great talking agents with you on Tuesday."

let test_email () =
  let d = make_dinner () in
  let roman = invite_of d 0 in
  let e = Invite_email.render ~host_name:"Mike" ~message ~dinner:d roman in
  Alcotest.(check string) "to the guest" "roman@example.com" e.to_;
  Alcotest.(check string)
    "the subject names the circle"
    "Join the AI Dinner 2: autonomy circle on Digestif" e.subject;
  let command =
    "curl -fsSL https://digestif.io/install.sh | sh -s -- --join "
    ^ Invite_code.to_token roman.code
  in
  Alcotest.(check string)
    "greeting, the host's lines, the paragraph, the command, the expiry, the \
     closing"
    (String.concat "\n"
       [
         "Hi Roman,";
         "";
         message;
         "";
         Invite_email.paragraph;
         "";
         "Paste this into a terminal on your Mac or Linux machine:";
         "";
         "  " ^ command;
         "";
         "This invite is yours alone and works once, until October 30, 2026 at \
          10:00 PM EDT.";
         "";
         "And please let me know how else I can help.";
         "";
         "Mike";
       ])
    e.text;
  Alcotest.(check bool)
    "the command's token is the guest's invite" true
    (parse_ok (Invite_code.to_token roman.code) = roman.code);
  Alcotest.(check bool)
    "the paragraph names where the code is" true
    (contains Invite_email.paragraph "github.com/digestif-ai/digestif");
  Alcotest.(check bool)
    "names no coding agent" false
    (contains e.text "Claude" || contains e.text "Codex");
  Alcotest.(check bool)
    "mailto encodes the body" true
    (String.starts_with ~prefix:"mailto:roman%40example.com?subject="
       (Invite_email.mailto e)
    && not (contains (Invite_email.mailto e) " "))

let test_message_required () =
  List.iter
    (fun m ->
      match Invite_email.message_of_string m with
      | Ok _ -> Alcotest.failf "%S was taken as the host's lines" m
      | Error e ->
          Alcotest.(check bool) "names --message" true (contains e "--message"))
    [ ""; "  \n\t " ];
  Alcotest.(check (result string string))
    "trimmed" (Ok "Hi there.")
    (Invite_email.message_of_string "\n Hi there. \n")

let test_eastern_expiry () =
  let at s = Invite_email.readable_expiry (time s) in
  Alcotest.(check string)
    "standard time" "November 3, 2026 at 8:12 PM EST"
    (at "2026-11-04T01:12:00.000Z");
  Alcotest.(check string)
    "daylight time" "July 4, 2026 at 12:30 PM EDT"
    (at "2026-07-04T16:30:00.000Z");
  Alcotest.(check string)
    "midnight reads 12 AM" "January 2, 2027 at 12:05 AM EST"
    (at "2027-01-02T05:05:00.000Z");
  (* 2026: daylight time runs from March 8 07:00 UTC to November 1 06:00 UTC. *)
  Alcotest.(check string)
    "the minute before daylight time" "March 8, 2026 at 1:59 AM EST"
    (at "2026-03-08T06:59:00.000Z");
  Alcotest.(check string)
    "the minute daylight time starts" "March 8, 2026 at 3:00 AM EDT"
    (at "2026-03-08T07:00:00.000Z");
  Alcotest.(check string)
    "the minute before daylight time ends" "November 1, 2026 at 1:59 AM EDT"
    (at "2026-11-01T05:59:00.000Z");
  Alcotest.(check string)
    "the minute standard time returns" "November 1, 2026 at 1:00 AM EST"
    (at "2026-11-01T06:00:00.000Z")

let () =
  Alcotest.run "invite"
    [
      ( "code",
        [
          Alcotest.test_case "round-trip" `Quick test_code_roundtrip;
          Alcotest.test_case "shape" `Quick test_code_shape;
          Alcotest.test_case "forgiving paste" `Quick test_code_forgiving;
          Alcotest.test_case "typos refused" `Quick test_code_typo;
          Alcotest.test_case "local relay" `Quick test_code_local_relay;
          Alcotest.test_case "key per code" `Quick test_invite_key_per_code;
          Alcotest.test_case "install token" `Quick test_token;
        ] );
      ( "dinner",
        [
          Alcotest.test_case "signed dinner" `Quick test_dinner;
          Alcotest.test_case "refusals" `Quick test_dinner_refusals;
        ] );
      ( "join",
        [
          Alcotest.test_case "join verifies" `Quick test_join;
          Alcotest.test_case "refusals" `Quick test_join_refusals;
          Alcotest.test_case "bootstrap path" `Quick test_bootstrap_path;
        ] );
      ( "host",
        [ Alcotest.test_case "unexpected joins ask" `Quick test_host_watch ] );
      ( "email",
        [
          Alcotest.test_case "invite email" `Quick test_email;
          Alcotest.test_case "the host's lines are required" `Quick
            test_message_required;
          Alcotest.test_case "expiry in Eastern time" `Quick test_eastern_expiry;
        ] );
    ]
