open Digestif_core
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
  let p = Mail_crypto.X25519.generate () in
  (p, Mail_crypto.X25519.public p)

let test_hkdf () =
  (* RFC 5869, test case 1. *)
  let hex s =
    String.init
      (String.length s / 2)
      (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))
  in
  let okm =
    Mail_crypto.hkdf
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

let options : Ask.choice list =
  [
    { id = "admit"; label = "Admit"; recommended = true };
    { id = "revoke"; label = "Revoke"; recommended = false };
  ]

(* One counter per mail key, never reused. *)
let counter () =
  let n = ref 0 in
  fun () ->
    incr n;
    !n

let presign ?deadline ?(note = fun _ -> None) ~mail_key ~next ~keys ~item
    options =
  List.map
    (fun (c : Ask.choice) ->
      Link.presign_pick ~mail_key ~next_mail_seq:next ~keys
        ~created_at:"2026-10-29T03:17:00.000Z" ~epoch:6 ~item ?deadline
        ?note:(note c) ~title:"Let Phong join?" ~label:c.label c.id)
    options

(* A choice with no deadline: its links expire 30 days after the digest, and the Paused choice's
   Unpause says on its confirm page when it acts. *)
let test_pick_links_expire () =
  let _, k = x_pair () in
  let paused : Ask.t =
    {
      kind = Some "paused";
      title = "Digestif paused. Unpause?";
      detail = "";
      about = None;
      options =
        [
          { id = "unpause"; label = "Unpause"; recommended = true };
          { id = "stay_paused"; label = "Stay paused"; recommended = false };
        ];
      on_no_answer = "stay_paused";
      lapses_at = None;
    }
  in
  let links =
    presign ~note:(Ask.confirm_note paused)
      ~mail_key:(Crypto.generate_signing_key ())
      ~next:(counter ()) ~keys:[ k ]
      ~item:("sha256:" ^ String.make 64 'c')
      paused.options
  in
  List.iter
    (fun (l : Link.t) ->
      Alcotest.(check string)
        "30 days after the digest" "2026-11-28T03:17:00.000Z" l.expires_at)
    links;
  let notes =
    List.map
      (fun (l : Link.t) ->
        Result.to_option
          (Seal.string_member "note"
             (ok (Link.open_answer ~id:l.id ~secret:l.secret l.sealed_answer))))
      links
  in
  Alcotest.(check (list (option string)))
    "Unpause says when the machine acts"
    [ Some "Your machine unpauses when it next syncs, or when it wakes."; None ]
    notes;
  let deadline = "2026-11-01T15:00:00.000Z" in
  Alcotest.(check (list string))
    "a choice's links expire at its deadline" [ deadline; deadline ]
    (List.map
       (fun (l : Link.t) -> l.expires_at)
       (presign ~deadline
          ~mail_key:(Crypto.generate_signing_key ())
          ~next:(counter ()) ~keys:[ k ]
          ~item:("sha256:" ^ String.make 64 'c')
          options))

let test_links () =
  let member_priv, member_key = x_pair () in
  let mail_key = Crypto.generate_signing_key () in
  let mail_text = Keys.public mail_key in
  let item = "sha256:" ^ String.make 64 'c' in
  let next = counter () in
  let links = presign ~mail_key ~next ~keys:[ member_key ] ~item options in
  List.iteri
    (fun i (l : Link.t) ->
      let payload =
        ok (Link.open_answer ~id:l.id ~secret:l.secret l.sealed_answer)
      in
      let signed =
        ok (Link.check_answer ~mail_keys:[ mail_text ] ~ask:item payload)
      in
      let envelope = signed.envelope and body = Option.get signed.body in
      Alcotest.(check (option string))
        "prev is the choice" (Some item) envelope.prev;
      Alcotest.(check int) "chainless seq" (i + 1) envelope.seq;
      Alcotest.(check bool)
        "a pick names no ask" true
        (Result.is_error (Seal.string_member "ask" body));
      let named, option = ok (Ask.decision_of_body ~priv:member_priv body) in
      Alcotest.(check string) "names the choice" item named;
      Alcotest.(check string) "option" (List.nth options i).id option;
      Alcotest.(check (result string string))
        "label" (Ok (List.nth options i).label)
        (Seal.string_member "label" payload);
      is_error "a wrong secret"
        (Link.open_answer ~id:l.id ~secret:(Mail_crypto.random 32)
           l.sealed_answer);
      is_error "another link's id"
        (Link.open_answer ~id:(Mail_crypto.random 16) ~secret:l.secret
           l.sealed_answer);
      is_error "a key of another identity"
        (Link.check_answer ~mail_keys:[] ~ask:item payload);
      is_error "a different item"
        (Link.check_answer ~mail_keys:[ mail_text ]
           ~ask:("sha256:" ^ String.make 64 'd')
           payload))
    links;
  Alcotest.(check int) "one seq per option" 3 (next ());
  is_error "a decision naming an ask"
    (Ask.decision_of_body ~priv:member_priv
       (`Assoc
          [
            ("ask", `String item);
            ( "sealed",
              Seal.seal ~recipients:[ member_key ]
                (`Assoc [ ("option", `String "admit") ]) );
          ]))

