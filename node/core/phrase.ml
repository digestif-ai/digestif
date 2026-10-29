(* The recovery phrase: 24 BIP39 English words (256 bits of entropy). It is the account. The
   identity signing key and the X25519 encryption key derive from it and are never stored; the node
   holds the phrase only for as long as one signature or one derivation takes.

   seed       = PBKDF2-HMAC-SHA512(phrase, "mnemonic", 2048, 64)          (BIP39, no passphrase)
   identity   = Ed25519 seed  HMAC-SHA512(key = "digestif-v0 identity",   seed)[0..32]
   encryption = X25519 secret HMAC-SHA512(key = "digestif-v0 encryption", seed)[0..32] *)

let words =
  lazy
    (Array.of_list
       (List.filter (( <> ) "") (String.split_on_char '\n' Bip39_words.raw)))

let index_of word =
  let w = Lazy.force words in
  let rec go lo hi =
    if lo > hi then None
    else
      let mid = (lo + hi) / 2 in
      let c = compare word w.(mid) in
      if c = 0 then Some mid
      else if c < 0 then go lo (mid - 1)
      else go (mid + 1) hi
  in
  go 0 (Array.length w - 1)

let bit s i = (Char.code s.[i / 8] lsr (7 - (i mod 8))) land 1

let of_entropy entropy =
  let ent = String.length entropy * 8 in
  if not (List.mem ent [ 128; 160; 192; 224; 256 ]) then
    invalid_arg "Phrase.of_entropy: bad length";
  let cs = ent / 32 in
  let checksum = Crypto.sha256 entropy in
  let bits =
    Array.init (ent + cs) (fun i ->
        if i < ent then bit entropy i else bit checksum (i - ent))
  in
  let w = Lazy.force words in
  String.concat " "
    (List.init
       ((ent + cs) / 11)
       (fun j ->
         let v = ref 0 in
         for k = 0 to 10 do
           v := (!v lsl 1) lor bits.((j * 11) + k)
         done;
         w.(!v)))

let generate () = of_entropy (Crypto.random 32)

let normalize s =
  String.concat " "
    (List.filter (( <> ) "")
       (String.split_on_char ' '
          (String.map
             (function
               | '\n' | '\t' | '\r' -> ' ' | c -> Char.lowercase_ascii c)
             s)))

(* Check the words and the checksum; returns the normalized phrase. *)
let validate s =
  let p = normalize s in
  let ws = String.split_on_char ' ' p in
  let n = List.length ws in
  if not (List.mem n [ 12; 15; 18; 21; 24 ]) then
    Error (Printf.sprintf "a recovery phrase has 24 words, not %d" n)
  else
    (* The position, never the word: an error must not echo any part of a phrase. *)
    match List.find_index (fun w -> index_of w = None) ws with
    | Some i ->
        Error (Printf.sprintf "word %d is not a recovery phrase word" (i + 1))
    | None ->
        let bits = Buffer.create (n * 11) in
        List.iter
          (fun w ->
            let v = Option.get (index_of w) in
            for k = 10 downto 0 do
              Buffer.add_char bits (if (v lsr k) land 1 = 1 then '1' else '0')
            done)
          ws;
        let b = Buffer.contents bits in
        let ent = n * 11 * 32 / 33 in
        let entropy =
          String.init (ent / 8) (fun i ->
              let v = ref 0 in
              for k = 0 to 7 do
                v := (!v lsl 1) lor if b.[(i * 8) + k] = '1' then 1 else 0
              done;
              Char.chr !v)
        in
        if of_entropy entropy = p then Ok p
        else
          Error "the recovery phrase checksum does not match; check each word"

let seed ?(passphrase = "") phrase =
  Crypto.pbkdf2_sha512 ~password:(normalize phrase)
    ~salt:("mnemonic" ^ passphrase) ~iterations:2048 ~length:64

type derived = {
  identity : Crypto.signing_key;
  encryption : Crypto.encryption_key;
}

let derive phrase =
  match validate phrase with
  | Error e -> Error e
  | Ok p -> (
      let s = seed p in
      let part label = String.sub (Crypto.hmac_sha512 ~key:label s) 0 32 in
      match
        ( Crypto.signing_key_of_seed (part "digestif-v0 identity"),
          Crypto.encryption_key_of_secret (part "digestif-v0 encryption") )
      with
      | Ok identity, Ok encryption -> Ok { identity; encryption }
      | Error e, _ | _, Error e -> Error e)
