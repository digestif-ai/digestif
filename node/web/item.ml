(* Items on the wire (docs/protocol.md, Items): the item itself, its To, and the bodies of the
   envelopes that carry it, answer it, close it and pick on it, with the rules every node reads the
   same way from them: which close stands, and when a question or a choice closes with no close of
   its own. Nothing here touches the log or the store.

     item:        { "to": "circle", "item": <item> }
                  { "to": [ "ed25519:..." ], "sealed": <sealed item> }
     item_answer: { "item": "sha256:...", "text": "...", "voice": "person" }
                  { "item": "sha256:...", "to": [ ... ], "sealed": <sealed { text, voice }> }
     item_close:  { "item": "sha256:...", "closed": true, "answer": "sha256:...", "voice": "agent" }
                  { "item": "sha256:...", "to": [ ... ], "sealed": <sealed { closed, answer, voice }> }
     decision:    { "item": "sha256:...", "sealed": <sealed { "option": "..." }> } *)

let kinds = [ "question"; "choice"; "notice" ]

let subjects =
  [
    "note_question";
    "intro";
    "share";
    "work";
    "credit";
    "behavior";
    "practice";
    "suggestion";
    "join";
    "paused";
    "note_ready";
    "could_not_run";
    "pause_coming";
    "repositories";
    "skipped_projects";
  ]

(* Local is a property of the subject, fixed here and never set per item: a local item is never on
   the wire, mailed or shown off the machine. *)
let local_subject = function
  | Some ("repositories" | "skipped_projects") -> true
  | _ -> false

(* DIG-355: where on this machine a node's notice is acted on, and the one line that says what to do
   there. Both are fixed by the subject, so neither can name a repository, a path or a failure. *)
let notice_page = function
  | "repositories" -> Some "/settings/repositories/edit"
  | "note_ready" | "pause_coming" | "could_not_run" -> Some "/feed"
  | _ -> None

let notice_instruction = function
  | "repositories" ->
      Some
        "Decide whether Digestif may read it. Nothing is read until you say so."
  | "note_ready" -> Some "Read the note and approve it, edit it or dismiss it."
  | "could_not_run" -> Some "Open it to see why Digestif could not run."
  | "pause_coming" ->
      Some "Approve the waiting note before the pause, or Digestif pauses."
  | _ -> None

(* The subjects a member writes on New item; every other subject comes from an agent or the node. *)
let member_subjects = [ "intro"; "suggestion" ]

(* A question with no answer this long after it was sent closes by itself. *)
let question_lapse = 7.0 *. 86_400.0

type option_ = { id : string; label : string; recommended : bool }

