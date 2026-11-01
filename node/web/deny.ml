(* The deny layer (design.md, Guarding what goes out): code, not a model, checks every outbound
   message before it is signed. The member's deny list (names, domains, ids, regular expressions)
   and the built-in detectors: secrets, and the financial shapes in financial.ml, which no member
   can turn off. A trip refuses the message and names the rule that tripped,
   never the text that tripped it. The circle's own member and agent names never trip a name
   entry, so a list that names a colleague who later joins does not refuse every note. *)

type detector = { name : string; description : string; test : string -> bool }

let rx pattern = Re.compile (Re.Perl.re ~opts:[ `Caseless ] pattern)
let matches re text = Re.execp re text

let any patterns =
  let res = List.map rx patterns in
  fun text -> List.exists (fun re -> matches re text) res

(* Shannon entropy in bits per character. *)
let entropy s =
  let counts = Array.make 256 0 in
  String.iter (fun c -> counts.(Char.code c) <- counts.(Char.code c) + 1) s;
  let n = float_of_int (String.length s) in
  Array.fold_left
    (fun acc c ->
      if c = 0 then acc
      else
        let p = float_of_int c /. n in
        acc -. (p *. Float.log2 p))
    0.0 counts

let token_re = Re.compile (Re.Perl.re "[A-Za-z0-9+/=_-]{32,}")

(* A long token that mixes letters and digits and is close to random: a key nobody recognised the
   shape of. A sha256 hex digest stays under the bar (sixteen symbols, at most four bits each). *)
let high_entropy text =
  List.exists
    (fun g ->
      let t = Re.Group.get g 0 in
      let has f = String.exists f t in
      has (function 'a' .. 'z' -> true | _ -> false)
      && has (function 'A' .. 'Z' -> true | _ -> false)
      && has (function '0' .. '9' -> true | _ -> false)
      && entropy t > 4.2)
    (Re.all token_re text)

let detectors =
  [
    {
      name = "Key and token shapes";
      description = "API keys, bearer tokens, cloud credentials";
      test =
        any
          [
            {|sk-[A-Za-z0-9_-]{16,}|};
            {|\bAKIA[0-9A-Z]{16}\b|};
            {|\bgh[pousr]_[A-Za-z0-9]{30,}|};
            {|\bxox[abprs]-[A-Za-z0-9-]{10,}|};
            {|\bbearer\s+[A-Za-z0-9._~+/-]{20,}|};
            {|\bAIza[0-9A-Za-z_-]{35}\b|};
          ];
    };
    {
      name = "Private keys";
      description = "PEM blocks and raw key material";
      test = any [ {|-----BEGIN [A-Z ]*PRIVATE KEY-----|} ];
    };
    {
      name = "Connection strings";
      description = "Database and service URLs with credentials";
      test = any [ {|[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]+@|} ];
    };
    {
      name = "Payment card numbers";
      description = "Luhn-checked card numbers";
      test = Financial.card;
    };
    {
      name = "Bank account numbers";
      description = "IBANs with their checksum, US routing and account pairs";
      test = Financial.bank_account;
    };
    {
      name = "Crypto wallets";
      description = "Wallet addresses and keys, checksum-verified";
      test = Financial.wallet;
    };
    {
      name = "Recovery phrases";
      description = "BIP39 words with a valid checksum";
      test = Financial.recovery_phrase;
    };
    {
      name = "High-entropy strings";
      description = "Long random-looking values";
      test = high_entropy;
    };
  ]

let kinds = [ "name"; "domain"; "id"; "pattern" ]

(* A pattern the member typed, compiled the way the deny layer will run it. *)
let compile_pattern value =
  match Re.Perl.re ~opts:[ `Caseless ] value with
  | re -> Ok (Re.compile re)
  | exception (Re.Perl.Parse_error | Re.Perl.Not_supported) ->
      Error "That pattern does not compile."

let lower = String.lowercase_ascii

let contains ~needle hay =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n > 0 && go 0

let word_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

(* A name or id matches as a whole word, case-insensitively; a domain matches anywhere. *)
let whole_word ~needle hay =
  let needle = lower needle and hay = lower hay in
  let n = String.length needle and h = String.length hay in
  let boundary i = i < 0 || i >= h || not (word_char hay.[i]) in
  let rec go i =
    i + n <= h
    && ((String.sub hay i n = needle && boundary (i - 1) && boundary (i + n))
       || go (i + 1))
  in
  n > 0 && go 0

let entry_trips (e : Store.deny_entry) text =
  match e.d_kind with
  | "domain" -> contains ~needle:(lower e.value) (lower text)
  | "pattern" -> (
      match compile_pattern e.value with
      | Ok re -> matches re text
      | Error _ -> false)
  | _ -> whole_word ~needle:e.value text

type verdict = Pass | Tripped of { rule : string; entry : string option }

(* [allowed] is the circle's member and agent names. *)
let check ~(entries : Store.deny_entry list) ~allowed text =
  let allowed = List.map lower allowed in
  let entry =
    List.find_opt
      (fun (e : Store.deny_entry) ->
        (not (e.d_kind = "name" && List.mem (lower e.value) allowed))
        && entry_trips e text)
      entries
  in
  match entry with
  | Some e -> Tripped { rule = "deny: " ^ e.d_kind; entry = Some e.d_id }
  | None -> (
      match List.find_opt (fun d -> d.test text) detectors with
      | Some d -> Tripped { rule = "detector: " ^ d.name; entry = None }
      | None -> Pass)
