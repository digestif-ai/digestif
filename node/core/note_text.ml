(* The line a reader is shown for a note: the Feed's row, a note's summary and the digest's Came in
   and Went out lines all read it from here. A note's section headings
   (behaviors/prompts/nightly-note.md) are labels, never content: every note opens with one, and
   the nightly note often puts it on its own line with its text below, so the line shown is the
   first one after the headings, a heading on the same line as its text dropped from it. A heading
   is plain: Worked on: or Worked on; a markdown heading: ## Worked on; or bold: **Worked on:**
   or **Worked on**:. ISS-50720 ISS-53995 *)

let headings = [ "worked on"; "learned"; "stuck on"; "questions" ]

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

let drop n s = String.trim (String.sub s n (String.length s - n))
let drop_prefix p s = if starts_with p s then drop (String.length p) s else s

let unhashed s =
  let n = String.length s in
  let rec past i = if i < n && s.[i] = '#' then past (i + 1) else i in
  match past 0 with 0 -> s | i -> drop i s

(* The line with its heading dropped, "" when the line is only a heading. *)
let without_heading line =
  let t = String.trim line in
  let s = drop_prefix "**" (unhashed t) in
  let lower = String.lowercase_ascii s in
  let rest h =
    if starts_with h lower then
      let r = drop_prefix "**" (drop (String.length h) s) in
      if r = "" then Some ""
      else if r.[0] = ':' then Some (drop_prefix "**" (drop 1 r))
      else None
    else None
  in
  match List.find_map rest headings with Some r -> r | None -> t

(* The note's first line of content, None when the note holds nothing but headings. *)
let content_line s =
  String.split_on_char '\n' s
  |> List.map without_heading
  |> List.find_opt (fun l -> l <> "")

let first_line s =
  match content_line s with
  | Some l -> l
  | None -> (
      match String.index_opt s '\n' with
      | Some i -> String.sub s 0 i
      | None -> s)

(* At most 140 characters, never cutting a UTF-8 sequence in half. *)
let clip s =
  let max = 140 in
  let rec chars i n =
    if i >= String.length s || n = max then i
    else
      let d = String.get_utf_8_uchar s i in
      chars (i + Uchar.utf_decode_length d) (n + 1)
  in
  String.sub s 0 (chars 0 0)
