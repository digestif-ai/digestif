(* The node's half of the checks (docs/design.md, Guarding what goes out; DES-37265, Checks find
   and fix). The checks run in the note's behavior (behaviors/src/checks.ts), which hands the node
   the checked text and what each run removed, by part and by what it broke, never by text. Here:
   reading that into the note's Log, and the check at signing, a backstop that should never fire.

   The backstop runs the deny layer (deny.ml) over the exact bytes signed. A checked version has had
   every match removed, so a trip means a deny entry was added while the note waited, the text
   changed after its checks, or a detector disagrees with itself. It refuses to sign and never
   edits: the note returns to Waiting with the reason on its page. *)

(* parts *)

let known_heading h =
  List.mem (String.lowercase_ascii h) [ "worked on"; "learned"; "stuck on" ]

let heading_re = Re.compile (Re.Perl.re {|^([A-Z][A-Za-z' ]{0,40}?):(.*)$|})

(* A heading line, as behaviors/src/checks.ts reads one: a few words and a colon, the rest of the
   line empty or, for one of the note's own headings, its first words. *)
let heading_of line =
  match Re.exec_opt heading_re line with
  | None -> None
  | Some g ->
      let h = String.trim (Re.Group.get g 1) in
      let words =
        List.length (List.filter (( <> ) "") (String.split_on_char ' ' h))
      in
      if words > 5 then None
      else if known_heading h || String.trim (Re.Group.get g 2) = "" then Some h
      else None

let no_heading = "Note"

(* The note's parts, in order, as (heading, text); text before the first heading is [no_heading]. *)
let parts text =
  let close acc = function
    | None -> acc
    | Some (h, ls) -> (h, String.concat "\n" (List.rev ls)) :: acc
  in
  let acc, cur =
    List.fold_left
      (fun (acc, cur) line ->
        match (heading_of line, cur) with
        | Some h, _ -> (close acc cur, Some (h, [ line ]))
        | None, Some (h, ls) -> (acc, Some (h, line :: ls))
        | None, None -> (acc, Some (no_heading, [ line ])))
      ([], None)
      (String.split_on_char '\n' text)
  in
  List.rev (close acc cur)

(* the backstop *)

(* What tripped, as the page names it: by its type, never by its text. *)
let what_tripped ~deny rule =
  if deny then "A deny list entry"
  else
    let name =
      match String.index_opt rule ':' with
      | Some i ->
          String.trim (String.sub rule (i + 1) (String.length rule - i - 1))
      | None -> rule
    in
    match name with
    | "Key and token shapes" -> "An API key or token"
    | "Private keys" -> "A private key"
    | "Connection strings" -> "A connection string"
    | "Payment card numbers" -> "A payment card number"
    | "Bank account numbers" -> "A bank account number"
    | "Crypto wallets" -> "A crypto wallet address or key"
    | "Recovery phrases" -> "A recovery phrase"
    | "High-entropy strings" -> "A high-entropy string"
    | n -> "A match of " ^ n

type refusal = {
  rule : string;
  entry : string option;  (** the deny entry that tripped *)
  reason : string;  (** the page's words: Not sent. ... Edit it. *)
}

(* The deny layer over the bytes to be signed; a trip names what tripped and the first part it
   tripped in. *)
let backstop ~entries ~allowed text =
  match Deny.check ~entries ~allowed text with
  | Deny.Pass -> None
  | Tripped { rule; entry } ->
      let part =
        List.find_map
          (fun (h, t) ->
            match Deny.check ~entries ~allowed t with
            | Deny.Pass -> None
            | Tripped _ -> Some h)
          (parts text)
      in
      Some
        {
          rule;
          entry;
          reason =
            Printf.sprintf "Not sent. %s matches %s. Edit it."
              (what_tripped ~deny:(entry <> None) rule)
              (Option.value part ~default:"the note");
        }

(* the Log *)

let checks = [ "pii"; "rules" ]

let causes =
  [ "always_on"; "rules"; "learnings"; "deny_list"; "detector"; "person" ]

(* A part or a type is a heading or a detector's name: short, and never a run of the note. *)
let label_max = 60

let label = function
  | `String s when s <> "" && String.length s <= label_max -> Some s
  | _ -> None

(* One removal as the behavior handed it: exactly the fields of a log_removal, and nothing else
   kept, so no text of the note can ride into the Log. *)
let removal (j : Yojson.Safe.t) : Yojson.Safe.t option =
  let f k = match j with `Assoc l -> List.assoc_opt k l | _ -> None in
  match (Option.bind (f "part") label, f "cause", f "count", f "detector") with
  | Some part, Some (`String cause), Some (`Int count), detector
    when List.mem cause causes && count > 0 -> (
      match (cause, Option.map label detector) with
      | "detector", Some (Some d) ->
          Some
            (`Assoc
               [
                 ("part", `String part);
                 ("cause", `String cause);
                 ("detector", `String d);
                 ("count", `Int count);
               ])
      | "detector", _ -> None
      | _, (None | Some None) ->
          Some
            (`Assoc
               [
                 ("part", `String part);
                 ("cause", `String cause);
                 ("count", `Int count);
               ])
      | _, Some (Some _) -> None)
  | _ -> None

let all_some l =
  List.fold_right
    (fun x acc ->
      match (x, acc) with Some x, Some acc -> Some (x :: acc) | _ -> None)
    l (Some [])

(* `digestif note --checks`: the runs the behavior made, as `[{check, removals}]`, read into
   `checked` entries of the note's Log at [at]. *)
let read_runs ~at text : (Yojson.Safe.t list, string) result =
  let bad = Error "--checks is not a list of check runs" in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> bad
  | `List runs -> (
      let run = function
        | `Assoc f -> (
            match (List.assoc_opt "check" f, List.assoc_opt "removals" f) with
            | Some (`String check), Some (`List rs) when List.mem check checks
              ->
                Option.map
                  (fun removals ->
                    `Assoc
                      [
                        ("at", `String at);
                        ("event", `String "checked");
                        ("check", `String check);
                        ("removals", `List removals);
                      ])
                  (all_some (List.map removal rs))
            | _ -> None)
        | _ -> None
      in
      match all_some (List.map run runs) with Some l -> Ok l | None -> bad)
  | _ -> bad

let entry ~at event extra : Yojson.Safe.t =
  `Assoc ([ ("at", `String at); ("event", `String event) ] @ extra)

let written ~at = entry ~at "written" []

let signing_refused ~at =
  entry ~at "signing_refused" [ ("problem", `String "signing_refused") ]
