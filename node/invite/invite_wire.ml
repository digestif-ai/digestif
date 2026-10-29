(* The wire pieces the invite flow needs: base64url, sha256, RFC 8785 JCS, ed25519 keys and
   envelope signing, as fixed by docs/protocol.md. Private to the invite library until it builds
   on the node core's Digestif_core modules. *)

module Ed = Mirage_crypto_ec.Ed25519

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok v -> Ok v
  | Error (`Msg m) -> Error m

let sha256_raw s = Digestif.SHA256.(digest_string s |> to_raw_string)
let sha256_hex s = Digestif.SHA256.(digest_string s |> to_hex)
let sha256_tagged s = "sha256:" ^ sha256_hex s

(* ---- JCS (RFC 8785) over Yojson.Safe.t, without floats ---- *)

(* UTF-16 code units of a UTF-8 string, for RFC 8785 key ordering. *)
let utf16_units s =
  let n = String.length s in
  let units = ref [] in
  let push u = units := u :: !units in
  let byte i = Char.code s.[i] in
  let rec go i =
    if i < n then begin
      let b = byte i in
      let cp, len =
        if b < 0x80 then (b, 1)
        else if b land 0xE0 = 0xC0 && i + 1 < n then
          (((b land 0x1F) lsl 6) lor (byte (i + 1) land 0x3F), 2)
        else if b land 0xF0 = 0xE0 && i + 2 < n then
          ( ((b land 0x0F) lsl 12)
            lor ((byte (i + 1) land 0x3F) lsl 6)
            lor (byte (i + 2) land 0x3F),
            3 )
        else if i + 3 < n then
          ( ((b land 0x07) lsl 18)
            lor ((byte (i + 1) land 0x3F) lsl 12)
            lor ((byte (i + 2) land 0x3F) lsl 6)
            lor (byte (i + 3) land 0x3F),
            4 )
        else (b, 1)
      in
      if cp >= 0x10000 then begin
        let c = cp - 0x10000 in
        push (0xD800 lor (c lsr 10));
        push (0xDC00 lor (c land 0x3FF))
      end
      else push cp;
      go (i + len)
    end
  in
  go 0;
  List.rev !units

let compare_keys a b = compare (utf16_units a) (utf16_units b)

let jcs_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

(* Integers beyond 2^53 are not exactly representable in the IEEE doubles JCS is defined over. *)
let max_safe_int = 9007199254740991

let rec jcs_value buf (v : Yojson.Safe.t) =
  match v with
  | `Null -> Buffer.add_string buf "null"
  | `Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | `Int i ->
      if abs i > max_safe_int then
        invalid_arg "Jcs: integer outside the exact double range";
      Buffer.add_string buf (string_of_int i)
  | `Intlit _ -> invalid_arg "Jcs: integer literal outside the native range"
  | `Float _ -> invalid_arg "Jcs: floats do not appear in Digestif bodies"
  | `String s -> jcs_string buf s
  | `List items ->
      Buffer.add_char buf '[';
      List.iteri
        (fun i x ->
          if i > 0 then Buffer.add_char buf ',';
          jcs_value buf x)
        items;
      Buffer.add_char buf ']'
  | `Assoc fields ->
      let sorted = List.sort (fun (a, _) (b, _) -> compare_keys a b) fields in
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, x) ->
          if i > 0 then Buffer.add_char buf ',';
          jcs_string buf k;
          Buffer.add_char buf ':';
          jcs_value buf x)
        sorted;
      Buffer.add_char buf '}'

let jcs v =
  let buf = Buffer.create 256 in
  jcs_value buf v;
  Buffer.contents buf

(* ---- keys ---- *)

let ed25519_prefix = "ed25519:"
let encode_public pub = ed25519_prefix ^ b64url_encode (Ed.pub_to_octets pub)

let decode_public s =
  let p = String.length ed25519_prefix in
  if String.length s <= p || String.sub s 0 p <> ed25519_prefix then
    Error "not an ed25519 key"
  else
    match b64url_decode (String.sub s p (String.length s - p)) with
    | Error e -> Error e
    | Ok raw -> (
        match Ed.pub_of_octets raw with
        | Ok k -> Ok k
        | Error _ -> Error "not a valid ed25519 public key")

let priv_of_seed seed =
  match Ed.priv_of_octets seed with
  | Ok k -> k
  | Error _ -> invalid_arg "ed25519 seed must be 32 bytes"

let public_key priv = encode_public (Ed.pub_of_priv priv)
let sign priv msg = b64url_encode (Ed.sign ~key:priv msg)

let verify ~key ~signature msg =
  match (decode_public key, b64url_decode signature) with
  | Ok pub, Ok sig_raw -> Ed.verify ~key:pub sig_raw ~msg
  | _ -> false

(* ---- times ---- *)

let iso8601 t = Ptime.to_rfc3339 ~frac_s:3 ~tz_offset_s:0 t

let parse_iso8601 s =
  match Ptime.of_rfc3339 s with Ok (t, _, _) -> Some t | Error _ -> None

(* ---- envelopes ---- *)

type envelope = { json : Yojson.Safe.t; hash : string }

let field name = function `Assoc fs -> List.assoc_opt name fs | _ -> None

let sign_envelope ~author ~seq ?prev ~created_at ~epoch ~kind
    (body : Yojson.Safe.t) =
  let unsigned =
    [
      ("version", `Int 0);
      ("author", `String (public_key author));
      ("seq", `Int seq);
      ("created_at", `String (iso8601 created_at));
      ("epoch", `Int epoch);
      ("kind", `String kind);
      ("body_hash", `String (sha256_tagged (jcs body)));
    ]
    @ match prev with Some p -> [ ("prev", `String p) ] | None -> []
  in
  let signature = sign author (jcs (`Assoc unsigned)) in
  let env = `Assoc (unsigned @ [ ("signature", `String signature) ]) in
  { json = env; hash = sha256_tagged (jcs env) }

(* Checks the envelope's signature and that body_hash binds [body]. *)
let verify_envelope (env : Yojson.Safe.t) (body : Yojson.Safe.t) =
  match env with
  | `Assoc fs -> (
      match
        ( List.assoc_opt "author" fs,
          List.assoc_opt "signature" fs,
          List.assoc_opt "body_hash" fs )
      with
      | ( Some (`String author),
          Some (`String signature),
          Some (`String body_hash) ) ->
          let unsigned =
            `Assoc (List.filter (fun (k, _) -> k <> "signature") fs)
          in
          body_hash = sha256_tagged (jcs body)
          && verify ~key:author ~signature (jcs unsigned)
      | _ -> false)
  | _ -> false

let envelope_hash env = sha256_tagged (jcs env)
