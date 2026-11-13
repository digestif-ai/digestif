(* ISS-51009: a suggested change to the nightly note prompt (docs/design.md, Suggesting a change
   to the note prompt; protocol.md, Items, subject suggestion).

   A member suggests a whole prompt with one line saying what it changes, and names the members
   who judge it; its author is always one. ISS-52613: it travels as an item, a choice addressed to
   its judges (protocol.md, Items), so it waits in each judge's Inbox and every judge's node tests
   the same pair. From then on each judge's node writes that judge's own note twice, with the
   prompt it stands on and with the suggested one, and shows both blind; the summary the judge
   approves carries the id of the prompt that wrote it and the suggestion it judged. That approval
   is the pick: nothing else is stored, and every judge's node reads the same picks out of the same
   signed record, so every one folds them to the same outcome.

   A ROUND is each judge's next pick, in order: round 1 is each judge's first pick, round 2 each
   one's second, so a judge with a quiet day lines up with the others on the next note. A round is
   decided once every judge has picked in it: all the suggested version adopts it, all the current
   one closes it, and a split runs the pair again. One suggestion runs at a time per judge: the
   oldest one still judging that names them, and a later one waits. A suggestion its author
   retracted is withdrawn. *)

open Digestif_core

type pick = Current | Suggested
type result = Adopted | Not_adopted | Split
type status = Judging | Adopted_status | Not_adopted_status | Withdrawn

let pick_name = function Current -> "current" | Suggested -> "suggested"

let result_name = function
  | Adopted -> "adopted"
  | Not_adopted -> "not_adopted"
  | Split -> "split"

let status_name = function
  | Judging -> "judging"
  | Adopted_status -> "adopted"
  | Not_adopted_status -> "not_adopted"
  | Withdrawn -> "withdrawn"

