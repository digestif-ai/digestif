(* The textual forms of keys, hashes and signatures (protocol.md, Encoding). *)

let ed25519_prefix = "ed25519:"
let x25519_prefix = "x25519:"
let sha256_prefix = "sha256:"

let strip prefix s =
  let n = String.length prefix in
  if String.length s > n && String.sub s 0 n = prefix then Some (String.sub s n (String.length s - n))
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
let public (k : Crypto.signing_key) = encode_ed25519 k.pub
let encryption_public (k : Crypto.encryption_key) = encode_x25519 k.public
let hash_of_bytes s = sha256_prefix ^ Crypto.sha256_hex s

let is_hash s =
  match strip sha256_prefix s with
  | Some h -> String.length h = 64 && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) h
  | None -> false

let encode_signature raw = B64url.encode raw

let decode_signature s =
  match B64url.decode s with
  | Ok raw when String.length raw = 64 -> Ok raw
  | Ok _ -> Error "signature is not 64 bytes"
  | Error e -> Error e

(* Sign the JCS encoding of [json] with [key]; the form every inner signature in a circle-state body
   takes. *)
let sign_json key json = encode_signature (Crypto.sign key (Jcs.encode json))

let verify_json ~pub ~signature json =
  match (decode_ed25519 pub, decode_signature signature, Jcs.encode_result json) with
  | Ok pub, Ok signature, Ok bytes -> Crypto.verify ~pub ~signature bytes
  | _ -> false
