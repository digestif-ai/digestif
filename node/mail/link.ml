(* Answer links (docs/protocol.md, Answer links). The mail key pre-signs one decision per option;
   each is sealed under a random secret that only its link carries, so the relays hold answers
   nobody can post without the email. *)

open Digestif_core

type t = {
  id : string;  (** 16 raw bytes *)
  secret : string;  (** 32 raw bytes; never stored by a relay *)
  ask : string;  (** the ask's envelope hash *)
  expires_at : string;
  sealed_answer : string;  (** raw: nonce, then ciphertext with its tag *)
}

let info = "digestif-v0 link"
let adata id = "digestif-v0 link " ^ B64url.encode id
let key ~id ~secret = Mail_crypto.hkdf ~salt:id ~info ~ikm:secret 32

let seal_answer_with ~nonce ~id ~secret payload =
  nonce
  ^ Mail_crypto.aes_gcm_encrypt ~key:(key ~id ~secret) ~nonce ~adata:(adata id)
      (Jcs.encode payload)

let ( let* ) = Result.bind

let open_answer ~id ~secret sealed_answer =
  if String.length sealed_answer < 12 + 16 then Error "sealed answer too short"
  else
    let nonce = String.sub sealed_answer 0 12 in
    let ct = String.sub sealed_answer 12 (String.length sealed_answer - 12) in
    let* p =
      Option.to_result ~none:"wrong secret"
        (Mail_crypto.aes_gcm_decrypt ~key:(key ~id ~secret) ~nonce ~adata:(adata id)
           ct)
    in
    try Ok (Yojson.Safe.from_string p) with Yojson.Json_error e -> Error e

let payload ~ask_title ~label signed =
  `Assoc
    [
      ("ask_title", `String ask_title);
      ("label", `String label);
      ("signed", signed);
    ]

(* Pre-sign the decision for one option and seal it behind a fresh link. [next_mail_seq] hands
   out the mail key's sequence numbers; the caller persists the counter so none is reused. *)
let presign ~mail_key ~next_mail_seq ~member_key ~created_at ~epoch ~ask_hash
    ~(ask : Ask.t) (choice : Ask.choice) =
  let body = Ask.decision_body ~member_key ~ask:ask_hash ~option:choice.id in
  let signed =
    Envelope.create ~key:mail_key ~seq:(next_mail_seq ()) ~prev:ask_hash
      ~created_at ~epoch ~kind:"decision" body
  in
  let id = Mail_crypto.random 16 and secret = Mail_crypto.random 32 in
  {
    id;
    secret;
    ask = ask_hash;
    expires_at = ask.lapses_at;
    sealed_answer =
      seal_answer_with ~nonce:(Mail_crypto.random 12) ~id ~secret
        (payload ~ask_title:ask.title ~label:choice.label
           (Envelope.signed_to_json signed));
  }

(* What the digest body carries for the link: everything but the secret. *)
let record l =
  `Assoc
    [
      ("id", `String (B64url.encode l.id));
      ("ask", `String l.ask);
      ("expires_at", `String l.expires_at);
      ("sealed_answer", `String (B64url.encode l.sealed_answer));
    ]

let url ~relay ~id ~secret =
  let relay =
    if String.ends_with ~suffix:"/" relay then
      String.sub relay 0 (String.length relay - 1)
    else relay
  in
  relay ^ "/v0/links/" ^ B64url.encode id ^ "?s=" ^ B64url.encode secret

(* What a mailing relay checks before appending the decision a confirmed link carries: it
   verifies, it is a decision, its author is one of [mail_keys] (the digest author's admitted mail
   keys, as ed25519:... text) and its prev is the link's ask. Returns the signed envelope. *)
let check_answer ~mail_keys ~ask payload =
  let* json = Seal.member "signed" payload in
  let* signed =
    Result.map_error Envelope.error_message (Envelope.signed_of_json json)
  in
  let* () = Result.map_error Envelope.error_message (Envelope.verify signed) in
  let e = signed.envelope in
  if e.kind <> "decision" then Error "not a decision"
  else if not (List.mem e.author mail_keys) then Error "not_admitted"
  else if e.prev <> Some ask then Error "the decision answers a different ask"
  else Ok signed
