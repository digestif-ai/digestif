(* The primitives the mail constructions add to digestif_core's, all of which WebCrypto also offers,
   so a Worker can open what a node writes with no crypto dependency (docs/protocol.md, Sealing):
   HKDF-SHA256, AES-256-GCM, and an X25519 exchange that refuses an all-zero secret. Random bytes,
   hashes and Ed25519 are digestif_core's. *)

module Core = Digestif_core

let random = Core.Crypto.random
let sha256 = Core.Crypto.sha256

(* RFC 5869, with SHA-256. *)
let hkdf ~salt ~info ~ikm len =
  let hmac key msg = Core.Crypto.hmac_sha256 ~key msg in
  let prk = hmac salt ikm in
  let buf = Buffer.create len in
  let rec go prev i =
    if Buffer.length buf < len then begin
      let t = hmac prk (prev ^ info ^ String.make 1 (Char.chr i)) in
      Buffer.add_string buf t;
      go t (i + 1)
    end
  in
  go "" 1;
  Buffer.sub buf 0 len

let aes_gcm_encrypt ~key ~nonce ?(adata = "") plaintext =
  let key = Mirage_crypto.AES.GCM.of_secret key in
  Mirage_crypto.AES.GCM.authenticate_encrypt ~key ~nonce ~adata plaintext

let aes_gcm_decrypt ~key ~nonce ?(adata = "") ciphertext =
  let key = Mirage_crypto.AES.GCM.of_secret key in
  Mirage_crypto.AES.GCM.authenticate_decrypt ~key ~nonce ~adata ciphertext

module X25519 = struct
  module X = Mirage_crypto_ec.X25519

  (* A private key is its 32 raw bytes; the public half is recomputed when needed. *)
  type priv = string

  (* Any 32 bytes are an X25519 secret (the exchange clamps them). *)
  let generate () = random 32

  let public priv =
    match X.secret_of_octets priv with
    | Ok (_, pub) -> pub
    | Error _ -> invalid_arg "X25519.public"

  let shared ~priv ~public =
    match X.secret_of_octets priv with
    | Error _ -> Error "bad x25519 private key"
    | Ok (secret, _) -> (
        match X.key_exchange secret public with
        | Ok s when s <> String.make 32 '\000' -> Ok s
        | Ok _ -> Error "x25519 shared secret is all zero"
        | Error _ -> Error "bad x25519 public key")
end
