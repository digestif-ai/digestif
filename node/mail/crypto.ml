(* The primitives every Digestif body is built from, all of which WebCrypto also offers, so a
   Worker can open what a node writes with no crypto dependency (docs/protocol.md, Sealing). *)

(* The caller seeds the generator once at start-up (Mirage_crypto_rng_unix.use_default). *)
let random n = Mirage_crypto_rng.generate n

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))
let sha256_hex s = Digestif.SHA256.(to_hex (digest_string s))

(* RFC 5869, with SHA-256. *)
let hkdf ~salt ~info ~ikm len =
  let hmac key msg = Digestif.SHA256.(to_raw_string (hmac_string ~key msg)) in
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

module Ed25519 = struct
  module E = Mirage_crypto_ec.Ed25519

  type priv = E.priv

  let generate () = fst (E.generate ())

  let of_seed s =
    match E.priv_of_octets s with Ok p -> p | Error _ -> invalid_arg "Ed25519.of_seed"

  let seed p = E.priv_to_octets p
  let public p = E.pub_to_octets (E.pub_of_priv p)
  let sign p msg = E.sign ~key:p msg

  let verify ~public sig_ msg =
    match E.pub_of_octets public with Ok key -> E.verify ~key sig_ ~msg | Error _ -> false
end

module X25519 = struct
  module X = Mirage_crypto_ec.X25519

  (* A private key is its 32 raw bytes; the public half is recomputed when needed. *)
  type priv = string

  let generate () = X.secret_to_octets (fst (X.gen_key ()))

  let public priv =
    match X.secret_of_octets priv with Ok (_, pub) -> pub | Error _ -> invalid_arg "X25519.public"

  let shared ~priv ~public =
    match X.secret_of_octets priv with
    | Error _ -> Error "bad x25519 private key"
    | Ok (secret, _) -> (
        match X.key_exchange secret public with
        | Ok s when s <> String.make 32 '\000' -> Ok s
        | Ok _ -> Error "x25519 shared secret is all zero"
        | Error _ -> Error "bad x25519 public key")
end
