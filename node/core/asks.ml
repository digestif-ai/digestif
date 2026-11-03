(* The node's ask store: what this node needs its member to decide, kept in the log's database. An
   ask is keyed by what it is about (one per invite for a join, `join:<invite key>`), so raising the
   same question again replaces the open one rather than adding a second. Each ask names its
   recommended option and the option that stands when it lapses unanswered. The daily digest
   appends each open ask once, as an ask envelope, and keeps that envelope's hash on the row, which
   is what a decision names. *)

type choice = { id : string; label : string }

(* ISS-42316 (DES-37153, What leaves the machine): the kinds whose words could name what is on the
   member's machine. Local is a property of the kind, fixed here and never set per ask: a local ask
   is shown only on the machine, holds no options of its own, and is never appended to a relay or
   carried by a digest. *)
let local_kinds = [ "repositories" ]
let local_kind = function Some k -> List.mem k local_kinds | None -> false

(* How an answer arrived: the person at this node, a decision envelope (from the laptop's UI, a
   phone, or an answer link), the ask lapsing on its on_no_answer, or a local ask closing itself
   once nothing it asks about waits. *)
type via = Person | Decision of string | Lapse | Closed

type t = {
  key : string;
  kind : string option;
      (** The kind its ask envelope names (docs/protocol.md, Asks and
          decisions); a local kind keeps it off every relay and digest. *)
  title : string;
  detail : string;
  about : string option;  (** The key or hash the answer acts on. *)
  options : choice list;
  recommended : string;
  on_no_answer : string;
  lapses_at : string option;  (** None: it never lapses. *)
  raised_at : string;
  answer : string option;
  answered_at : string option;
  envelope : string option;
      (** The ask envelope the digest appended for it, once it has. *)
  answered_via : via option;
}

let options_json options =
  Yojson.Safe.to_string
    (`List
       (List.map
          (fun c -> `Assoc [ ("id", `String c.id); ("label", `String c.label) ])
          options))

let options_of_json s =
  match Yojson.Safe.from_string s with
  | `List l ->
      List.filter_map
        (function
          | `Assoc f -> (
              match (List.assoc_opt "id" f, List.assoc_opt "label" f) with
              | Some (`String id), Some (`String label) -> Some { id; label }
              | _ -> None)
          | _ -> None)
        l
  | _ -> []
  | exception _ -> []

let validate a =
  let ids = List.map (fun c -> c.id) a.options in
  if local_kind a.kind then
    if a.options = [] then Ok ()
    else Error "a local ask is answered on its own page and holds no options"
  else if a.options = [] then Error "an ask needs at least one option"
  else if List.length (List.sort_uniq compare ids) <> List.length ids then
    Error "option ids repeat"
  else if not (List.mem a.recommended ids) then
    Error "the recommended option is not one of the options"
  else if not (List.mem a.on_no_answer ids) then
    Error "on_no_answer is not one of the options"
  else Ok ()

let columns =
  "key, kind, title, detail, about, options, recommended, on_no_answer, \
   lapses_at, raised_at, answer, answered_at, envelope, answered_via, decision"

let via_of_row via decision =
  match (Log.text_opt via, Log.text_opt decision) with
  | Some "decision", Some d -> Some (Decision d)
  | Some "lapse", _ -> Some Lapse
  | Some "closed", _ -> Some Closed
  | Some _, _ -> Some Person
  | None, _ -> None

let via_columns = function
  | Person -> ("person", None)
  | Decision d -> ("decision", Some d)
  | Lapse -> ("lapse", None)
  | Closed -> ("closed", None)

let of_row = function
  | [|
      key;
      kind;
      title;
      detail;
      about;
      options;
      recommended;
      on_no_answer;
      lapses_at;
      raised_at;
      answer;
      answered_at;
      envelope;
      answered_via;
      decision;
    |] ->
      Some
        {
          key = Log.text key;
          kind = Log.text_opt kind;
          title = Log.text title;
          detail = Log.text detail;
          about = Log.text_opt about;
          options = options_of_json (Log.text options);
          recommended = Log.text recommended;
          on_no_answer = Log.text on_no_answer;
          lapses_at = Log.text_opt lapses_at;
          raised_at = Log.text raised_at;
          answer = Log.text_opt answer;
          answered_at = Log.text_opt answered_at;
          envelope = Log.text_opt envelope;
          answered_via = via_of_row answered_via decision;
        }
  | _ -> None

(* Raise an ask, or re-raise one under the same key: the question is asked again, open, with what
   it now says, and the next digest carries it again. *)
