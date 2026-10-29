(* The invite code a guest pastes into the app or opens as digestif://join/<code>.

   It names one relay to bootstrap from and carries 16 random bytes, from which the private half
   of the guest's invite key is derived. Written in Crockford base32 with a check symbol, grouped
   in fours, so a code read off a phone or retyped by hand either parses or is refused, never
   silently wrong. *)

type t = { relay : string; secret : string }

let secret_bytes = 16
let url_prefix = "digestif://join/"
let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
let check_alphabet = alphabet ^ "*~$=U"
let random_secret () = Mirage_crypto_rng.generate secret_bytes

let invite_key t =
  if String.length t.secret <> secret_bytes then
    invalid_arg "invite secret must be 16 bytes";
  Invite_wire.priv_of_seed
    (Invite_wire.sha256_raw ("DIGESTIF-INVITE-V0\n" ^ t.secret))

let invite_public_key t = Invite_wire.public_key (invite_key t)

(* ---- base32 over the secret's bits, most significant first ---- *)

let bits_of_bytes s =
  let n = String.length s * 8 in
  Array.init n (fun i -> (Char.code s.[i / 8] lsr (7 - (i mod 8))) land 1)

(* 16 bytes are 128 bits; 26 symbols carry 130, the two leading bits are zero. *)
let symbols = 26

let encode_secret secret =
  let bits = bits_of_bytes secret in
  let pad = (symbols * 5) - Array.length bits in
  let bit i = if i < pad then 0 else bits.(i - pad) in
  String.init symbols (fun s ->
      let v = ref 0 in
      for j = 0 to 4 do
        v := (!v lsl 1) lor bit ((s * 5) + j)
      done;
      alphabet.[!v])

(* The check symbol is the secret, read as one big-endian number, modulo 37. *)
let check_symbol secret =
  let m =
    String.fold_left (fun acc c -> ((acc * 256) + Char.code c) mod 37) 0 secret
  in
  check_alphabet.[m]

let group4 s =
  let b = Buffer.create (String.length s * 5 / 4) in
  String.iteri
    (fun i c ->
      if i > 0 && i mod 4 = 0 then Buffer.add_char b '-';
      Buffer.add_char b c)
    s;
  Buffer.contents b

let code t =
  group4 (encode_secret t.secret ^ String.make 1 (check_symbol t.secret))

let relay_host relay =
  let strip p s =
    let n = String.length p in
    if String.length s >= n && String.sub s 0 n = p then
      Some (String.sub s n (String.length s - n))
    else None
  in
  match strip "https://" relay with Some h -> h | None -> relay

let to_text t = relay_host t.relay ^ "/" ^ code t
let to_url t = url_prefix ^ to_text t

(* ---- parsing ---- *)

let normalize_symbol c =
  match Char.uppercase_ascii c with
  | 'O' -> Some '0'
  | 'I' | 'L' -> Some '1'
  | c when String.contains check_alphabet c -> Some c
  | _ -> None

let value_of_symbol c = String.index_opt alphabet c

let decode_secret syms =
  let bits = Array.make (symbols * 5) 0 in
  let ok = ref true in
  String.iteri
    (fun s c ->
      match value_of_symbol c with
      | None -> ok := false
      | Some v ->
          for j = 0 to 4 do
            bits.((s * 5) + j) <- (v lsr (4 - j)) land 1
          done)
    syms;
  if (not !ok) || bits.(0) <> 0 || bits.(1) <> 0 then None
  else
    Some
      (String.init secret_bytes (fun i ->
           let v = ref 0 in
           for j = 0 to 7 do
             v := (!v lsl 1) lor bits.(2 + (i * 8) + j)
           done;
           Char.chr !v))

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let normalize_relay host =
  let host =
    if String.length host > 0 && host.[String.length host - 1] = '/' then
      String.sub host 0 (String.length host - 1)
    else host
  in
  if
    String.contains host ':'
    && (String.starts_with ~prefix:"http://" host
       || String.starts_with ~prefix:"https://" host)
  then host
  else "https://" ^ host

let parse input =
  let s = String.trim input in
  let s =
    let lower = String.lowercase_ascii s in
    if String.starts_with ~prefix:url_prefix lower then
      String.sub s (String.length url_prefix)
        (String.length s - String.length url_prefix)
    else s
  in
  match String.rindex_opt s '/' with
  | None ->
      Error
        "An invite code starts with the relay it came from, like \
         relay.example/ABCD-…"
  | Some i -> (
      let host = String.trim (String.sub s 0 i) in
      let raw = String.sub s (i + 1) (String.length s - i - 1) in
      let buf = Buffer.create 32 in
      let bad = ref false in
      String.iter
        (fun c ->
          if c = '-' || is_space c then ()
          else
            match normalize_symbol c with
            | Some c -> Buffer.add_char buf c
            | None -> bad := true)
        raw;
      let syms = Buffer.contents buf in
      if host = "" then Error "The invite code is missing its relay."
      else if !bad || String.length syms <> symbols + 1 then
        Error "That is not a whole invite code. Copy it again from the email."
      else
        match decode_secret (String.sub syms 0 symbols) with
        | None ->
            Error
              "That is not a whole invite code. Copy it again from the email."
        | Some secret ->
            if check_symbol secret <> syms.[symbols] then
              Error "That invite code has a typo. Copy it again from the email."
            else Ok { relay = normalize_relay host; secret })