let test_digest_end_to_end () =
  let member_priv, member_key = x_pair ()
  and mailer_priv, mailer_key = x_pair () in
  let device_key = Crypto.generate_signing_key ()
  and mail_key = Crypto.generate_signing_key () in
  let item = "sha256:" ^ String.make 64 'e' in
  let w =
    Digest.write ~device_key ~seq:12
      ~prev:("sha256:" ^ String.make 64 'f')
      ~epoch:6 ~created_at:"2026-10-29T03:20:00.000Z" ~date:"2026-10-29"
      ~to_:"mike@example.com"
      ~subject:"Digestif, October 29: 3 in, 1 out, 1 in your Inbox"
      ~sections:
        [
          { title = "Came in"; lines = [ "Roman (Ada): shipped the D1 fold." ] };
        ]
      ~inbox:
        [
          {
            item;
            hash = Some item;
            kind = "choice";
            subject = Some "join";
            title = "Let Phong join?";
            line = "Choice from your node";
            action =
              Pick
                {
                  keys = [ member_key ];
                  options;
                  default = Some "revoke";
                  deadline = None;
                };
          };
        ]
      ~mail_key ~next_mail_seq:(counter ()) ~member_key ~mailer_key ()
  in
  ok (Result.map_error Envelope.error_message (Envelope.verify w.signed));
  let body = Option.get w.signed.body in
  Alcotest.(check string) "hash" w.hash (Envelope.hash w.signed.envelope);
  Alcotest.(check string) "kind" "digest" w.signed.envelope.kind;
  let stored = Yojson.Safe.to_string body in
  List.iter
    (fun (l : Link.t) ->
      let s = B64url.encode l.secret in
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
  Alcotest.(check bool)
    "no asks list" true
    (Result.is_error (Seal.member "asks" email));
  let options =
    match ok (Seal.member "inbox" email) with
    | `List [ e ] -> ok (Seal.member "options" e)
    | _ -> Alcotest.fail "one Inbox entry"
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
  let identity_key = Crypto.generate_signing_key () in
  let mail_pub = (Crypto.generate_signing_key ()).pub in
  let b = Device.body ~identity_key ~key:mail_pub ~role:Bodies.Mail () in
  let _, key, role = ok (Device.verify b) in
  Alcotest.(check string) "key" (Keys.encode_ed25519 mail_pub) key;
  Alcotest.(check string) "role" "mail" role

let test_phone_pairing () =
  let identity_key = Crypto.generate_signing_key () in
  let phone_ed = (Crypto.generate_signing_key ()).pub in
  let phone_x_priv, phone_x = x_pair () in
  let encryption_priv = Mail_crypto.X25519.generate () in
  let code = Phone.pairing_code ~ed25519:phone_ed ~x25519:phone_x in
  let ed, x = ok (Phone.parse_pairing_code ("  " ^ code ^ "\n")) in
  Alcotest.(check string) "ed" phone_ed ed;
  Alcotest.(check string) "x" phone_x x;
  let broken =
    String.mapi
      (fun i c -> if i = 10 then if c = 'A' then 'B' else 'A' else c)
      code
  in
  (* The sentences the UI's mock answers (ui/mock/node.ts), which the Playwright suite reads. *)
  let refused what expected r =
    match r with
    | Ok _ -> Alcotest.failf "%s should have been refused" what
    | Error m -> Alcotest.(check string) what expected m
  in
  refused "a mistyped code"
    "The pairing code's check does not match; retype it."
    (Phone.parse_pairing_code broken);
  refused "not a code"
    "Not a pairing code: it starts with p1. and comes from the phone."
    (Phone.parse_pairing_code "hello");
  refused "keys of the wrong length"
    "Not a pairing code: it starts with p1. and comes from the phone."
    (Phone.parse_pairing_code "p1.AAAA.AAAA");
  let relays = [ "https://relay-1.example"; "https://relay-2.example" ] in
  let body =
    ok (Phone.device_body ~identity_key ~encryption_priv ~relays code)
  in
  let _, key, role = ok (Device.verify body) in
  Alcotest.(check string) "phone key" (Keys.encode_ed25519 phone_ed) key;
  Alcotest.(check string) "role" "device" role;
  let k, identity, rs =
    ok (Phone.open_enrollment ~phone_x25519_priv:phone_x_priv body)
  in
  Alcotest.(check string) "encryption key" encryption_priv k;
  Alcotest.(check string) "identity" (Keys.public identity_key) identity;
  Alcotest.(check (list string)) "relays" relays rs;
  is_error "another phone"
    (Phone.open_enrollment
       ~phone_x25519_priv:(Mail_crypto.X25519.generate ())
       body)

let () =
  Ci_alcotest.run "digestif_mail"
    [
      ("primitives", [ Alcotest.test_case "hkdf" `Quick test_hkdf ]);
      ( "seal",
        [
          Alcotest.test_case "two recipients" `Quick test_seal_two_recipients;
          Alcotest.test_case "tamper" `Quick test_seal_tamper;
        ] );
      ( "links",
        [
          Alcotest.test_case "presign and open" `Quick test_links;
          Alcotest.test_case "expiry and notes" `Quick test_pick_links_expire;
        ] );
      ( "digest",
        [ Alcotest.test_case "end to end" `Quick test_digest_end_to_end ] );
      ( "devices",
        [
          Alcotest.test_case "mail key" `Quick test_device_bodies;
          Alcotest.test_case "phone pairing" `Quick test_phone_pairing;
        ] );
    ]
