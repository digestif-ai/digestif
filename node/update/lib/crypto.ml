(* Ed25519 keys in their wire spelling, and SHA-256 in its wire spelling (docs/protocol.md,
   "Encoding"). *)

module Ed = Mirage_crypto_ec.Ed25519

let key_prefix = "ed25519:"
let hash_prefix = "sha256:"

(* A public key, kept as its canonical text so equality is string equality. *)
type public_key = string

let public_key_of_string s : (public_key, string) result =
  let p = String.length key_prefix in
  if String.length s <= p || String.sub s 0 p <> key_prefix then
    Error (Printf.sprintf "key %S does not start with %s" s key_prefix)
  else
    match B64url.decode (String.sub s p (String.length s - p)) with
    | Error e -> Error (Printf.sprintf "key %S: %s" s e)
    | Ok raw -> (
        match Ed.pub_of_octets raw with
        | Ok _ -> Ok s
        | Error _ ->
            Error (Printf.sprintf "key %S is not an Ed25519 public key" s))

let raw_public (k : public_key) =
  let p = String.length key_prefix in
  match B64url.decode (String.sub k p (String.length k - p)) with
  | Ok raw -> raw
  | Error e -> invalid_arg e

let public_key_of_secret (secret : Ed.priv) : public_key =
  key_prefix ^ B64url.encode (Ed.pub_to_octets (Ed.pub_of_priv secret))

(* A signing secret on disk is its 32-byte seed in base64url, the same spelling as the public half,
   under "ed25519-secret:". *)
let secret_prefix = "ed25519-secret:"

let secret_to_string secret =
  secret_prefix ^ B64url.encode (Ed.priv_to_octets secret)

let secret_of_string s =
  let s = String.trim s in
  let p = String.length secret_prefix in
  if String.length s <= p || String.sub s 0 p <> secret_prefix then
    Error ("a signing secret starts with " ^ secret_prefix)
  else
    match B64url.decode (String.sub s p (String.length s - p)) with
    | Error e -> Error e
    | Ok raw -> (
        match Ed.priv_of_octets raw with
        | Ok k -> Ok k
        | Error _ -> Error "not an Ed25519 seed")

let secret_of_seed seed =
  match Ed.priv_of_octets seed with
  | Ok k -> k
  | Error _ -> invalid_arg "seed must be 32 bytes"

let sign secret msg = B64url.encode (Ed.sign ~key:secret msg)

let verify (key : public_key) ~signature msg =
  match B64url.decode signature with
  | Error _ -> false
  | Ok raw -> (
      String.length raw = 64
      &&
      match Ed.pub_of_octets (raw_public key) with
      | Ok pub -> Ed.verify ~key:pub raw ~msg
      | Error _ -> false)

let sha256 s = hash_prefix ^ Digestif.SHA256.(to_hex (digest_string s))
