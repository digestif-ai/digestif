(* base64url without padding (RFC 4648 section 5), the encoding every key and signature uses. *)

let alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let encode s =
  let n = String.length s in
  let b = Buffer.create ((n * 4 / 3) + 4) in
  let byte i = Char.code s.[i] in
  let emit v = Buffer.add_char b alphabet.[v land 63] in
  let rec go i =
    if i + 2 < n then begin
      let v = (byte i lsl 16) lor (byte (i + 1) lsl 8) lor byte (i + 2) in
      emit (v lsr 18);
      emit (v lsr 12);
      emit (v lsr 6);
      emit v;
      go (i + 3)
    end
    else if i + 1 < n then begin
      let v = (byte i lsl 16) lor (byte (i + 1) lsl 8) in
      emit (v lsr 18);
      emit (v lsr 12);
      emit (v lsr 6)
    end
    else if i < n then begin
      let v = byte i lsl 16 in
      emit (v lsr 18);
      emit (v lsr 12)
    end
  in
  go 0;
  Buffer.contents b

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
    let b = Buffer.create (n * 3 / 4) in
    let rec go i acc bits =
      if i = n then
        (* Leftover bits must be zero, so every value has exactly one spelling. *)
        if acc land ((1 lsl bits) - 1) = 0 then Ok (Buffer.contents b)
        else Error "base64url: non-canonical trailing bits"
      else
        match value s.[i] with
        | None -> Error "base64url: invalid character"
        | Some v ->
            let acc = (acc lsl 6) lor v and bits = bits + 6 in
            if bits >= 8 then begin
              Buffer.add_char b (Char.chr ((acc lsr (bits - 8)) land 255));
              go (i + 1) (acc land ((1 lsl (bits - 8)) - 1)) (bits - 8)
            end
            else go (i + 1) acc bits
    in
    go 0 0 0
