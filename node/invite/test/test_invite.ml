open Digestif_invite

let () = Mirage_crypto_rng_unix.use_default ()
let time s = Option.get (Invite_wire.parse_iso8601 s)
let now = time "2026-10-28T02:00:00.000Z"
let hours h = Option.get (Ptime.add_span now (Ptime.Span.of_int_s (h * 3600)))
let fresh_key () = Invite_wire.priv_of_seed (Mirage_crypto_rng.generate 32)
let relays = [ "https://relay-1.example"; "https://relay-2.example" ]

let guests =
  [
    {
      Dinner.name = "Roman Cherkasov";
      email = "roman@example.com";
      platform = Some Dinner.Mac;
    };
    {
      Dinner.name = "Phong Nguyen";
      email = "phong@example.com";
      platform = None;
    };
  ]

let host_identity = fresh_key ()
let host_device = fresh_key ()

let make_dinner () =
  match
    Dinner.create
      ~host:(Invite_wire.public_key host_identity)
      ~date:"2026-10-27" ~label:"AI Dinner 2: autonomy" ~relays ~now guests
  with
  | Ok d -> d
  | Error e -> Alcotest.fail e

let signed_dinner () =
  let d = make_dinner () in
  let env = Dinner.sign ~host_device ~seq:3 ~prev:"sha256:00" ~epoch:6 ~now d in
  (d, env)

(* ---- JCS ---- *)

