(* base64url with no padding, the only base64 on the wire (docs/protocol.md, Encoding). *)

let encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let decode s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok v -> Ok v
  | Error (`Msg m) -> Error ("bad base64url: " ^ m)
