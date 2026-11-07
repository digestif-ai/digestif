(* A note's one-line preview, the same on the Feed, a note's summary and the daily digest. A note
   opens with a section heading (behaviors/prompts/nightly-note.md), so the preview is the first
   line after the headings, and a heading on the same line as its text is dropped from it. The
   writer is a model, so a heading comes plain, as Worked on: or without its colon, as a markdown
   heading such as ## Worked on, or in bold with the colon inside or outside the stars.
   ISS-50720 ISS-53994 *)

let headings = [ "worked on"; "learned"; "stuck on"; "questions" ]

let drop_prefix p s =
  if String.starts_with ~prefix:p s then
    Some (String.sub s (String.length p) (String.length s - String.length p))
  else None

(* A markdown heading's hashes. *)
let without_hashes s =
  let n = String.length s in
  let rec go i = if i < n && s.[i] = '#' then go (i + 1) else i in
  match go 0 with 0 -> s | i -> String.trim (String.sub s i (n - i))

let emphasis = [ "**"; "__"; "*"; "_" ]

(* The marker a line opens with, and the line without it. *)
let opening s =
  match
    List.find_map
      (fun m -> Option.map (fun r -> (m, r)) (drop_prefix m s))
      emphasis
  with
  | Some (m, r) -> (Some m, r)
  | None -> (None, s)

let colon s = match drop_prefix ":" s with Some r -> String.trim r | None -> s

(* What follows a heading's words: its colon and closing marker gone, or None when the words run
   on into a sentence (Learned a lot today.). *)
let after_heading ~marker r =
  let r = String.trim r in
  let close r =
    match marker with
    | Some m -> ( match drop_prefix m r with Some r -> Some r | None -> None)
    | None -> None
  in
  if r = "" then Some ""
  else if r.[0] = ':' then
    let r = colon r in
    Some (String.trim (Option.value (close r) ~default:r))
  else Option.map (fun r -> colon (String.trim r)) (close r)

let without_heading line =
  let t = String.trim line in
  let marker, body = opening (without_hashes t) in
  let lower = String.lowercase_ascii body in
  let rest h =
    let n = String.length h in
    if String.length lower >= n && String.sub lower 0 n = h then
      after_heading ~marker (String.sub body n (String.length body - n))
    else None
  in
  match List.find_map rest headings with Some r -> r | None -> t

let first_line s =
  match
    String.split_on_char '\n' s
    |> List.map without_heading
    |> List.find_opt (fun l -> l <> "")
  with
  | Some l -> l
  | None -> (
      match String.index_opt s '\n' with
      | Some i -> String.sub s 0 i
      | None -> s)

(* At most [max] characters, 140 unless given, never cutting a UTF-8 sequence in half. *)
let clip ?(max = 140) s =
  let rec chars i n =
    if i >= String.length s || n = max then i
    else
      let d = String.get_utf_8_uchar s i in
      chars (i + Uchar.utf_decode_length d) (n + 1)
  in
  String.sub s 0 (chars 0 0)

let of_text s = clip (first_line s)