let raise_ (log : Log.t) ?(raised_at = Time_fmt.now ()) a =
  match validate a with
  | Error e -> Error e
  | Ok () ->
      Log.exec log
        ("INSERT INTO asks (" ^ columns
       ^ ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, \
          NULL) ON CONFLICT (key) DO UPDATE SET kind = excluded.kind, title = \
          excluded.title, detail = excluded.detail, about = excluded.about, \
          options = excluded.options, recommended = excluded.recommended, \
          on_no_answer = excluded.on_no_answer, lapses_at = \
          excluded.lapses_at, raised_at = excluded.raised_at, answer = NULL, \
          answered_at = NULL, envelope = NULL, answered_via = NULL, decision = \
          NULL")
        Log.
          [
            s a.key;
            opt a.kind;
            s a.title;
            s a.detail;
            opt a.about;
            s (options_json a.options);
            s a.recommended;
            s a.on_no_answer;
            opt a.lapses_at;
            s raised_at;
          ];
      Ok ()

let find (log : Log.t) key =
  match
    Log.rows log
      ("SELECT " ^ columns ^ " FROM asks WHERE key = ?")
      [ Log.s key ]
  with
  | [ r ] -> of_row r
  | _ -> None

let list ?(all = false) (log : Log.t) =
  List.filter_map of_row
    (Log.rows log
       ("SELECT " ^ columns ^ " FROM asks"
       ^ (if all then "" else " WHERE answer IS NULL")
       ^ " ORDER BY raised_at, key")
       [])

(* The open asks no digest has carried yet, oldest first. A local ask is never one: no digest
   carries it and no envelope is appended for it. *)
let unappended (log : Log.t) =
  List.filter_map of_row
    (Log.rows log
       ("SELECT " ^ columns
      ^ " FROM asks WHERE answer IS NULL AND envelope IS NULL ORDER BY \
         raised_at, key")
       [])
  |> List.filter (fun a -> not (local_kind a.kind))

(* The ask envelope a digest appended for the ask under [key]. A local ask is refused: it never
   leaves the machine, so no envelope can stand for it. *)
let appended (log : Log.t) ~key ~envelope =
  match find log key with
  | Some a when local_kind a.kind ->
      Error ("ask " ^ key ^ " is local and is never appended")
  | _ ->
      Log.exec log "UPDATE asks SET envelope = ? WHERE key = ?"
        Log.[ s envelope; s key ];
      Ok ()

(* Raise the local ask under [key] while [open_] holds, keeping when it was first raised and
   refreshing its words; close it once [open_] no longer holds. Nothing else answers a local ask:
   it closes itself when what it asks about is decided where it is decided. *)
let hold_local (log : Log.t) ?(at = Time_fmt.now ()) ~open_ (a : t) =
  if not (local_kind a.kind) then Error ("ask " ^ a.key ^ " is not local")
  else
    match (find log a.key, open_) with
    | Some { answer = None; _ }, true ->
        Log.exec log "UPDATE asks SET title = ?, detail = ? WHERE key = ?"
          Log.[ s a.title; s a.detail; s a.key ];
        Ok ()
    | _, true -> raise_ log ~raised_at:at a
    | Some { answer = None; _ }, false ->
        let via, decision = via_columns Closed in
        Log.exec log
          "UPDATE asks SET answer = 'closed', answered_at = ?, answered_via = \
           ?, decision = ? WHERE key = ?"
          Log.[ s at; s via; opt decision; s a.key ];
        Ok ()
    | _, false -> Ok ()

(* An open ask whose lapse time has passed: its on_no_answer option is what stands. An ask with no
   lapse time never lapses. *)
let lapsed ~now a =
  a.answer = None
  &&
  match (Option.bind a.lapses_at Time_fmt.to_unix, Time_fmt.to_unix now) with
  | Some l, Some n -> n >= l
  | _ -> false

let record_answer (log : Log.t) ?(answered_at = Time_fmt.now ()) ?(via = Person)
    ~key choice =
  match find log key with
  | None -> Error ("no ask " ^ key)
  | Some a when local_kind a.kind ->
      Error
        ("ask " ^ key
       ^ " is local: it is answered on its own page and closes itself")
  | Some a when not (List.exists (fun c -> c.id = choice) a.options) ->
      Error
        (Printf.sprintf "%S is not an answer to %s; choose %s" choice key
           (String.concat " or " (List.map (fun c -> c.id) a.options)))
  | Some _ ->
      let via, decision = via_columns via in
      Log.exec log
        "UPDATE asks SET answer = ?, answered_at = ?, answered_via = ?, \
         decision = ? WHERE key = ?"
        Log.[ s choice; s answered_at; s via; opt decision; s key ];
      Ok ()
