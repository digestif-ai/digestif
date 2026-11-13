(* ISS-85463: the paragraph of a message an Inbox item came from, with the words that produced it
   marked. The run that wrote the item recorded those words, its [quote]; the node finds them in
   the message it holds and answers the paragraph around them. A quote the message does not hold is
   no span at all, never a guess: the page then shows the link to the message alone. *)

type t = { before : string; quote : string; after : string }

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

(* [text] with every run of whitespace folded to one space, and for each byte of the folded text the
   offset in [text] it came from. *)
let fold text =
  let b = Buffer.create (String.length text) in
  let map = ref [] in
  let last_space = ref true in
  String.iteri
    (fun i c ->
      if is_space c then (
        if not !last_space then (
          Buffer.add_char b ' ';
          map := i :: !map;
          last_space := true))
      else (
        Buffer.add_char b c;
        map := i :: !map;
        last_space := false))
    text;
  (Buffer.contents b, Array.of_list (List.rev !map))

let find_sub ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i =
    if i + n > m then None
    else if String.sub s i n = sub then Some i
    else go (i + 1)
  in
  if n = 0 then None else go 0

(* Where [quote] stands in [text], as byte offsets [start, stop): verbatim, else with whitespace
   folded on both sides, since a model copying a line rarely keeps its line breaks. *)
let locate ~quote text =
  let quote = String.trim quote in
  match find_sub ~sub:quote text with
  | Some i -> Some (i, i + String.length quote)
  | None -> (
      let folded, map = fold text in
      let q, _ = fold quote in
      let q = String.trim q in
      match find_sub ~sub:q folded with
      | Some i when q <> "" -> Some (map.(i), map.(i + String.length q - 1) + 1)
      | _ -> None)

(* The start of the paragraph holding offset [i]: just past the blank line before it. *)
let rec para_start text i =
  if i <= 0 then 0
  else if text.[i - 1] = '\n' && blank_line_before text (i - 1) then i
  else para_start text (i - 1)

(* Whether the newline at [nl] closes a line holding only whitespace, or opens the text. *)
and blank_line_before text nl =
  let rec back j =
    if j < 0 then true
    else
      match text.[j] with
      | '\n' -> true
      | ' ' | '\t' | '\r' -> back (j - 1)
      | _ -> false
  in
  back (nl - 1)

let rec para_stop text i =
  let n = String.length text in
  if i >= n then n
  else if text.[i] = '\n' && blank_line_after text (i + 1) then i
  else para_stop text (i + 1)

and blank_line_after text j =
  let n = String.length text in
  let rec fwd j =
    if j >= n then true
    else
      match text.[j] with
      | '\n' -> true
      | ' ' | '\t' | '\r' -> fwd (j + 1)
      | _ -> false
  in
  fwd j

(* The paragraph (or paragraphs, when the quote spans a blank line) of [text] holding [quote], split
   around it; None when [text] does not hold it. *)
let find ~quote text =
  match locate ~quote text with
  | None -> None
  | Some (start, stop) ->
      let p0 = para_start text start and p1 = para_stop text stop in
      let cut a b = String.sub text a (b - a) in
      let before = cut p0 start and after = cut stop p1 in
      let lstrip s =
        let n = String.length s in
        let rec go i = if i < n && is_space s.[i] then go (i + 1) else i in
        let i = go 0 in
        String.sub s i (n - i)
      in
      let rstrip s =
        let rec go i = if i > 0 && is_space s.[i - 1] then go (i - 1) else i in
        String.sub s 0 (go (String.length s))
      in
      Some
        { before = lstrip before; quote = cut start stop; after = rstrip after }

let to_json t : Yojson.Safe.t =
  `Assoc
    [
      ("before", `String t.before);
      ("quote", `String t.quote);
      ("after", `String t.after);
    ]