(* A prompt's id: sha256 of its text as it is written, which a note written with it carries. The
   release's behaviors/prompts/nightly-note.md has one the same way, with no envelope. *)
let prompt_id text = "sha256:" ^ Crypto.sha256_hex text
let placeholder = "{{always_on_rules}}"
let get = Content.get
let str_field = Content.str_field

(* The suggestion as the item its author sends (protocol.md, Items, subject suggestion): a choice
   addressed to its judges, whose title is the change line and whose detail is the prompt. It is
   picked blind on the note's approval page, never by a pick on the item, so the options only name
   the two versions and the current prompt stands while nobody has picked. *)
let option_suggested = "suggested"
let option_current = "current"

let item ~text ~change : Item.t =
  {
    kind = "choice";
    subject = Some "suggestion";
    voice = "person";
    title = change;
    detail = text;
    about = None;
    options =
      [
        {
          id = option_suggested;
          label = "The suggested prompt";
          recommended = false;
        };
        {
          id = option_current;
          label = "The current prompt";
          recommended = false;
        };
      ];
    default = Some option_current;
    deadline = None;
    adopted = None;
  }

(* Whom a suggestion is addressed to: the judges its author names, never the author, who judges it
   anyway; a suggestion only its author judges is addressed to them alone. *)
let to_of ~author named =
  match List.filter (( <> ) author) (List.sort_uniq compare named) with
  | [] -> Item.Members [ author ]
  | l -> Item.Members l

type suggestion = {
  hash : string;
  author : string;  (** identity *)
  created_at : string;
  text : string;
  change : string;
  id : string;  (** the prompt id of [text] *)
  judges : string list;  (** the author first *)
  withdrawn : bool;
}

type round = {
  number : int;
  picks : (string * pick * string) list;  (** judge, pick, signed at *)
  result : result option;
}

type judged = {
  s : suggestion;
  status : status;
  rounds : round list;
  decided_at : string option;
}

let dedupe l =
  List.rev
    (List.fold_left
       (fun acc x -> if List.mem x acc then acc else x :: acc)
       [] l)

(* The picks one summary body makes: the suggestion it judged and which prompt wrote it. *)
let pick_of (b : Yojson.Safe.t) =
  match (str_field "suggestion" b, str_field "prompt" b) with
  | Some s, Some p -> Some (s, p)
  | _ -> None

(* The rounds, in order, up to the first one that decides; then each judge's picks past the
   complete rounds, as the round still open. *)
let rounds_of ~(s : suggestion) (picks : (string * (string * pick) list) list) =
  let nth l k = List.nth_opt l k in
  let judges = s.judges in
  let per j = Option.value (List.assoc_opt j picks) ~default:[] in
  let rec go k acc =
    let these =
      List.filter_map
        (fun j -> Option.map (fun (at, p) -> (j, p, at)) (nth (per j) k))
        judges
    in
    if these = [] then (List.rev acc, None)
    else if List.length these < List.length judges then
      (List.rev ({ number = k + 1; picks = these; result = None } :: acc), None)
    else
      let all p = List.for_all (fun (_, x, _) -> x = p) these in
      let result =
        if all Suggested then Adopted
        else if all Current then Not_adopted
        else Split
      in
      let r = { number = k + 1; picks = these; result = Some result } in
      let at =
        List.fold_left (fun m (_, _, a) -> if a > m then a else m) "" these
      in
      match result with
      | Split -> go (k + 1) (r :: acc)
      | Adopted | Not_adopted -> (List.rev (r :: acc), Some (result, at))
  in
  go 0 []

(* Every suggestion this node can read, oldest first, folded with the picks the circle's summaries
   make. The suggestions are the node's own Inbox rows (Store.Items.suggestions), so the index has
   to be brought up to the log first; [identity_of] maps a summary's signing key to its member. *)
let read (log : Log.t) ~identity_of =
  let rows = Store.Items.suggestions log in
  if rows = [] then []
  else
    let suggestions =
      List.map
        (fun (hash, author, created_at, change, text, named, retracted) ->
          if retracted then
            (* Its words went with its retract: nothing to judge, and nothing to show but that it
               was withdrawn, though the Inbox row still holds the title and prompt it was sent with. *)
            {
              hash;
              author;
              created_at;
              text = "";
              change = "";
              id = "";
              judges = [ author ];
              withdrawn = true;
            }
          else
            {
              hash;
              author;
              created_at;
              text;
              change;
              id = prompt_id text;
              judges = dedupe (author :: named);
              withdrawn = retracted;
            })
        rows
    in
    (* Every summary that judged a suggestion, by the judge's identity, oldest first. *)
    let summaries =
      List.map Log.row_of
        (Log.rows log
           ("SELECT " ^ Log.envelope_columns
          ^ " FROM envelopes WHERE kind = 'summary' AND body LIKE \
             '%\"suggestion\":%' ORDER BY created_at, hash")
           [])
      |> List.filter_map (fun (r : Log.row) ->
          match (r.signed.body, identity_of r.signed.envelope.author) with
          | Some b, Some who when r.retracted_by = None ->
              Option.map
                (fun (sh, p) -> (sh, who, r.signed.envelope.created_at, p))
                (pick_of b)
          | _ -> None)
    in
    List.map
      (fun s ->
        if s.withdrawn then
          { s; status = Withdrawn; rounds = []; decided_at = None }
        else
          let picks =
            List.map
              (fun j ->
                ( j,
                  List.filter_map
                    (fun (sh, who, at, p) ->
                      if sh = s.hash && who = j && at >= s.created_at then
                        Some (at, if p = s.id then Suggested else Current)
                      else None)
                    summaries ))
              s.judges
          in
          let rounds, decided = rounds_of ~s picks in
          match decided with
          | Some (Adopted, at) ->
              { s; status = Adopted_status; rounds; decided_at = Some at }
          | Some (_, at) ->
              { s; status = Not_adopted_status; rounds; decided_at = Some at }
          | None -> { s; status = Judging; rounds; decided_at = None })
      suggestions

let judges_ j ~me = List.mem me j.s.judges

(* The suggestion [me]'s notes are written in two versions with now: the oldest still judging that
   names them. *)
let running (all : judged list) ~me =
  List.find_opt (fun j -> j.status = Judging && judges_ j ~me) all

(* The prompt [me]'s notes are written with: the suggestion they judged that was adopted last. *)
let adopted (all : judged list) ~me =
  List.fold_left
    (fun acc j ->
      if j.status = Adopted_status && judges_ j ~me then
        match acc with
        | Some a when a.decided_at >= j.decided_at -> acc
        | _ -> Some j
      else acc)
    None all

let find (all : judged list) hash = List.find_opt (fun j -> j.s.hash = hash) all

(* What [who] picked in a round, when they picked in it. *)
let pick_in (r : round) who =
  List.find_map (fun (j, p, _) -> if j = who then Some p else None) r.picks
