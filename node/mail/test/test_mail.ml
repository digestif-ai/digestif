open Digestif_mail

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let is_error what = function
  | Ok _ -> Alcotest.failf "%s should have been refused" what
  | Error _ -> ()

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  go 0

let x_pair () =
  let p = Crypto.X25519.generate () in
  (p, Crypto.X25519.public p)

let test_jcs () =
  let j =
    `Assoc
      [
        ("b", `List [ `Int 1; `Null; `Bool true ]);
        ("a", `String "tab\there \"q\" \001");
        ("\u{20ac}", `Int 3);
        ("\u{1f600}", `Int 2);
        ("\r", `Int 4);
      ]
  in
  (* RFC 8785 orders keys by UTF-16 code units: U+000D, "a", "b", U+1F600 (a surrogate, 0xD83D),
     then U+20AC... is 0x20AC, which sorts before 0xD83D. *)
  Alcotest.(check string)
    "canonical"
    "{\"\\r\":4,\"a\":\"tab\\there \\\"q\\\" \
     \\u0001\",\"b\":[1,null,true],\"\u{20ac}\":3,\"\u{1f600}\":2}"
    (Jcs.encode j)

let test_hkdf () =
  (* RFC 5869, test case 1. *)
  let hex s =
    String.init
      (String.length s / 2)
      (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))
  in
  let okm =
    Crypto.hkdf
      ~salt:(hex "000102030405060708090a0b0c")
      ~info:(hex "f0f1f2f3f4f5f6f7f8f9")
      ~ikm:(String.make 22 '\x0b') 42
  in
  Alcotest.(check string)
    "okm"
    (hex
       "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    okm

let test_seal_two_recipients () =
  let p1, k1 = x_pair () and p2, k2 = x_pair () and p3, _ = x_pair () in
  let plaintext =
    `Assoc [ ("to", `String "mike@example.com"); ("n", `Int 7) ]
  in
  let sealed = Seal.seal ~recipients:[ k1; k2 ] plaintext in
  Alcotest.check json "member opens" plaintext (ok (Seal.open_ ~priv:p1 sealed));
  Alcotest.check json "mailer opens" plaintext (ok (Seal.open_ ~priv:p2 sealed));
  is_error "a third key" (Seal.open_ ~priv:p3 sealed);
  Alcotest.(check (list string))
    "recipients" [ k1; k2 ]
    (ok (Seal.recipients sealed))

let test_seal_tamper () =
  let p1, k1 = x_pair () in
  let sealed = Seal.seal ~recipients:[ k1 ] (`Assoc [ ("a", `Int 1) ]) in
  let tampered =
    match sealed with
    | `Assoc kvs ->
        `Assoc
          (List.map
             (fun (k, v) ->
               if k = "ciphertext" then
                 match v with
                 | `String s ->
                     ( k,
                       `String
                         ((if s.[0] = 'A' then "B" else "A")
                         ^ String.sub s 1 (String.length s - 1)) )
                 | v -> (k, v)
               else (k, v))
             kvs)
    | j -> j
  in
  is_error "a tampered ciphertext" (Seal.open_ ~priv:p1 tampered)

let ask : Ask.t =
  {
    title = "Introduce Phong to Andrey?";
    detail = "Phong's agent asked for an intro about eval harnesses.";
    about = Some ("sha256:" ^ String.make 64 'b');
    options =
      [
        { id = "yes"; label = "Make the intro"; recommended = true };
        { id = "no"; label = "Decline"; recommended = false };
      ];
    on_no_answer = "no";
    lapses_at = "2026-11-01T15:00:00.000Z";
  }

let test_ask_round_trip () =
  ok (Ask.validate ask);
  let p, k = x_pair () in
  let back = ok (Ask.of_body ~priv:p (Ask.body ~member_key:k ask)) in
  Alcotest.(check string) "title" ask.title back.title;
  Alcotest.(check (list string))
    "options" [ "yes"; "no" ]
    (List.map (fun (c : Ask.choice) -> c.id) back.options);
  Alcotest.(check bool) "recommended" true (List.hd back.options).recommended;
  is_error "no options" (Ask.validate { ask with options = [] });
  is_error "unknown default" (Ask.validate { ask with on_no_answer = "maybe" })

