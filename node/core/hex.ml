let encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let decode s =
  let n = String.length s in
  if n mod 2 <> 0 then Error "hex: odd length"
  else
    try Ok (String.init (n / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (i * 2) 2))))
    with _ -> Error "hex: invalid character"