type t = {
  kind : string;
  subject : string option;
  voice : string;  (** person, agent or node *)
  title : string;
  detail : string;
  about : string option;
  options : option_ list;  (** a choice's; empty otherwise *)
  default : string option;  (** a choice's option with no pick *)
  deadline : string option;  (** when a choice's default takes effect *)
}

type to_ = Circle | Members of string list  (** identities *)

let get name = function `Assoc f -> List.assoc_opt name f | _ -> None

let str_field name j =
  match get name j with Some (`String s) -> Some s | _ -> None

let opt_pair name = function Some v -> [ (name, `String v) ] | None -> []

(* A reader treats a missing or unknown voice as the agent's. *)
let voice_of ?(allowed = [ "person"; "agent"; "node" ]) j =
  match str_field "voice" j with
  | Some v when List.mem v allowed -> v
  | _ -> "agent"

let option_json o : Yojson.Safe.t =
  `Assoc
    ([ ("id", `String o.id); ("label", `String o.label) ]
    @ if o.recommended then [ ("recommended", `Bool true) ] else [])

let to_json t : Yojson.Safe.t =
  `Assoc
    ([ ("kind", `String t.kind) ]
    @ opt_pair "subject" t.subject
    @ [
        ("voice", `String t.voice);
        ("title", `String t.title);
        ("detail", `String t.detail);
      ]
    @ opt_pair "about" t.about
    @
    if t.kind = "choice" then
      [ ("options", `List (List.map option_json t.options)) ]
      @ opt_pair "default" t.default
      @ opt_pair "deadline" t.deadline
    else [])

let ( let* ) = Result.bind

let options_of j =
  match get "options" j with
  | Some (`List l) ->
      List.fold_right
        (fun o acc ->
          let* acc = acc in
          match (str_field "id" o, str_field "label" o) with
          | Some id, Some label ->
              Ok
                ({
                   id;
                   label;
                   recommended = get "recommended" o = Some (`Bool true);
                 }
                :: acc)
          | _ -> Error "an option needs an id and a label")
        l (Ok [])
  | _ -> Error "a choice needs options"

(* An item as the wire carries it, or why it is malformed. A kind this node does not know is an
   error too: a node ignores an item when it cannot tell what it asks of its reader. *)
let of_json j =
  let* kind =
    match str_field "kind" j with
    | Some k when List.mem k kinds -> Ok k
    | _ -> Error "an unknown kind"
  in
  let* title =
    match str_field "title" j with
    | Some t when String.trim t <> "" -> Ok t
    | _ -> Error "an item needs a title"
  in
  let detail = Option.value (str_field "detail" j) ~default:"" in
  let subject =
    match str_field "subject" j with
    | Some s when List.mem s subjects -> Some s
    | _ -> None
  in
  let* options, default, deadline =
    if kind <> "choice" then Ok ([], None, None)
    else
      let* options = options_of j in
      let ids = List.map (fun o -> o.id) options in
      let default = str_field "default" j in
      if List.length options < 2 then Error "a choice needs two options"
      else if List.length (List.sort_uniq compare ids) <> List.length ids then
        Error "an option id is repeated"
      else if List.length (List.filter (fun o -> o.recommended) options) > 1
      then Error "more than one option is recommended"
      else
        match default with
        | Some d when List.mem d ids ->
            Ok (options, default, str_field "deadline" j)
        | _ -> Error "a choice's default names no option"
  in
  Ok
    {
      kind;
      subject;
      voice = voice_of j;
      title;
      detail;
      about = str_field "about" j;
      options;
      default;
      deadline;
    }

(* What the deny layer reads of an item before it is signed: every word a reader is shown. *)
let words t =
  String.concat "\n"
    (t.title :: t.detail :: List.map (fun o -> o.label) t.options
    |> List.filter (( <> ) ""))

let to_list = function Circle -> [] | Members l -> l

let to_field to_ : string * Yojson.Safe.t =
  match to_ with
  | Circle -> ("to", `String "circle")
  | Members l -> ("to", `List (List.map (fun s -> `String s) l))

let to_of j =
  match get "to" j with
  | Some (`String "circle") -> Some Circle
  | Some (`List (_ :: _ as l)) ->
      let ids =
        List.filter_map (function `String s -> Some s | _ -> None) l
      in
      if List.length ids = List.length l then Some (Members ids) else None
  | _ -> None

(* [keys] are the raw X25519 public keys a named body is sealed to: every reader's and the
   author's own. *)
let seal ~keys plaintext = Digestif_mail.Seal.seal ~recipients:keys plaintext

let item_body ~to_ ~keys t : Yojson.Safe.t =
  match to_ with
  | Circle -> `Assoc [ to_field Circle; ("item", to_json t) ]
  | Members _ -> `Assoc [ to_field to_; ("sealed", seal ~keys (to_json t)) ]

(* An answer or a close follows its item's To: plaintext beside the item's hash on a circle item,
   sealed to every reader of a named one. *)
let follow_body ~item ~to_ ~keys fields : Yojson.Safe.t =
  match to_ with
  | Circle -> `Assoc (("item", `String item) :: fields)
  | Members _ ->
      `Assoc
        [
          ("item", `String item);
          to_field to_;
          ("sealed", seal ~keys (`Assoc fields));
        ]

let answer_body ~item ~to_ ~keys ~text ~voice =
  follow_body ~item ~to_ ~keys
    [ ("text", `String text); ("voice", `String voice) ]

let close_body ~item ~to_ ~keys ~closed ?answer ~voice () =
  follow_body ~item ~to_ ~keys
    ([ ("closed", `Bool closed) ]
    @ opt_pair "answer" answer
    @ [ ("voice", `String voice) ])

(* A pick is a decision sealed to the picker and the choice's author. *)
let pick_body ~item ~keys ~option : Yojson.Safe.t =
  `Assoc
    [
      ("item", `String item);
      ("sealed", seal ~keys (`Assoc [ ("option", `String option) ]));
    ]

let open_sealed ~priv body =
  match get "sealed" body with
  | None -> None
  | Some s -> Result.to_option (Digestif_mail.Seal.open_ ~priv s)

(* The item an "item" body carries, when this member can read it: every circle item, and a named
   one sealed to them. A malformed or unknown item reads as None, as one sealed to someone else. *)
let read_item ~priv body =
  match to_of body with
  | None -> None
  | Some Circle ->
      Option.bind (get "item" body) (fun j ->
          Option.map (fun t -> (Circle, t)) (Result.to_option (of_json j)))
  | Some (Members _ as to_) ->
      Option.bind (open_sealed ~priv body) (fun j ->
          Option.map (fun t -> (to_, t)) (Result.to_option (of_json j)))

(* The fields an answer or a close carries, in the clear or opened. *)
let read_follow ~priv body =
  match str_field "item" body with
  | None -> None
  | Some item -> (
      match get "sealed" body with
      | None -> Some (item, body)
      | Some _ -> Option.map (fun j -> (item, j)) (open_sealed ~priv body))

type answer = { a_item : string; text : string; a_voice : string }

let read_answer ~priv body =
  Option.bind (read_follow ~priv body) (fun (item, j) ->
      match str_field "text" j with
      | Some text ->
          Some
            {
              a_item = item;
              text;
              a_voice = voice_of ~allowed:[ "person"; "agent" ] j;
            }
      | None -> None)

type close = {
  c_item : string;
  closed : bool;
  answer : string option;
  c_voice : string;
}

let read_close ~priv body =
  Option.bind (read_follow ~priv body) (fun (item, j) ->
      match get "closed" j with
      | Some (`Bool closed) ->
          Some
            {
              c_item = item;
              closed;
              answer = str_field "answer" j;
              c_voice = voice_of ~allowed:[ "person"; "agent" ] j;
            }
      | _ -> None)

(* The choice a decision picks on and the option, when it is a pick this member can open; a
   decision on an ask names no item. *)
let read_pick ~priv body =
  match str_field "item" body with
  | None -> None
  | Some item ->
      Option.bind (open_sealed ~priv body) (fun j ->
          Option.map (fun o -> (item, o)) (str_field "option" j))

(* Which close stands: the newest in the person's voice, in the fold order (when, then hash), and
   with none the newest in the agent's. [closes] are (voice, at, hash, value). *)
let standing closes =
  let newest voice =
    List.filter (fun (v, _, _, _) -> v = voice) closes
    |> List.sort (fun (_, a, h, _) (_, b, g, _) -> compare (b, g) (a, h))
    |> function
    | x :: _ -> Some x
    | [] -> None
  in
  match newest "person" with Some x -> Some x | None -> newest "agent"

(* Whether a choice is closed by its picks: one addressed to one member on that member's first
   pick, one addressed to several when every member it names has picked; a circle choice, and a
   suggestion, never by picks. [picked] is the identities with a pick that counts. *)
let closed_by_picks ~subject ~to_ ~picked =
  subject <> Some "suggestion"
  &&
  match to_ with
  | Circle -> false
  | Members l -> l <> [] && List.for_all (fun m -> List.mem m picked) l

(* When the item closes by the clock, with no close of its own: a question with no answer a week
   after it was sent, a choice at its deadline. *)
let closes_at ~kind ~sent ~deadline ~answered =
  match kind with
  | "question" when not answered -> Some (sent +. question_lapse)
  | "choice" -> deadline
  | _ -> None
