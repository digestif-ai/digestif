(* The textual forms of keys, hashes and signatures (protocol.md, Encoding). *)

let ed25519_prefix = "ed25519:"
let x25519_prefix = "x25519:"
let sha256_prefix = "sha256:"

let strip prefix s =
  let n = String.length prefix in
  if String.length s > n && String.sub s 0 n = prefix then
    Some (String.sub s n (String.length s - n))
  else None

let encode_ed25519 raw = ed25519_prefix ^ B64url.encode raw
let encode_x25519 raw = x25519_prefix ^ B64url.encode raw

let decode_32 prefix s =
  match strip prefix s with
  | None -> Error (Printf.sprintf "expected %s<base64url>, got %S" prefix s)
  | Some b -> (
      match B64url.decode b with
      | Ok raw when String.length raw = 32 -> Ok raw
      | Ok _ -> Error (Printf.sprintf "%S is not a 32-byte key" s)
      | Error e -> Error e)

let decode_ed25519 = decode_32 ed25519_prefix
let decode_x25519 = decode_32 x25519_prefix

(* An Ed25519 public key kept as its text: decoding is canonical, so two spellings of one key never
   both parse, and key equality is string equality. *)
type public_key = string

let parse_ed25519 s : (public_key, string) result =
  match decode_ed25519 s with
  | Error e -> Error e
  | Ok raw when Crypto.is_ed25519_public raw -> Ok s
  | Ok _ -> Error (Printf.sprintf "%S is not an Ed25519 public key" s)

let public (k : Crypto.signing_key) = encode_ed25519 k.pub
let encryption_public (k : Crypto.encryption_key) = encode_x25519 k.public
let hash_of_bytes s = sha256_prefix ^ Crypto.sha256_hex s

(* A signing key written to a file is its 32-byte seed in base64url, spelled like the public half
   under "ed25519-secret:". Only a release signer's key is ever written so; a node's keys live in
   the keystore. *)
let ed25519_secret_prefix = "ed25519-secret:"

let encode_secret (k : Crypto.signing_key) =
  ed25519_secret_prefix ^ B64url.encode k.seed

let decode_secret s =
  match strip ed25519_secret_prefix (String.trim s) with
  | None -> Error ("a signing secret starts with " ^ ed25519_secret_prefix)
  | Some b -> (
      match B64url.decode b with
      | Error e -> Error e
      | Ok seed -> Crypto.signing_key_of_seed seed)

let is_hash s =
  match strip sha256_prefix s with
  | Some h ->
      String.length h = 64
      && String.for_all
           (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
           h
  | None -> false

let encode_signature raw = B64url.encode raw

let decode_signature s =
  match B64url.decode s with
  | Ok raw when String.length raw = 64 -> Ok raw
  | Ok _ -> Error "signature is not 64 bytes"
  | Error e -> Error e

let sign key msg = encode_signature (Crypto.sign key msg)

(* Whether [signature] (base64url) by [pub] (ed25519:...) verifies over [msg]. *)
let verify ~pub ~signature msg =
  match (decode_ed25519 pub, decode_signature signature) with
  | Ok pub, Ok signature -> Crypto.verify ~pub ~signature msg
  | _ -> false

(* Sign the JCS encoding of [json] with [key]; the form every inner signature in a circle-state body
   takes. *)
let sign_json key json = sign key (Jcs.encode json)

let verify_json ~pub ~signature json =
  match Jcs.encode_result json with
  | Ok bytes -> verify ~pub ~signature bytes
  | Error _ -> false
