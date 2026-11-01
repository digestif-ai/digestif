(* The financial half of the deny layer's built-in detectors (design.md, Guarding what goes out):
   payment card numbers, bank account numbers, crypto wallet addresses and keys, and recovery
   phrases, the node's copy of the shapes behaviors/src/pii.ts checks on the nightly note. They run
   here on every outbound text, a person's own post included, because the node is the one gate
   everything passes before it is signed. Every shape is verified by the check its format carries
   (Luhn, mod 97, the ABA weights, Base58Check, bech32, BIP39), so a number that merely looks like
   one is let through. Dollar amounts and words such as "bank" are not detected: they cannot be told
   from ordinary work. *)

open Digestif_core

let is_digit = function '0' .. '9' -> true | _ -> false

let is_alnum = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | _ -> false

let digits_of s =
  String.concat ""
    (List.map (String.make 1)
       (List.filter is_digit (List.of_seq (String.to_seq s))))

(* Maximal runs of characters satisfying [f], with their start offsets. *)
let runs f text =
  let n = String.length text in
  let rec go i acc =
    if i >= n then List.rev acc
    else if f text.[i] then begin
      let j = ref i in
      while !j < n && f text.[!j] do
        incr j
      done;
      go !j ((i, String.sub text i (!j - i)) :: acc)
    end
    else go (i + 1) acc
  in
  go 0 []

(* Luhn (ISO/IEC 7812). *)
let luhn d =
  let n = String.length d in
  let sum = ref 0 in
  for i = 0 to n - 1 do
    let v = Char.code d.[n - 1 - i] - 48 in
    let v =
      if i mod 2 = 1 then if v * 2 > 9 then (v * 2) - 9 else v * 2 else v
    in
    sum := !sum + v
  done;
  n > 0 && !sum mod 10 = 0

(* Payment card numbers: 13 to 19 digits in groups separated by single spaces or dashes, beginning
   with 3 to 6 or 22 to 27, Luhn-valid. Read as whole groups of a run of digit groups, so a card is
   found inside a longer run of numbers and never across a group. *)
let card text =
  let groups_re = Re.compile (Re.Perl.re {|[0-9]+(?:[ -][0-9]+)*|}) in
  Re.all groups_re text
  |> List.exists (fun g ->
      let start, stop = Re.Group.offset g 0 in
      let before = if start > 0 then Some text.[start - 1] else None in
      let after =
        if stop < String.length text then Some text.[stop] else None
      in
      let glued = function Some c -> c = '-' | None -> false in
      let groups =
        String.split_on_char ' ' (Re.Group.get g 0)
        |> List.concat_map (String.split_on_char '-')
        |> Array.of_list
      in
      let k = Array.length groups in
      let found = ref false in
      for i = 0 to k - 1 do
        for j = i to k - 1 do
          let d =
            String.concat "" (Array.to_list (Array.sub groups i (j - i + 1)))
          in
          let len = String.length d in
          let prefix =
            match d.[0] with
            | '3' .. '6' -> true
            | '2' -> len > 1 && d.[1] >= '2' && d.[1] <= '7'
            | _ -> false
          in
          let edge =
            (i > 0 || not (glued before)) && (j < k - 1 || not (glued after))
          in
          if edge && len >= 13 && len <= 19 && prefix && luhn d then
            found := true
        done
      done;
      !found)

(* ISO 13616 mod 97. *)
let iban_valid s =
  let n = String.length s in
  n >= 15 && n <= 34
  &&
  let r = String.sub s 4 (n - 4) ^ String.sub s 0 4 in
  let rem = ref 0 and ok = ref true in
  String.iter
    (fun c ->
      let piece =
        match c with
        | '0' .. '9' -> String.make 1 c
        | 'A' .. 'Z' -> string_of_int (Char.code c - 55)
        | _ ->
            ok := false;
            ""
      in
      String.iter
        (fun d -> rem := ((!rem * 10) + Char.code d - 48) mod 97)
        piece)
    r;
  !ok && !rem = 1

