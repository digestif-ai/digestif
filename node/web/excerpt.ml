(* A search hit's excerpt (DIG-128): the passage of its text where the member's words matched, so
   a result says where it matched and not only that it did. The search matches each word against
   the start of a word in the text (Store.Search.query), and so does this, in any ASCII case; the
   UI marks the words in what it returns. A text the words do not match as written here (a match
   the tokenizer found through a diacritic) reads from its start. *)

open Digestif_core

let is_word_byte ch =
  match ch with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | ch -> Char.code ch >= 128

(* The words of what the member typed, lower case, each holding a letter or digit: the words the
   search itself keeps. *)
let words q =
  String.split_on_char ' '
    (String.map
       (function '\t' | '\n' | '\r' -> ' ' | ch -> Char.lowercase_ascii ch)
       (String.trim q))
  |> List.filter (fun w -> w <> "" && String.exists is_word_byte w)

(* [text] on one line: every run of whitespace one space. *)
let one_line text =
  let b = Buffer.create (String.length text) in
  let space = ref false in
  String.iter
    (fun ch ->
      match ch with
      | ' ' | '\t' | '\n' | '\r' -> space := true
      | ch ->
          if !space && Buffer.length b > 0 then Buffer.add_char b ' ';
          space := false;
          Buffer.add_char b ch)
    text;
  Buffer.contents b

(* The first byte where a word of the text starts with one of [words]. *)
let first_match words text =
  let lower = String.lowercase_ascii text in
  let n = String.length lower in
  let starts_word i = i = 0 || not (is_word_byte lower.[i - 1]) in
  let at i w =
    let m = String.length w in
    i + m <= n && String.sub lower i m = w
  in
  let rec go i =
    if i >= n then None
    else if starts_word i && List.exists (at i) words then Some i
    else go (i + 1)
  in
  go 0

(* Back from byte [i] to the start of a UTF-8 sequence. *)
let rec char_start s i =
  if i <= 0 then 0
  else if Char.code s.[i] land 0xC0 = 0x80 then char_start s (i - 1)
  else i

(* The excerpt: at most [width] characters of [text] on one line, starting a little before the
   first match at the start of a word, with an ellipsis on each side the text was cut. *)
let of_text ?(before = 40) ?(width = 160) ~q text =
  let text = one_line text in
  let start =
    match first_match (words q) text with
    | None -> 0
    | Some i when i <= before -> 0
    | Some i -> (
        let from = char_start text (i - before) in
        (* Start at a word: after the first space past [from], when it comes before the match. *)
        match String.index_from_opt text from ' ' with
        | Some sp when sp + 1 <= i -> sp + 1
        | _ -> from)
  in
  let rest = String.sub text start (String.length text - start) in
  let shown = Note_preview.clip ~max:width rest in
  (if start > 0 then "…" else "")
  ^ shown
  ^ if String.length shown < String.length rest then "…" else ""
