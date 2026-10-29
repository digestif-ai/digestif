(* Fixed-input vectors for the mail constructions, checked in as vectors.json. The WebCrypto
   reference (../webcrypto/mail.test.mjs) opens every one of them, which is the proof that a Worker
   or a phone reads exactly what the node writes. Regenerate with: dune build @runtest --auto-promote *)

open Digestif_mail

let bytes n c = String.make n (Char.chr c)
let b64 = B64.encode

let () =
  let r1 = bytes 32 0x05 and r2 = bytes 32 0x06 in
  let plaintext = `Assoc [ ("hello", `String "digestif"); ("n", `Int 1); ("émoji", `String "🍷") ] in
  let sealed =
    Seal.seal_with ~content_key:(bytes 32 0x01) ~nonce:(bytes 12 0x02)
      ~ephemerals:[ bytes 32 0x03; bytes 32 0x04 ]
      ~recipients:[ Crypto.X25519.public r1; Crypto.X25519.public r2 ]
      plaintext
  in
  let member_priv = bytes 32 0x0d in
  let mail_key = Crypto.Ed25519.of_seed (bytes 32 0x0a) in
  let decision =
    `Assoc
      [
        ("ask", `String ("sha256:" ^ String.make 64 'a'));
        ( "sealed",
          Seal.seal_with ~content_key:(bytes 32 0x0e) ~nonce:(bytes 12 0x0f)
            ~ephemerals:[ bytes 32 0x10 ]
            ~recipients:[ Crypto.X25519.public member_priv ]
            (`Assoc [ ("option", `String "yes") ]) );
      ]
  in
  let signed, hash =
    Envelope.sign ~key:mail_key ~seq:3 ~prev:("sha256:" ^ String.make 64 'a')
      ~created_at:"2026-10-29T03:17:00.000Z" ~epoch:6 ~kind:"decision" decision
  in
  let payload = Link.payload ~ask_title:"Introduce Phong to Andrey?" ~label:"Make the intro" signed in
  let id = bytes 16 0x07 and secret = bytes 32 0x08 in
  let sealed_answer = Link.seal_answer_with ~nonce:(bytes 12 0x09) ~id ~secret payload in
  let phone_ed = Crypto.Ed25519.(public (of_seed (bytes 32 0x0b))) in
  let phone_x = Crypto.X25519.public (bytes 32 0x0c) in
  let x priv = `Assoc [ ("private", `String (b64 priv)); ("public", `String (b64 (Crypto.X25519.public priv))) ] in
  let out =
    `Assoc
      [
        ( "seal",
          `Assoc
            [
              ("recipients", `List [ x r1; x r2 ]);
              ("sealed", sealed);
              ("plaintext_jcs", `String (Jcs.encode plaintext));
            ] );
        ( "link",
          `Assoc
            [
              ("id", `String (b64 id));
              ("secret", `String (b64 secret));
              ("sealed_answer", `String (b64 sealed_answer));
              ("url", `String (Link.url ~relay:"https://relay-1.example" ~id ~secret));
              ("payload_jcs", `String (Jcs.encode payload));
              ("envelope_hash", `String hash);
              ("member", x member_priv);
              ("option", `String "yes");
            ] );
        ( "pairing",
          `Assoc
            [
              ("ed25519", `String (b64 phone_ed));
              ("x25519", `String (b64 phone_x));
              ("code", `String (Phone.pairing_code ~ed25519:phone_ed ~x25519:phone_x));
            ] );
      ]
  in
  print_string (Yojson.Safe.pretty_to_string out);
  print_newline ()
