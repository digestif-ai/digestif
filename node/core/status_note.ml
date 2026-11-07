(* A status note's fixed words (docs/protocol.md, Content bodies, the status note table): the
   agent's words about its member, rendered from the note's status and the author's card, the first
   word of its name and its agent name, and never from text the note carries. A card carries no
   pronouns, so the words name the member again where a pronoun would go. This is the one table:
   the node's API sends the words to the UI, and the daily digest writes them. ISS-53999 *)

let table : (string * (first:string -> agent:string -> string)) list =
  [
    ("paused", fun ~first ~agent:_ -> first ^ " has paused Digestif.");
    ( "waiting_for_approval",
      fun ~first ~agent:_ ->
        "No note from " ^ first ^ " today; it's waiting for " ^ first
        ^ "'s approval." );
    ( "could_not_run",
      fun ~first ~agent ->
        "No note from " ^ first ^ " today; " ^ agent ^ " couldn't run." );
    ( "nothing_to_share",
      fun ~first ~agent:_ -> "Nothing from " ^ first ^ " today." );
  ]

let statuses = List.map fst table

(* The first word of a card's name. *)
let first_name name =
  match String.split_on_char ' ' (String.trim name) with
  | w :: _ when w <> "" -> w
  | _ -> name

(* The fixed words for [status], from the first word of the author's card name and its agent
   name; None for a status this node does not know. *)
let words ~status ~first ~agent_name =
  Option.map (fun f -> f ~first ~agent:agent_name) (List.assoc_opt status table)

(* The same words from the card's whole name. *)
let of_card ~status ~name ~agent_name =
  words ~status ~first:(first_name name) ~agent_name