(* One counter per mail key, never reused. *)
let counter () =
  let n = ref 0 in
  fun () ->
    incr n;
    !n

let test_links () =
  let member_priv, member_key = x_pair () in
  let mail_key = Crypto.Ed25519.generate () in
  let mail_text = Keys.ed25519 (Crypto.Ed25519.public mail_key) in
  let ask_hash = "sha256:" ^ String.make 64 'c' in
  let next = counter () in
  let links =
    List.map
      (Link.presign ~mail_key ~next_mail_seq:next ~member_key
         ~created_at:"2026-10-29T03:17:00.000Z" ~epoch:6 ~ask_hash ~ask)
      ask.options
  in
  List.iteri
    (fun i (l : Link.t) ->
      let payload =
        ok (Link.open_answer ~id:l.id ~secret:l.secret l.sealed_answer)
      in
      let signed =
        ok (Link.check_answer ~mail_keys:[ mail_text ] ~ask:ask_hash payload)
      in
      let envelope, body, _ = ok (Envelope.verify signed) in
      Alcotest.(check (result string string))
        "prev is the ask" (Ok ask_hash)
        (Seal.string_member "prev" envelope);
      Alcotest.check json "chainless seq"
        (`Int (i + 1))
        (ok (Seal.member "seq" envelope));
      let a, option = ok (Ask.decision_of_body ~priv:member_priv body) in
      Alcotest.(check string) "names the ask" ask_hash a;
      Alcotest.(check string) "option" (List.nth ask.options i).id option;
      Alcotest.(check (result string string))
        "label" (Ok (List.nth ask.options i).label)
        (Seal.string_member "label" payload);
      is_error "a wrong secret"
        (Link.open_answer ~id:l.id ~secret:(Crypto.random 32) l.sealed_answer);
      is_error "another link's id"
        (Link.open_answer ~id:(Crypto.random 16) ~secret:l.secret
           l.sealed_answer);
      is_error "a key of another identity"
        (Link.check_answer ~mail_keys:[] ~ask:ask_hash payload);
      is_error "a different ask"
        (Link.check_answer ~mail_keys:[ mail_text ]
           ~ask:("sha256:" ^ String.make 64 'd')
           payload))
    links;
  Alcotest.(check int) "one seq per option" 3 (next ())

let test_digest_end_to_end () =
  let member_priv, member_key = x_pair ()
  and mailer_priv, mailer_key = x_pair () in
  let device_key = Crypto.Ed25519.generate ()
  and mail_key = Crypto.Ed25519.generate () in
  let ask_hash = "sha256:" ^ String.make 64 'e' in
  let w =
    Digest.write ~device_key ~seq:12
      ~prev:("sha256:" ^ String.make 64 'f')
      ~epoch:6 ~created_at:"2026-10-29T03:20:00.000Z" ~date:"2026-10-29"
      ~to_:"mike@example.com"
      ~subject:"Digestif, October 29: 3 in, 1 out, 1 ask"
      ~sections:
        [
          { title = "Came in"; lines = [ "Roman (Ada): shipped the D1 fold." ] };
        ]
      ~asks:[ (ask_hash, ask) ]
      ~mail_key ~next_mail_seq:(counter ()) ~member_key ~mailer_key ()
  in
  let envelope, body, hash = ok (Envelope.verify w.signed) in
  Alcotest.(check string) "hash" w.hash hash;
  Alcotest.(check (result string string))
    "kind" (Ok "digest")
    (Seal.string_member "kind" envelope);
  let stored = Yojson.Safe.to_string body in
  List.iter
    (fun (l : Link.t) ->
      let s = B64.encode l.secret in
      if contains stored s then
        Alcotest.fail "a link secret is in the stored digest")
    w.links;
  (* The member's own devices read the email too. *)
  ignore (ok (Seal.open_ ~priv:member_priv (ok (Seal.member "sealed" body))));
  let request = Digest.mail_request ~mailer_key w in
  let email =
    ok
      (Digest.render ~mailer_priv ~relay:"https://relay-1.example/"
         ~digest_body:body ~request)
  in
  let asks = ok (Seal.member "asks" email) in
  let options =
    match asks with
    | `List [ a ] -> ok (Seal.member "options" a)
    | _ -> Alcotest.fail "one ask"
  in
  let urls =
    match options with
    | `List l -> List.map (fun o -> ok (Seal.string_member "link" o)) l
    | _ -> Alcotest.fail "options"
  in
  Alcotest.(check int) "a link per option" 2 (List.length urls);
  List.iter2
    (fun url (l : Link.t) ->
      Alcotest.(check string)
        "url"
        (Link.url ~relay:"https://relay-1.example" ~id:l.id ~secret:l.secret)
        url)
    urls w.links;
  is_error "a relay that is not the mailer"
    (Digest.render ~mailer_priv:member_priv ~relay:"x" ~digest_body:body
       ~request)

let test_device_bodies () =
  let identity_key = Crypto.Ed25519.generate () in
  let mail_pub = Crypto.Ed25519.(public (generate ())) in
  let b = Device.body ~identity_key ~key:mail_pub ~role:"mail" () in
  let _, key, role = ok (Device.verify b) in
  Alcotest.(check string) "key" (Keys.ed25519 mail_pub) key;
  Alcotest.(check string) "role" "mail" role

let test_phone_pairing () =
  let identity_key = Crypto.Ed25519.generate () in
  let phone_ed = Crypto.Ed25519.(public (generate ())) in
  let phone_x_priv, phone_x = x_pair () in
  let encryption_priv = Crypto.X25519.generate () in
  let code = Phone.pairing_code ~ed25519:phone_ed ~x25519:phone_x in
  let ed, x = ok (Phone.parse_pairing_code ("  " ^ code ^ "\n")) in
  Alcotest.(check string) "ed" phone_ed ed;
  Alcotest.(check string) "x" phone_x x;
  let broken =
    String.mapi
      (fun i c -> if i = 10 then if c = 'A' then 'B' else 'A' else c)
      code
  in
  is_error "a mistyped code" (Phone.parse_pairing_code broken);
  is_error "not a code" (Phone.parse_pairing_code "hello");
  let relays = [ "https://relay-1.example"; "https://relay-2.example" ] in
  let body =
    ok (Phone.device_body ~identity_key ~encryption_priv ~relays code)
  in
  let _, key, role = ok (Device.verify body) in
  Alcotest.(check string) "phone key" (Keys.ed25519 phone_ed) key;
  Alcotest.(check string) "role" "device" role;
  let k, identity, rs =
    ok (Phone.open_enrollment ~phone_x25519_priv:phone_x_priv body)
  in
  Alcotest.(check string) "encryption key" encryption_priv k;
  Alcotest.(check string)
    "identity"
    (Keys.ed25519 (Crypto.Ed25519.public identity_key))
    identity;
  Alcotest.(check (list string)) "relays" relays rs;
  is_error "another phone"
    (Phone.open_enrollment ~phone_x25519_priv:(Crypto.X25519.generate ()) body)

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "digestif_mail"
    [
      ( "primitives",
        [
          Alcotest.test_case "jcs" `Quick test_jcs;
          Alcotest.test_case "hkdf" `Quick test_hkdf;
        ] );
      ( "seal",
        [
          Alcotest.test_case "two recipients" `Quick test_seal_two_recipients;
          Alcotest.test_case "tamper" `Quick test_seal_tamper;
        ] );
      ("ask", [ Alcotest.test_case "round trip" `Quick test_ask_round_trip ]);
      ("links", [ Alcotest.test_case "presign and open" `Quick test_links ]);
      ( "digest",
        [ Alcotest.test_case "end to end" `Quick test_digest_end_to_end ] );
      ( "devices",
        [
          Alcotest.test_case "mail key" `Quick test_device_bodies;
          Alcotest.test_case "phone pairing" `Quick test_phone_pairing;
        ] );
    ]