let test_jcs () =
  let v =
    Yojson.Safe.from_string
      {|{"\u20ac":"Euro","\r":"CR","1":"One","\ud83d\ude00":"Smile","b":[true,null,-1],"a\"":"q\u0001"}|}
  in
  Alcotest.(check string)
    "RFC 8785 ordering and escaping"
    "{\"\\r\":\"CR\",\"1\":\"One\",\"a\\\"\":\"q\\u0001\",\"b\":[true,null,-1],\"\xe2\x82\xac\":\"Euro\",\"\xf0\x9f\x98\x80\":\"Smile\"}"
    (Invite_wire.jcs v);
  Alcotest.check_raises "floats refused"
    (Invalid_argument "Jcs: floats do not appear in Digestif bodies") (fun () ->
      ignore (Invite_wire.jcs (`Float 1.5)))

(* ---- invite codes ---- *)

let code () =
  {
    Invite_code.relay = "https://relay-1.example";
    secret = Mirage_crypto_rng.generate 16;
  }

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
        (Invite_wire.iso8601 i.expires_at))
    d.invites;
  Alcotest.(check bool)
    "the dinner envelope verifies" true
    (Invite_wire.verify_envelope env.json (Dinner.body d));
  Alcotest.(check (option string))
    "signed by the host's device key"
    (Some (Invite_wire.public_key host_device))
    (match Invite_wire.field "author" env.json with
    | Some (`String s) -> Some s
    | _ -> None);
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
  let g n = { Dinner.name = n; email = "a@example.com"; platform = None } in
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
  match
    Join.check_dinner ~now:(hours 1) ~code ~envelope:env.json
      ~body:(Dinner.body d)
  with
  | Error e -> Alcotest.fail (Join.error_message e)
  | Ok (dinner_hash, _, _) ->
      Alcotest.(check string)
        "the dinner hash is the envelope's" env.hash dinner_hash;
      let identity = fresh_key () and device = fresh_key () in
      let body = Join.body ~dinner_hash ~code ~identity ~device in
      let jenv = Join.envelope ~now:(hours 1) ~code body in
      (match Join.verify ~envelope:jenv.json ~body with
      | Error e -> Alcotest.fail e
      | Ok j ->
          Alcotest.(check string)
            "authored by the invite key" inv.invite_key j.invite_key;
          Alcotest.(check string)
            "names the identity"
            (Invite_wire.public_key identity)
            j.identity_key;
          Alcotest.(check string)
            "names the device"
            (Invite_wire.public_key device)
            j.device_key);
      let tampered =
        match body with
        | `Assoc fs ->
            `Assoc
              (List.map
                 (fun (k, v) ->
                   if k = "identity_key" then
                     (k, `String (Invite_wire.public_key (fresh_key ())))
                   else (k, v))
                 fs)
        | v -> v
      in
      let tenv = Join.envelope ~now:(hours 1) ~code tampered in
      Alcotest.(check bool)
        "a swapped identity does not verify" true
        (Result.is_error (Join.verify ~envelope:tenv.json ~body:tampered))

let test_join_refusals () =
  let d, env = signed_dinner () in
  let inv = invite_of d 1 in
  let check ~now ?(body = Dinner.body d) code =
    Join.check_dinner ~now ~code ~envelope:env.json ~body
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

let test_bootstrap_request () =
  let c = code () in
  let path, headers =
    Join.bootstrap_request ~now ~nonce:(Mirage_crypto_rng.generate 16) c
  in
  let h k = List.assoc k headers in
  Alcotest.(check string)
    "the invite key reads its own dinner"
    ("/v0/invites/" ^ Invite_code.invite_public_key c)
    path;
  Alcotest.(check string)
    "signed by the invite key"
    (Invite_code.invite_public_key c)
    (h "Digestif-Key");
  let signed =
    Join.request_string ~meth:"GET" ~path ~timestamp:(h "Digestif-Timestamp")
      ~nonce:(h "Digestif-Nonce") ~body_sha256:Join.empty_body_hash
  in
  Alcotest.(check bool)
    "the request signature verifies" true
    (Invite_wire.verify ~key:(h "Digestif-Key")
       ~signature:(h "Digestif-Signature") signed)

(* ---- host watch ---- *)

let join_for (d : Dinner.t) env n =
  let inv = invite_of d n in
  let identity = fresh_key () in
  let body =
    Join.body ~dinner_hash:env.Invite_wire.hash ~code:inv.code ~identity
      ~device:(fresh_key ())
  in
  let jenv = Join.envelope ~now:(hours 2) ~code:inv.code body in
  Result.get_ok (Join.verify ~envelope:jenv.json ~body)

let test_host_watch () =
  let d, env = signed_dinner () in
  let ledger = Host_watch.records_of_dinner ~dinner_hash:env.hash d in
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
        (Invite_wire.iso8601 ask.lapses_at)
  | _ -> Alcotest.fail "an unexpected join did not ask");
  let second =
    { (join_for d env 0) with Join.invite_key = (invite_of d 0).invite_key }
  in
  let _, o = Host_watch.observe ~now:(hours 2) ledger second in
  (match o with
  | Host_watch.Asked _ -> ()
  | _ -> Alcotest.fail "a second identity on one invite did not ask");
  let stranger =
    { roman with Join.invite_key = Invite_wire.public_key (fresh_key ()) }
  in
  let _, o = Host_watch.observe ~now:(hours 2) ledger stranger in
  (match o with
  | Host_watch.Not_ours -> ()
  | _ -> Alcotest.fail "another host's join was claimed");
  let ledger', revoke =
    Host_watch.answer ledger ~invite_key:phong.invite_key
      ~identity_key:phong.identity_key Host_watch.Revoke ~host_identity
  in
  (match revoke with
  | Some body ->
      let s k =
        match Invite_wire.field k body with Some (`String v) -> v | _ -> ""
      in
      Alcotest.(check string)
        "revokes the identity" phong.identity_key (s "target");
      Alcotest.(check bool)
        "signed by the host identity" true
        (Invite_wire.verify ~key:(s "by") ~signature:(s "signature")
           (Invite_wire.jcs
              (`Assoc
                 [ ("target", `String (s "target")); ("by", `String (s "by")) ])))
  | None -> Alcotest.fail "revoke wrote nothing");
  match Host_watch.of_json (Host_watch.to_json ledger') with
  | Ok back ->
      Alcotest.(check bool) "the ledger round-trips" true (back = ledger')
  | Error e -> Alcotest.fail e

(* ---- email ---- *)

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let test_email () =
  let d = make_dinner () in
  let roman = invite_of d 0 and phong = invite_of d 1 in
  let e = Invite_email.render ~host_name:"Mike" ~dinner:d roman in
  Alcotest.(check string) "to the guest" "roman@example.com" e.to_;
  Alcotest.(check bool)
    "carries the code" true
    (contains e.text (Invite_code.to_text roman.code));
  Alcotest.(check bool)
    "carries the join link" true
    (contains e.text (Invite_code.to_url roman.code));
  Alcotest.(check bool)
    "Mac link only for a Mac guest" false (contains e.text "Linux:");
  Alcotest.(check bool)
    "says when it expires" true
    (contains e.text "October 31, 2026 at 02:00 UTC");
  let e2 = Invite_email.render ~host_name:"Mike" ~dinner:d phong in
  Alcotest.(check bool)
    "both platforms when unknown" true
    (contains e2.text "Mac:" && contains e2.text "Linux:");
  Alcotest.(check bool)
    "mailto encodes the body" true
    (String.starts_with ~prefix:"mailto:roman%40example.com?subject="
       (Invite_email.mailto e)
    && not (contains (Invite_email.mailto e) " "))

let () =
  Alcotest.run "invite"
    [
      ("jcs", [ Alcotest.test_case "ordering and escaping" `Quick test_jcs ]);
      ( "code",
        [
          Alcotest.test_case "round-trip" `Quick test_code_roundtrip;
          Alcotest.test_case "shape" `Quick test_code_shape;
          Alcotest.test_case "forgiving paste" `Quick test_code_forgiving;
          Alcotest.test_case "typos refused" `Quick test_code_typo;
          Alcotest.test_case "local relay" `Quick test_code_local_relay;
          Alcotest.test_case "key per code" `Quick test_invite_key_per_code;
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
          Alcotest.test_case "bootstrap read" `Quick test_bootstrap_request;
        ] );
      ( "host",
        [ Alcotest.test_case "unexpected joins ask" `Quick test_host_watch ] );
      ("email", [ Alcotest.test_case "invite email" `Quick test_email ]);
    ]
