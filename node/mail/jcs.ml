(* RFC 8785 canonical JSON for the bodies this library writes: objects, arrays, strings, integers,
   booleans and null. Floats are refused rather than rendered, since nothing on the wire uses one.
   Object keys sort by UTF-16 code units, as the RFC requires. *)

let utf16_units s =
  let units = ref [] in
  let i = ref 0 in
  let n = String.length s in
  while !i < n do
    let dec = String.get_utf_8_uchar s !i in
    let u = Uchar.to_int (Uchar.utf_decode_uchar dec) in
    if u >= 0x10000 then begin
      let v = u - 0x10000 in
      units := (0xDC00 lor (v land 0x3FF)) :: (0xD800 lor (v lsr 10)) :: !units
    end
    else units := u :: !units;
    i := !i + Uchar.utf_decode_length dec
  done;
  List.rev !units

let compare_keys a b = compare (utf16_units a) (utf16_units b)

let add_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\012' -> Buffer.add_string buf "\\f"
      | '\r' -> Buffer.add_string buf "\\r"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

let rec add buf (j : Yojson.Safe.t) =
  match j with
  | `Null -> Buffer.add_string buf "null"
  | `Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | `Int i -> Buffer.add_string buf (string_of_int i)
  | `Intlit s -> Buffer.add_string buf s
  | `Float _ -> invalid_arg "Jcs.encode: floats are not used on the wire"
  | `String s -> add_string buf s
  | `List l ->
      Buffer.add_char buf '[';
      List.iteri
        (fun i v ->
          if i > 0 then Buffer.add_char buf ',';
          add buf v)
        l;
      Buffer.add_char buf ']'
  | `Assoc kvs ->
      let kvs = List.sort (fun (a, _) (b, _) -> compare_keys a b) kvs in
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char buf ',';
          add_string buf k;
          Buffer.add_char buf ':';
          add buf v)
        kvs;
      Buffer.add_char buf '}'

let encode j =
  let buf = Buffer.create 256 in
  add buf j;
  Buffer.contents buf