let iban text =
  let re = Re.compile (Re.Perl.re {|[A-Z][A-Z][0-9][0-9](?:[ -]?[A-Z0-9])+|}) in
  Re.all re text
  |> List.exists (fun g ->
      let start, _ = Re.Group.offset g 0 in
      (start = 0 || not (is_alnum text.[start - 1]))
      &&
      let m = Re.Group.get g 0 in
      (* Every prefix ending at a group's end, longest first: "DE89… EUR" is the IBAN and a word. *)
      let n = String.length m in
      let rec try_end e =
        e >= 15
        && ((e = n || m.[e] = ' ' || m.[e] = '-')
            && iban_valid
                 (String.concat ""
                    (String.split_on_char ' '
                       (String.concat ""
                          (String.split_on_char '-' (String.sub m 0 e)))))
           || try_end (e - 1))
      in
      try_end n)

(* ABA routing number: nine digits, weights 3-7-1, in a Federal Reserve range. *)
let aba_valid d =
  String.length d = 9
  &&
  let v i = Char.code d.[i] - 48 in
  let p = (v 0 * 10) + v 1 in
  (p <= 12 || (p >= 21 && p <= 32) || (p >= 61 && p <= 72) || p = 80)
  && ((3 * (v 0 + v 3 + v 6)) + (7 * (v 1 + v 4 + v 7)) + v 2 + v 5 + v 8)
     mod 10
     = 0

(* A routing number followed within forty characters on the same line by an account number of 6
   to 17 digits; a routing number alone names a bank, not a member. *)
let routing_and_account text =
  let rec go = function
    | (s1, r) :: ((s2, a) :: _ as rest) ->
        let gap =
          String.sub text (s1 + String.length r) (s2 - s1 - String.length r)
        in
        aba_valid r
        && String.length gap >= 1
        && String.length gap <= 40
        && (not (String.contains gap '\n'))
        && String.length a >= 6
        && String.length a <= 17
        || go rest
    | _ -> false
  in
  go (runs is_digit text)

let base58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

(* Base58Check: the payload, when the last four bytes are the first four of its double SHA-256. *)
let base58check_payload s =
  let bytes =
    ref []
    (* little-endian *)
  in
  let ok =
    String.for_all
      (fun c ->
        match String.index_opt base58 c with
        | None -> false
        | Some v ->
            let carry = ref v in
            bytes :=
              List.map
                (fun b ->
                  let x = (b * 58) + !carry in
                  carry := x lsr 8;
                  x land 0xff)
                !bytes;
            while !carry > 0 do
              bytes := !bytes @ [ !carry land 0xff ];
              carry := !carry lsr 8
            done;
            true)
      s
  in
  if not ok then None
  else
    let zeros = ref 0 in
    (try String.iter (fun c -> if c = '1' then incr zeros else raise Exit) s
     with Exit -> ());
    let b =
      String.make !zeros '\000'
      ^ String.of_seq (List.to_seq (List.rev_map Char.chr !bytes))
    in
    let n = String.length b in
    if n < 5 then None
    else
      let payload = String.sub b 0 (n - 4) in
      if
        String.sub (Crypto.sha256 (Crypto.sha256 payload)) 0 4
        = String.sub b (n - 4) 4
      then Some payload
      else None

let bech32_charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

(* BIP173 bech32 or BIP350 bech32m: one case throughout, and the checksum over the human part. *)
let bech32_valid s =
  let lower = String.lowercase_ascii s in
  (s = lower || s = String.uppercase_ascii s)
  &&
  match String.rindex_opt lower '1' with
  | None -> false
  | Some sep when sep < 1 || String.length lower - sep - 1 < 6 -> false
  | Some sep -> (
      let hrp = String.sub lower 0 sep in
      let data = String.sub lower (sep + 1) (String.length lower - sep - 1) in
      match
        List.map
          (String.index_opt bech32_charset)
          (List.of_seq (String.to_seq data))
      with
      | vs when List.mem None vs -> false
      | vs ->
          let gen =
            [| 0x3b6a57b2; 0x26508e6d; 0x1ea119fa; 0x3d4233dd; 0x2a1462b3 |]
          in
          let chk = ref 1 in
          let step v =
            let top = !chk lsr 25 in
            chk := ((!chk land 0x1ffffff) lsl 5) lxor v;
            for i = 0 to 4 do
              if (top lsr i) land 1 = 1 then chk := !chk lxor gen.(i)
            done
          in
          String.iter (fun c -> step (Char.code c lsr 5)) hrp;
          step 0;
          String.iter (fun c -> step (Char.code c land 31)) hrp;
          List.iter (fun v -> step (Option.get v)) vs;
          !chk = 1 || !chk = 0x2bc830a3)

let ethereum_re = Re.compile (Re.Perl.re {|^0x[0-9a-fA-F]{40}$|})

let bech32_re =
  Re.compile
    (Re.Perl.re ~opts:[ `Caseless ]
       {|^(bc|tb|ltc|tltc)1[ac-hj-np-z02-9]{8,87}$|})

(* Crypto wallet addresses and keys, each a whole word: Base58Check with an address's, a key's or
   an extended key's payload (Bitcoin, Litecoin and Dogecoin addresses, WIF keys, BIP32 keys);
   bech32 and bech32m (SegWit and Taproot); and Ethereum's 0x and forty hex digits. *)
let wallet text =
  runs is_alnum text
  |> List.exists (fun (_, w) ->
      let n = String.length w in
      Re.execp ethereum_re w
      || (Re.execp bech32_re w && bech32_valid w)
      || n >= 25 && n <= 112
         && String.for_all (fun c -> String.contains base58 c) w
         &&
         match base58check_payload w with
         | Some p -> List.mem (String.length p) [ 21; 33; 34; 78 ]
         | None -> false)

(* Recovery phrases: 12, 15, 18, 21 or 24 consecutive BIP39 English words, read lowercase and apart
   from anything between them, whose checksum holds. *)
let recovery_phrase text =
  let words =
    runs
      (function 'a' .. 'z' -> true | _ -> false)
      (String.lowercase_ascii text)
    |> List.map snd
  in
  let window_valid run =
    let a = Array.of_list run in
    let k = Array.length a in
    List.exists
      (fun n ->
        let rec at i =
          i + n <= k
          && (Result.is_ok
                (Phrase.validate
                   (String.concat " " (Array.to_list (Array.sub a i n))))
             || at (i + 1))
        in
        at 0)
      [ 24; 21; 18; 15; 12 ]
  in
  let rec go run = function
    | w :: rest when Phrase.index_of w <> None -> go (w :: run) rest
    | rest -> (
        (List.length run >= 12 && window_valid (List.rev run))
        || match rest with [] -> false | _ :: rest -> go [] rest)
  in
  go [] words

let bank_account text = iban text || routing_and_account text
