(* Key text forms: ed25519:<base64url> and x25519:<base64url> (docs/protocol.md, Encoding). *)

let encode prefix raw = prefix ^ ":" ^ B64.encode raw

let decode prefix s =
  let p = prefix ^ ":" in
  let n = String.length p in
  if String.length s > n && String.sub s 0 n = p then
    match B64.decode (String.sub s n (String.length s - n)) with
    | Ok raw when String.length raw = 32 -> Ok raw
    | Ok _ -> Error ("not a 32-byte " ^ prefix ^ " key")
    | Error e -> Error e
  else Error ("not an " ^ prefix ^ " key: " ^ s)

let ed25519 raw = encode "ed25519" raw
let x25519 raw = encode "x25519" raw
let decode_ed25519 = decode "ed25519"
let decode_x25519 = decode "x25519"
let hash s = "sha256:" ^ Crypto.sha256_hex s
