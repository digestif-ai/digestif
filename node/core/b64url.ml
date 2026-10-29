(* base64url without padding (RFC 4648 section 5), the encoding of every key and signature. *)

let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let encode s =
  let n = String.length s in
  let buf = Buffer.create ((n * 4 / 3) + 4) in
  let byte i = Char.code s.[i] in
  let emit v = Buffer.add_char buf alphabet.[v land 63] in
  let i = ref 0 in
  while !i + 2 < n do
    let v = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) lor byte (!i + 2) in
    emit (v lsr 18);
    emit (v lsr 12);
    emit (v lsr 6);
    emit v;
    i := !i + 3
  done;
  (match n - !i with
  | 1 ->
      let v = byte !i lsl 16 in
      emit (v lsr 18);
      emit (v lsr 12)
  | 2 ->
      let v = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) in
      emit (v lsr 18);
      emit (v lsr 12);
      emit (v lsr 6)
  | _ -> ());
  Buffer.contents buf

let value c =
  match c with
  | 'A' .. 'Z' -> Some (Char.code c - 65)
  | 'a' .. 'z' -> Some (Char.code c - 97 + 26)
  | '0' .. '9' -> Some (Char.code c - 48 + 52)
  | '-' -> Some 62
  | '_' -> Some 63
  | _ -> None

let decode s =
  let n = String.length s in
  if n mod 4 = 1 then Error "base64url: impossible length"
  else
    let buf = Buffer.create (n * 3 / 4) in
    let acc = ref 0 and bits = ref 0 and bad = ref false in
    String.iter
      (fun c ->
        match value c with
        | None -> bad := true
        | Some v ->
            acc := (!acc lsl 6) lor v;
            bits := !bits + 6;
            if !bits >= 8 then begin
              bits := !bits - 8;
              Buffer.add_char buf (Char.chr ((!acc lsr !bits) land 0xff))
            end)
      s;
    (* Canonical form only: the unused low bits of the last character are zero. *)
    if !bad then Error "base64url: invalid character"
    else if !acc land ((1 lsl !bits) - 1) <> 0 then Error "base64url: non-canonical padding bits"
    else Ok (Buffer.contents buf)
