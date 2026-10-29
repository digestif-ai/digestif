(* JSON Canonicalization Scheme, RFC 8785. Every hash and signature in the protocol is over these
   bytes. Numbers serialize as ECMAScript's Number.prototype.toString does; object members sort by
   their names' UTF-16 code units; strings escape exactly what JSON.stringify escapes. *)

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun s -> raise (Invalid s)) fmt

(* Decode UTF-8 to code points, refusing malformed input: a canonical form needs one reading. *)
let code_points s =
  let n = String.length s in
  let out = ref [] in
  let i = ref 0 in
  let cont k =
    if !i + k >= n then invalid "truncated UTF-8";
    let c = Char.code s.[!i + k] in
    if c land 0xc0 <> 0x80 then invalid "invalid UTF-8 continuation";
    c land 0x3f
  in
  while !i < n do
    let c = Char.code s.[!i] in
    let cp, len =
      if c < 0x80 then (c, 1)
      else if c land 0xe0 = 0xc0 then (((c land 0x1f) lsl 6) lor cont 1, 2)
      else if c land 0xf0 = 0xe0 then
        (((c land 0x0f) lsl 12) lor (cont 1 lsl 6) lor cont 2, 3)
      else if c land 0xf8 = 0xf0 then
        ( ((c land 0x07) lsl 18)
          lor (cont 1 lsl 12)
          lor (cont 2 lsl 6)
          lor cont 3,
          4 )
      else invalid "invalid UTF-8 lead byte"
    in
    let min = match len with 1 -> 0 | 2 -> 0x80 | 3 -> 0x800 | _ -> 0x10000 in
    if cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) then
      invalid "invalid code point";
    out := cp :: !out;
    i := !i + len
  done;
  List.rev !out

let utf16_units s =
  List.concat_map
    (fun cp ->
      if cp < 0x10000 then [ cp ]
      else
        let v = cp - 0x10000 in
        [ 0xd800 lor (v lsr 10); 0xdc00 lor (v land 0x3ff) ])
    (code_points s)

let compare_names a b = compare (utf16_units a) (utf16_units b)

let add_string buf s =
  ignore (code_points s);
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

(* ECMAScript Number::toString for a finite double: the shortest digit string that round-trips,
   placed by the exponent rules of ECMA-262 section 6.1.6.1.20. *)
let number f =
  if not (Float.is_finite f) then invalid "non-finite number";
  if f = 0.0 then "0"
  else
    let sign = if f < 0.0 then "-" else "" in
    let a = Float.abs f in
    let rec shortest p =
      let s = Printf.sprintf "%.*e" (p - 1) a in
      if p >= 17 || float_of_string s = a then s else shortest (p + 1)
    in
    let s = shortest 1 in
    let mantissa, exp =
      match String.index_opt s 'e' with
      | Some i ->
          ( String.sub s 0 i,
            int_of_string (String.sub s (i + 1) (String.length s - i - 1)) )
      | None -> (s, 0)
    in
    let digits = String.concat "" (String.split_on_char '.' mantissa) in
    let digits =
      let j = ref (String.length digits) in
      while !j > 1 && digits.[!j - 1] = '0' do
        decr j
      done;
      String.sub digits 0 !j
    in
    let k = String.length digits and n = exp + 1 in
    let body =
      if k <= n && n <= 21 then digits ^ String.make (n - k) '0'
      else if 0 < n && n <= 21 then
        String.sub digits 0 n ^ "." ^ String.sub digits n (k - n)
      else if -6 < n && n <= 0 then "0." ^ String.make (-n) '0' ^ digits
      else
        let e = n - 1 in
        let first = String.sub digits 0 1 in
        let rest = if k > 1 then "." ^ String.sub digits 1 (k - 1) else "" in
        first ^ rest ^ "e"
        ^ (if e >= 0 then "+" else "-")
        ^ string_of_int (abs e)
    in
    sign ^ body

(* 2^53: past it an integer is not exactly an IEEE double, so it is written as the double would be. *)
let max_safe = 9007199254740992

let rec add buf (j : Yojson.Safe.t) =
  match j with
  | `Null -> Buffer.add_string buf "null"
  | `Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | `Int i when abs i <= max_safe -> Buffer.add_string buf (string_of_int i)
  | `Int i -> Buffer.add_string buf (number (float_of_int i))
  | `Intlit s -> Buffer.add_string buf (number (float_of_string s))
  | `Float f -> Buffer.add_string buf (number f)
  | `String s -> add_string buf s
  | `List l ->
      Buffer.add_char buf '[';
      List.iteri
        (fun i v ->
          if i > 0 then Buffer.add_char buf ',';
          add buf v)
        l;
      Buffer.add_char buf ']'
  | `Assoc fields ->
      let sorted =
        List.stable_sort (fun (a, _) (b, _) -> compare_names a b) fields
      in
      let rec dup = function
        | (a, _) :: ((b, _) :: _ as rest) ->
            if a = b then invalid "duplicate member %S" a else dup rest
        | _ -> ()
      in
      dup sorted;
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char buf ',';
          add_string buf k;
          Buffer.add_char buf ':';
          add buf v)
        sorted;
      Buffer.add_char buf '}'

let encode j =
  let buf = Buffer.create 256 in
  add buf j;
  Buffer.contents buf

let encode_result j = try Ok (encode j) with Invalid m -> Error m
