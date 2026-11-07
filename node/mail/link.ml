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
        (Mail_crypto.aes_gcm_decrypt ~key:(key ~id ~secret) ~nonce
           ~adata:(adata id) ct)
    in
    try Ok (Yojson.Safe.from_string p) with Yojson.Json_error e -> Error e

let payload ?note ~ask_title ~label signed =
  `Assoc
    ([
       ("ask_title", `String ask_title);
       ("label", `String label);
       ("signed", signed);
     ]
    @ match note with Some n -> [ ("note", `String n) ] | None -> [])

(* How long a link answers an ask that never lapses: 30 days after the digest that carried it. *)
let unlapsing_days = 30.0

(* A link expires at its choice's deadline, or 30 days after its digest for one with none. *)
let expires_after ~created_at lapses_at =
  match lapses_at with
  | Some l -> l
  | None -> (
      match Time_fmt.to_unix created_at with
      | Some t -> Time_fmt.of_unix (t +. (unlapsing_days *. 86400.0))
      | None -> invalid_arg ("link: digest time " ^ created_at))

(* Pre-sign [body], a decision answering the envelope [hash], and seal it behind a fresh link.
   [next_mail_seq] hands out the mail key's sequence numbers; the caller persists the counter so
   none is reused. *)
let seal_decision ~mail_key ~next_mail_seq ~created_at ~epoch ~hash ~expires_at
    ?note ~title ~label body =
  let signed =
    Envelope.create ~key:mail_key ~seq:(next_mail_seq ()) ~prev:hash ~created_at
      ~epoch ~kind:"decision" body
  in
  let id = Mail_crypto.random 16 and secret = Mail_crypto.random 32 in
  {
    id;
    secret;
    ask = hash;
    expires_at;
    sealed_answer =
      seal_answer_with ~nonce:(Mail_crypto.random 12) ~id ~secret
        (payload ?note ~ask_title:title ~label (Envelope.signed_to_json signed));
  }

(* ISS-52614: a link that picks an option of an item choice, or acknowledges a notice
   ([option] Ask.acknowledge), sealed to [keys] (Ask.pick_body). It expires at the choice's
   deadline, or 30 days after the digest. *)
let presign_pick ~mail_key ~next_mail_seq ~keys ~created_at ~epoch ~item
    ?deadline ?note ~title ~label option =
  seal_decision ~mail_key ~next_mail_seq ~created_at ~epoch ~hash:item
    ~expires_at:(expires_after ~created_at deadline)
    ?note ~title ~label
    (Ask.pick_body ~keys ~item ~option)

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
