(* What the local UI keeps that never travels: the member's brief, rules, deny list, source choice,
   mutes, the messages refused before signing, the member's notes and their versions, and the UI's
   launch tokens and sessions. Tables beside the log in the same SQLite file; envelopes stay in Log. *)

open Digestif_core

let schema =
  {|
CREATE TABLE IF NOT EXISTS ui_sources (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  label TEXT NOT NULL,
  paths TEXT NOT NULL,
  yields TEXT NOT NULL,
  selected INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_deny (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  created_at TEXT NOT NULL,
  trips INTEGER NOT NULL DEFAULT 0,
  UNIQUE (kind, value)
);
CREATE TABLE IF NOT EXISTS ui_mutes (
  identity TEXT PRIMARY KEY,
  muted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_outbox (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  voice TEXT NOT NULL,
  recipient TEXT,
  reply_to TEXT,
  text TEXT,
  status TEXT NOT NULL,
  refused_rule TEXT,
  created_at TEXT NOT NULL,
  posted_hash TEXT,
  held_reason TEXT
);
CREATE TABLE IF NOT EXISTS ui_ticks (
  id TEXT PRIMARY KEY,
  at TEXT NOT NULL,
  outcome TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ui_ticks_at ON ui_ticks (at);
CREATE TABLE IF NOT EXISTS ui_launch (
  token_hash TEXT PRIMARY KEY,
  expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_sessions (
  token_hash TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);
|}

(* Columns added after a table was first created, for a data directory that predates them. *)
let added_columns = [ ("ui_outbox", "held_reason", "TEXT") ]

let init_base (log : Log.t) =
  Log.check log.db (Sqlite3.exec log.db schema);
  List.iter
    (fun (table, column, ty) ->
      let present =
        Log.rows log (Printf.sprintf "PRAGMA table_info(%s)" table) []
        |> List.exists (fun r -> Array.length r > 1 && Log.text r.(1) = column)
      in
      if not present then
        Log.exec log
          (Printf.sprintf "ALTER TABLE %s ADD COLUMN %s %s" table column ty)
          [])
    added_columns

let now = Time_fmt.now
let config log key = Log.get_config log key
let set_config log key value = Log.set_config log key value
let random_id () = Hex.encode (Crypto.random 16)
let local_hash () = "sha256:" ^ Crypto.sha256_hex (Crypto.random 32)

(* brief and rules: one text each, with the time it was last saved *)

type text_doc = { text : string; updated_at : string option }

let k_brief = "ui_brief"
let k_rules = "ui_rules"

let default_rules =
  "Never name a customer, an employer-confidential project, a colleague or a \
   third party.\n\
   Never quote code or a log."

let get_doc log key ~default =
  {
    text = Option.value (config log key) ~default;
    updated_at = config log (key ^ "_updated_at");
  }

let set_doc log key text =
  set_config log key text;
  set_config log (key ^ "_updated_at") (now ())

let brief log = get_doc log k_brief ~default:""
let set_brief log text = set_doc log k_brief text
let rules log = get_doc log k_rules ~default:default_rules
let set_rules log text = set_doc log k_rules text

(* sources *)

type source = {
  id : string;
  kind : string;
  label : string;
  paths : string list;
  yields : string list;
  selected : bool;
}

let json_strings l =
  Yojson.Safe.to_string (`List (List.map (fun s -> `String s) l))

let strings_of_json s =
  match Yojson.Safe.from_string s with
  | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
  | _ -> []
  | exception _ -> []

let sources (log : Log.t) =
  List.map
    (function
      | [| id; kind; label; paths; yields; selected |] ->
          {
            id = Log.text id;
            kind = Log.text kind;
            label = Log.text label;
            paths = strings_of_json (Log.text paths);
            yields = strings_of_json (Log.text yields);
            selected = Log.int selected <> 0;
          }
      | _ -> assert false)
    (Log.rows log
       "SELECT id, kind, label, paths, yields, selected FROM ui_sources ORDER \
        BY position"
       [])

(* A command source is the member's own (docs/behaviors.md, Command sources): added and removed by
   them, never by a rediscovery. *)
let k_command = "command"

let insert_source (log : Log.t) ~pos s =
  Log.exec log
    "INSERT INTO ui_sources (id, kind, label, paths, yields, selected, \
     position) VALUES (?, ?, ?, ?, ?, ?, ?)"
    [
      Log.s s.id;
      Log.s s.kind;
      Log.s s.label;
      Log.s (json_strings s.paths);
      Log.s (json_strings s.yields);
      Log.i (if s.selected then 1 else 0);
      Log.i pos;
    ]

(* Replace the offered sources, keeping the member's choice for any id still offered and every
   command source after them. *)
let set_offered (log : Log.t) offered =
  let current = sources log in
  let chosen =
    List.filter_map (fun s -> if s.selected then Some s.id else None) current
  in
  let commands = List.filter (fun s -> s.kind = k_command) current in
  let offered =
    List.filter (fun s -> s.kind <> k_command) offered
    |> List.map (fun s ->
        { s with selected = s.selected || List.mem s.id chosen })
  in
  Log.transaction log (fun () ->
      Log.exec log "DELETE FROM ui_sources" [];
      List.iteri (fun pos s -> insert_source log ~pos s) (offered @ commands))

(* Appends a command source, unselected. The caller has checked the label and the program. *)
let add_command_source (log : Log.t) ~id ~label ~command =
  let pos =
    match
      Log.rows log "SELECT COALESCE(MAX(position) + 1, 0) FROM ui_sources" []
    with
    | [ [| p |] ] -> Log.int p
    | _ -> 0
  in
  insert_source log ~pos
    {
      id;
      kind = k_command;
      label;
      paths = command;
      yields = [ "Lines the program prints for the last day" ];
      selected = false;
    }

let remove_source (log : Log.t) id =
  Log.exec log "DELETE FROM ui_sources WHERE id = ?" [ Log.s id ]

let k_sources_saved = "ui_sources_saved"

let select_sources (log : Log.t) ids =
  Log.transaction log (fun () ->
      Log.exec log "UPDATE ui_sources SET selected = 0" [];
      List.iter
        (fun id ->
          Log.exec log "UPDATE ui_sources SET selected = 1 WHERE id = ?"
            [ Log.s id ])
        ids;
      set_config log k_sources_saved (now ()))

(* the deny list *)

type deny_entry = {
  d_id : string;
  d_kind : string;
  value : string;
  created_at : string;
  trips : int;
}

let deny_of = function
  | [| id; kind; value; created_at; trips |] ->
      {
        d_id = Log.text id;
        d_kind = Log.text kind;
        value = Log.text value;
        created_at = Log.text created_at;
        trips = Log.int trips;
      }
  | _ -> assert false

let deny_columns = "id, kind, value, created_at, trips"

let deny_list (log : Log.t) =
  List.map deny_of
    (Log.rows log
       ("SELECT " ^ deny_columns ^ " FROM ui_deny ORDER BY created_at, id")
       [])

let deny_entry (log : Log.t) id =
  match
    Log.rows log
      ("SELECT " ^ deny_columns ^ " FROM ui_deny WHERE id = ?")
      [ Log.s id ]
  with
  | [ r ] -> Some (deny_of r)
  | _ -> None

let add_deny (log : Log.t) ?(created_at = now ()) ~kind ~value () =
  let id = "deny-" ^ random_id () in
  Log.exec log
    "INSERT INTO ui_deny (id, kind, value, created_at) VALUES (?, ?, ?, ?)"
    [ Log.s id; Log.s kind; Log.s value; Log.s created_at ];
  Option.get (deny_entry log id)

let remove_deny (log : Log.t) id =
  Log.exec log "DELETE FROM ui_deny WHERE id = ?" [ Log.s id ]

let deny_tripped (log : Log.t) id =
  Log.exec log "UPDATE ui_deny SET trips = trips + 1 WHERE id = ?" [ Log.s id ]

(* mutes *)

let muted (log : Log.t) identity =
  Log.rows log "SELECT 1 FROM ui_mutes WHERE identity = ?" [ Log.s identity ]
  <> []

let set_muted (log : Log.t) identity m =
  if m then
    Log.exec log
      "INSERT OR IGNORE INTO ui_mutes (identity, muted_at) VALUES (?, ?)"
      [ Log.s identity; Log.s (now ()) ]
  else Log.exec log "DELETE FROM ui_mutes WHERE identity = ?" [ Log.s identity ]

(* The outbox: a message this member's node wrote that the deny layer refused before signing. A
   note is not here: notes are Notes, below. *)

type outbound = {
  o_id : string;
  o_kind : string;
  voice : string;
  recipient : string option;
  reply_to : string option;
  o_text : string option;
  status : string;
  refused_rule : string option;
  o_created_at : string;
  posted_hash : string option;
  held_reason : string option;
      (** Why the check at signing did not send the note: Not sent. ... Edit it.
      *)
}

let outbound_columns =
  "id, kind, voice, recipient, reply_to, text, status, refused_rule, \
   created_at, posted_hash, held_reason"

let outbound_of = function
  | [|
      id; kind; voice; recipient; reply_to; text; status; rule; at; posted; held;
    |] ->
      {
        o_id = Log.text id;
        o_kind = Log.text kind;
        voice = Log.text voice;
        recipient = Log.text_opt recipient;
        reply_to = Log.text_opt reply_to;
        o_text = Log.text_opt text;
        status = Log.text status;
        refused_rule = Log.text_opt rule;
        o_created_at = Log.text at;
        posted_hash = Log.text_opt posted;
        held_reason = Log.text_opt held;
      }
  | _ -> assert false

let outbox (log : Log.t) =
  List.map outbound_of
    (Log.rows log
       ("SELECT " ^ outbound_columns ^ " FROM ui_outbox ORDER BY created_at")
       [])

let outbound (log : Log.t) id =
  match
    Log.rows log
      ("SELECT " ^ outbound_columns ^ " FROM ui_outbox WHERE id = ?")
      [ Log.s id ]
  with
  | [ r ] -> Some (outbound_of r)
  | _ -> None

let add_outbound (log : Log.t) o =
  Log.exec log
    ("INSERT INTO ui_outbox (" ^ outbound_columns
   ^ ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    [
      Log.s o.o_id;
      Log.s o.o_kind;
      Log.s o.voice;
      Log.opt o.recipient;
      Log.opt o.reply_to;
      Log.opt o.o_text;
      Log.s o.status;
      Log.opt o.refused_rule;
      Log.s o.o_created_at;
      Log.opt o.posted_hash;
      Log.opt o.held_reason;
    ]

let settle_outbound (log : Log.t) id ~status ?text ?refused_rule ?posted_hash ()
    =
  Log.exec log
    "UPDATE ui_outbox SET status = ?, text = ?, refused_rule = ?, posted_hash \
     = ? WHERE id = ?"
    [
      Log.s status;
      Log.opt text;
      Log.opt refused_rule;
      Log.opt posted_hash;
      Log.s id;
    ]

(* The nightly tick: one row per run of the member's pipeline, written by `digestif note` when the
   run hands over a note and by `digestif tick` when it had nothing to say. A run that failed records
   a problem instead (Problems below). The Members page reads the ticks to say whether the work run
   still runs. *)

type tick_outcome =
  | Posted  (** the note was signed *)
  | Held  (** the note waits for the member's approval *)
  | Quiet  (** the run had nothing to say *)

let tick_outcomes = [ (Posted, "posted"); (Held, "held"); (Quiet, "quiet") ]
let tick_outcome_name o = List.assoc o tick_outcomes

let tick_outcome_of_name n =
  List.find_map (fun (o, s) -> if s = n then Some o else None) tick_outcomes

type tick = { t_at : string; outcome : tick_outcome }

let add_tick (log : Log.t) ?(at = now ()) outcome =
  Log.exec log "INSERT INTO ui_ticks (id, at, outcome) VALUES (?, ?, ?)"
    [
      Log.s ("tick-" ^ random_id ());
      Log.s at;
      Log.s (tick_outcome_name outcome);
    ]

(* The newest tick first. A row whose outcome this binary does not know is skipped. *)
let ticks (log : Log.t) ~limit =
  List.filter_map
    (function
      | [| at; outcome |] ->
          Option.map
            (fun o -> { t_at = Log.text at; outcome = o })
            (tick_outcome_of_name (Log.text outcome))
      | _ -> assert false)
    (Log.rows log
       "SELECT at, outcome FROM ui_ticks ORDER BY at DESC, rowid DESC LIMIT ?"
       [ Log.i limit ])

(* Launch tokens and sessions are kept as hashes: the database never holds a value that opens the
   UI. A launch token is good once, for five minutes. *)

let digest_token t = Crypto.sha256_hex t
let launch_ttl = 300.0

let new_launch_token (log : Log.t) =
  let token = B64url.encode (Crypto.random 32) in
  let t = Unix.gettimeofday () in
  Log.exec log "DELETE FROM ui_launch WHERE expires_at < ?"
    [ Sqlite3.Data.FLOAT t ];
  Log.exec log "INSERT INTO ui_launch (token_hash, expires_at) VALUES (?, ?)"
    [ Log.s (digest_token token); Sqlite3.Data.FLOAT (t +. launch_ttl) ];
  token

let spend_launch_token (log : Log.t) token =
  let h = digest_token token in
  let live =
    Log.rows log "SELECT expires_at FROM ui_launch WHERE token_hash = ?"
      [ Log.s h ]
  in
  Log.exec log "DELETE FROM ui_launch WHERE token_hash = ?" [ Log.s h ];
  match live with
  | [ [| Sqlite3.Data.FLOAT e |] ] -> e > Unix.gettimeofday ()
  | _ -> false

let new_session (log : Log.t) =
  let token = B64url.encode (Crypto.random 32) in
  Log.exec log "INSERT INTO ui_sessions (token_hash, created_at) VALUES (?, ?)"
    [ Log.s (digest_token token); Log.s (now ()) ];
  token

let session_valid (log : Log.t) token =
  Log.rows log "SELECT 1 FROM ui_sessions WHERE token_hash = ?"
    [ Log.s (digest_token token) ]
  <> []

(* A behavior's session ends when the behavior does. *)
let end_session (log : Log.t) token =
  Log.exec log "DELETE FROM ui_sessions WHERE token_hash = ?"
    [ Log.s (digest_token token) ]

(* The member experience (DES-37265, docs/design.md): one section per row that builds it, each a
   module of its own with its own tables and keys, so the rows edit disjoint lines. A section
   creates its tables in its own [init], which [init] below runs after the tables above. *)

(* ISS-38781: where each note starts, per source, and the first note's reach. *)
module Record = struct
  let init (_ : Log.t) = ()
end

(* ISS-38777: what each check run removed and where, and the deny list's part in the PII check.
   One row per entry of a note's Log, kept as the log_entry it is served as
   (spec/digestif-node.json), in the order it happened. An entry names a part and what was broken,
   never text, so nothing here holds what a check removed. *)
module Checks = struct
  let init (log : Log.t) =
    Log.check log.db
      (Sqlite3.exec log.db
         "CREATE TABLE IF NOT EXISTS ui_note_log (note_id TEXT NOT NULL, at \
          TEXT NOT NULL, entry TEXT NOT NULL);\n\
          CREATE INDEX IF NOT EXISTS ui_note_log_note ON ui_note_log (note_id);")

  let add (log : Log.t) ~note_id (entry : string) =
    Log.exec log "INSERT INTO ui_note_log (note_id, at, entry) VALUES (?, ?, ?)"
      [ Log.s note_id; Log.s (now ()); Log.s entry ]

  (* The note's entries, oldest first. *)
  let entries (log : Log.t) ~note_id =
    List.map
      (function [| entry |] -> Log.text entry | _ -> assert false)
      (Log.rows log
         "SELECT entry FROM ui_note_log WHERE note_id = ? ORDER BY rowid"
         [ Log.s note_id ])
end

(* The problem record (docs/design.md, One way a failure is reported): every job reports a failure
   through [report], and the job's next success closes it through [resolve]. The same job, kind and
   source add to one open problem rather than a new one. Each job keeps its own retry; this is only
   how its failure is seen, by the note's Log, the header of Notes and the status note alike. *)
module Problems = struct
  let jobs =
    [
      "sync";
      "read_circle";
      "write_version";
      "pii_check";
      "rules_check";
      "send";
      "source";
      "learnings";
      "self_update";
    ]

  let kinds =
    [
      "signed_out";
      "model_unavailable";
      "out_of_budget";
      "source_failed";
      "relay_unreachable";
      "signing_refused";
      "failed";
    ]

  (* The jobs a work run is: the status note reads Could not run today. while one is open. *)
  let work_run_jobs = [ "write_version"; "pii_check"; "rules_check" ]

  let init (log : Log.t) =
    Log.check log.db
      (Sqlite3.exec log.db
         "CREATE TABLE IF NOT EXISTS ui_problems (id TEXT PRIMARY KEY, job \
          TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', \
          first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, count \
          INTEGER NOT NULL, closed_at TEXT);\n\
          CREATE INDEX IF NOT EXISTS ui_problems_open ON ui_problems (job, \
          closed_at);")

  type problem = {
    p_id : string;
    job : string;
    kind : string;
    p_source : string option;
        (** with kind source_failed: the source's label *)
    first_seen_at : string;
    last_seen_at : string;
    count : int;
    closed_at : string option;
  }

  let columns =
    "id, job, kind, source, first_seen_at, last_seen_at, count, closed_at"

  let of_row = function
    | [| id; job; kind; source; first; last; count; closed |] ->
        {
          p_id = Log.text id;
          job = Log.text job;
          kind = Log.text kind;
          p_source = (match Log.text source with "" -> None | s -> Some s);
          first_seen_at = Log.text first;
          last_seen_at = Log.text last;
          count = Log.int count;
          closed_at = Log.text_opt closed;
        }
    | _ -> assert false

  let find (log : Log.t) id =
    match
      Log.rows log
        ("SELECT " ^ columns ^ " FROM ui_problems WHERE id = ?")
        [ Log.s id ]
    with
    | [ r ] -> Some (of_row r)
    | _ -> None

  (* The one function every job calls when it fails. Answers the open problem it added to. *)
  let report (log : Log.t) ?(at = now ()) ?source ~job ~kind () =
    if not (List.mem job jobs) then invalid_arg ("problem job: " ^ job);
    if not (List.mem kind kinds) then invalid_arg ("problem kind: " ^ kind);
    let source = Option.value source ~default:"" in
    Log.transaction log (fun () ->
        match
          Log.rows log
            "SELECT id FROM ui_problems WHERE job = ? AND kind = ? AND source \
             = ? AND closed_at IS NULL"
            [ Log.s job; Log.s kind; Log.s source ]
        with
        | [| id |] :: _ ->
            Log.exec log
              "UPDATE ui_problems SET last_seen_at = ?, count = count + 1 \
               WHERE id = ?"
              [ Log.s at; id ];
            Option.get (find log (Log.text id))
        | _ ->
            let id = "problem-" ^ random_id () in
            Log.exec log
              ("INSERT INTO ui_problems (" ^ columns
             ^ ") VALUES (?, ?, ?, ?, ?, ?, 1, NULL)")
              [
                Log.s id;
                Log.s job;
                Log.s kind;
                Log.s source;
                Log.s at;
                Log.s at;
              ];
            Option.get (find log id))

  (* The job succeeded: every open problem of it closes. A source job names the source that read,
     so one source's success does not close another's failure. *)
  let resolve (log : Log.t) ?(at = now ()) ?source ~job () =
    match source with
    | None ->
        Log.exec log
          "UPDATE ui_problems SET closed_at = ? WHERE job = ? AND closed_at IS \
           NULL"
          [ Log.s at; Log.s job ]
    | Some s ->
        Log.exec log
          "UPDATE ui_problems SET closed_at = ? WHERE job = ? AND source = ? \
           AND closed_at IS NULL"
          [ Log.s at; Log.s job; Log.s s ]

  (* Open problems first, then closed; newest first within each. *)
  let list (log : Log.t) ?(open_only = false) ~limit () =
    List.map of_row
      (Log.rows log
         ("SELECT " ^ columns ^ " FROM ui_problems"
         ^ (if open_only then " WHERE closed_at IS NULL" else "")
         ^ " ORDER BY closed_at IS NOT NULL, last_seen_at DESC, rowid DESC \
            LIMIT ?")
         [ Log.i limit ])

  let open_ (log : Log.t) = list log ~open_only:true ~limit:100 ()

  (* Whether the last work run failed: a problem in writing, checking or reading is open. *)
  let work_run_failed (log : Log.t) =
    List.exists (fun p -> List.mem p.job work_run_jobs) (open_ log)
end

(* ISS-38778: organizations, repositories and commit authors. *)
module Repositories = struct
  let init (_ : Log.t) = ()
end

(* The setup chat starts the first note at once rather than at Note time; it is the only caller,
   since a member who wants an earlier note moves Note time. *)
let k_nightly_run_now = "behavior_nightly_run_now"
let request_nightly_run log = set_config log k_nightly_run_now "1"
let nightly_run_requested log = config log k_nightly_run_now <> None

let clear_nightly_run log =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_nightly_run_now ]

(* The setup chat's progress (docs/design.md, The setup chat and the first note): each confirmed
   item is saved at once, so a chat closed halfway resumes at the first item not done. *)
module Setup = struct
  let init (_ : Log.t) = ()
  let k_names = "setup_names_saved"
  let k_first_note = "setup_first_note_started"

  type item = Names | Sources | Brief | First_note

  let item_name = function
    | Names -> "names"
    | Sources -> "sources"
    | Brief -> "brief"
    | First_note -> "first_note"

  (* The first item not done; None once the first note has started. *)
  let next log =
    if config log k_names = None then Some Names
    else if config log k_sources_saved = None then Some Sources
    else if String.trim (brief log).text = "" then Some Brief
    else if config log k_first_note = None then Some First_note
    else None

  let names_saved log = set_config log k_names (now ())
  let first_note_started log = config log k_first_note

  let start_first_note log =
    if first_note_started log = None then begin
      set_config log k_first_note (now ());
      request_nightly_run log
    end

  (* One source chosen, beside whatever is chosen already: a command source once its test passes. *)
  let choose_source (log : Log.t) id =
    Log.exec log "UPDATE ui_sources SET selected = 1 WHERE id = ?" [ Log.s id ]

  (* A rule the member gave in the chat, as a line of the one Rules text. *)
  let add_rule log text =
    let current = String.trim (rules log).text in
    set_rules log (if current = "" then text else current ^ "\n" ^ text)
end

(* ISS-38782: notes, their versions and Log, Learnings, the approval setting and the count of
   unchanged approvals behind its suggestion (DES-37265, Approve and Edit, Rules and Learnings,
   Status and Shared, Approval and sending are two small jobs).

   A note is written once and then waits. Its first version is the agent's, already checked; every
   edit is a new version, which both checks run on like any other. A version's [text] is what the
   member may read: the checked text once its checks passed. While an edit's checks have not
   finished its submitted words are kept in [submitted] so the check behavior can read them, and
   they are dropped the moment the checked text arrives: removed text is not kept. Who approved is
   the status itself. The send is not here: a note approved and not yet signed is the send job's
   (Api.send_notes), and Shared is read from the relays' sightings of the envelope it became. *)
module Notes = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_notes (
  id TEXT PRIMARY KEY,
  written_at TEXT NOT NULL,
  status TEXT NOT NULL,
  approved_version TEXT,
  approved_at TEXT,
  posted_hash TEXT,
  held_reason TEXT
);
CREATE TABLE IF NOT EXISTS ui_note_versions (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL,
  number INTEGER NOT NULL,
  voice TEXT NOT NULL,
  created_at TEXT NOT NULL,
  edited_version_id TEXT,
  submitted TEXT,
  text TEXT,
  pii TEXT NOT NULL,
  rules TEXT NOT NULL,
  removed INTEGER NOT NULL DEFAULT 0,
  approve INTEGER NOT NULL DEFAULT 0,
  learned INTEGER NOT NULL DEFAULT 1,
  next_try_at REAL,
  UNIQUE (note_id, number)
);
CREATE INDEX IF NOT EXISTS ui_note_versions_note ON ui_note_versions (note_id);
|}

  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)

  (* notes *)

  type note = {
    n_id : string;
    written_at : string;
    n_status : string;  (** waiting, approved or auto_approved *)
    approved_version : string option;
    approved_at : string option;
    n_posted_hash : string option;
    n_held_reason : string option;
  }

  let note_columns =
    "id, written_at, status, approved_version, approved_at, posted_hash, \
     held_reason"

  let note_of = function
    | [| id; at; status; version; approved_at; posted; held |] ->
        {
          n_id = Log.text id;
          written_at = Log.text at;
          n_status = Log.text status;
          approved_version = Log.text_opt version;
          approved_at = Log.text_opt approved_at;
          n_posted_hash = Log.text_opt posted;
          n_held_reason = Log.text_opt held;
        }
    | _ -> assert false

  (* Every note, newest first. *)
  let all (log : Log.t) =
    List.map note_of
      (Log.rows log
         ("SELECT " ^ note_columns
        ^ " FROM ui_notes ORDER BY written_at DESC, rowid DESC")
         [])

  let find (log : Log.t) id =
    match
      Log.rows log
        ("SELECT " ^ note_columns ^ " FROM ui_notes WHERE id = ?")
        [ Log.s id ]
    with
    | [ r ] -> Some (note_of r)
    | _ -> None

  let waiting (log : Log.t) =
    List.filter (fun n -> n.n_status = "waiting") (all log)

  (* versions *)

  type version = {
    v_id : string;
    v_note : string;
    number : int;
    v_voice : string;  (** agent or person *)
    v_created_at : string;
    edited_version_id : string option;
    submitted : string option;  (** an edit's words until its checks finish *)
    v_text : string option;  (** the checked text *)
    pii : string;  (** running, passed or could_not_finish *)
    rules : string;
    removed : bool;
    approve : bool;  (** Save & approve *)
    learned : bool;  (** Learnings were updated from this edit's diff *)
    next_try_at : float option;
  }

  let version_columns =
    "id, note_id, number, voice, created_at, edited_version_id, submitted, \
     text, pii, rules, removed, approve, learned, next_try_at"

  let version_of = function
    | [|
        id;
        note;
        number;
        voice;
        at;
        edited;
        submitted;
        text;
        pii;
        rules;
        removed;
        approve;
        learned;
        next;
      |] ->
        {
          v_id = Log.text id;
          v_note = Log.text note;
          number = Log.int number;
          v_voice = Log.text voice;
          v_created_at = Log.text at;
          edited_version_id = Log.text_opt edited;
          submitted = Log.text_opt submitted;
          v_text = Log.text_opt text;
          pii = Log.text pii;
          rules = Log.text rules;
          removed = Log.int removed = 1;
          approve = Log.int approve = 1;
          learned = Log.int learned = 1;
          next_try_at =
            (match next with
            | Sqlite3.Data.FLOAT f -> Some f
            | Sqlite3.Data.INT i -> Some (Int64.to_float i)
            | _ -> None);
        }
    | _ -> assert false

  (* A note's versions, oldest first. *)
  let versions (log : Log.t) ~note_id =
    List.map version_of
      (Log.rows log
         ("SELECT " ^ version_columns
        ^ " FROM ui_note_versions WHERE note_id = ? ORDER BY number")
         [ Log.s note_id ])

  let version (log : Log.t) id =
    match
      Log.rows log
        ("SELECT " ^ version_columns ^ " FROM ui_note_versions WHERE id = ?")
        [ Log.s id ]
    with
    | [ r ] -> Some (version_of r)
    | _ -> None

  let passed v = v.pii = "passed" && v.rules = "passed"
  let b x = Log.i (if x then 1 else 0)

  let insert_version (log : Log.t) v =
    Log.exec log
      ("INSERT INTO ui_note_versions (" ^ version_columns
     ^ ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)")
      [
        Log.s v.v_id;
        Log.s v.v_note;
        Log.i v.number;
        Log.s v.v_voice;
        Log.s v.v_created_at;
        Log.opt v.edited_version_id;
        Log.opt v.submitted;
        Log.opt v.v_text;
        Log.s v.pii;
        Log.s v.rules;
        b v.removed;
        b v.approve;
        b v.learned;
      ]

  (* The agent's note, checked by the behavior that wrote it: a note and its first version. With
     [could_not_finish], a check could not finish on it: the version stays unseen and unapproved,
     and the check behavior runs the checks alone again at [retry_at], never the writing. *)
  let add (log : Log.t) ?(at = now ()) ?could_not_finish ~status text =
    let id = local_hash () in
    Log.exec log
      ("INSERT INTO ui_notes (" ^ note_columns
     ^ ") VALUES (?, ?, ?, NULL, NULL, NULL, NULL)")
      [ Log.s id; Log.s at; Log.s "waiting" ];
    let v =
      {
        v_id = local_hash ();
        v_note = id;
        number = 1;
        v_voice = "agent";
        v_created_at = at;
        edited_version_id = None;
        submitted = None;
        v_text = Some text;
        pii = "passed";
        rules = "passed";
        removed = false;
        approve = false;
        learned = true;
        next_try_at = None;
      }
    in
    let v =
      match could_not_finish with
      | None -> v
      | Some (check, _) ->
          {
            v with
            v_text = None;
            submitted = Some text;
            pii = (if check = "pii" then "could_not_finish" else "running");
            rules = (if check = "rules" then "could_not_finish" else "running");
          }
    in
    insert_version log v;
    Option.iter
      (fun (_, retry_at) ->
        Log.exec log "UPDATE ui_note_versions SET next_try_at = ? WHERE id = ?"
          [ Sqlite3.Data.FLOAT retry_at; Log.s v.v_id ])
      could_not_finish;
    if status <> "waiting" && could_not_finish = None then
      Log.exec log
        "UPDATE ui_notes SET status = ?, approved_version = ?, approved_at = ? \
         WHERE id = ?"
        [ Log.s status; Log.s v.v_id; Log.s at; Log.s id ];
    (id, v.v_id)

  (* The member's edit: a new version whose checks have not run. *)
  let add_edit (log : Log.t) ~note_id ~edited ~approve text =
    let number =
      1 + List.fold_left (fun m v -> max m v.number) 0 (versions log ~note_id)
    in
    let v =
      {
        v_id = local_hash ();
        v_note = note_id;
        number;
        v_voice = "person";
        v_created_at = now ();
        edited_version_id = Some edited;
        submitted = Some text;
        v_text = None;
        pii = "running";
        rules = "running";
        removed = false;
        approve;
        learned = false;
        next_try_at = None;
      }
    in
    insert_version log v;
    (* An edit answers the reason the check at signing gave. *)
    Log.exec log "UPDATE ui_notes SET held_reason = NULL WHERE id = ?"
      [ Log.s note_id ];
    v

  (* An edit's checks finished: the checked text replaces the words submitted. *)
  let checked (log : Log.t) id ~text ~removed =
    Log.exec log
      "UPDATE ui_note_versions SET text = ?, submitted = NULL, pii = 'passed', \
       rules = 'passed', removed = ?, next_try_at = NULL WHERE id = ?"
      [ Log.s text; b removed; Log.s id ]

  (* A check could not finish: the version stays unseen and is tried again at [retry_at]. *)
  let could_not_finish (log : Log.t) id ~check ~retry_at =
    let other = if check = "pii" then "rules" else "pii" in
    Log.exec log
      (Printf.sprintf
         "UPDATE ui_note_versions SET %s = 'could_not_finish', %s = 'running', \
          next_try_at = ? WHERE id = ?"
         check other)
      [ Sqlite3.Data.FLOAT retry_at; Log.s id ]

  let set_learned (log : Log.t) id =
    Log.exec log
      "UPDATE ui_note_versions SET learned = 1, next_try_at = NULL WHERE id = ?"
      [ Log.s id ]

  (* What the check behavior is handed and has not finished: a version whose checks have not passed
     (the member's edit, or the agent's own when a check could not finish on it), or an edit whose
     Learnings update has not been made, once its next try is due. Handing them over sets the next
     try an hour on, so a run that dies is retried at most once an hour. *)
  let due (log : Log.t) ~now =
    List.map version_of
      (Log.rows log
         ("SELECT " ^ version_columns
        ^ " FROM ui_note_versions WHERE (pii <> 'passed' OR rules <> 'passed' \
           OR learned = 0) AND (next_try_at IS NULL OR next_try_at <= ?) ORDER \
           BY created_at")
         [ Sqlite3.Data.FLOAT now ])

  (* A note the checks emptied before anyone could read it is not written: it goes, with its
     versions and Log. *)
  let delete (log : Log.t) ~note_id =
    Log.transaction log (fun () ->
        List.iter
          (fun t ->
            Log.exec log
              (Printf.sprintf "DELETE FROM %s WHERE %s = ?" t
                 (if t = "ui_notes" then "id" else "note_id"))
              [ Log.s note_id ])
          [ "ui_note_log"; "ui_note_versions"; "ui_notes" ])

  (* A note none could read yet: no version of it has passed its checks. *)
  let readable (log : Log.t) ~note_id =
    List.exists passed (versions log ~note_id)

  let retry_hour = 3600.0

  let handed (log : Log.t) ids ~now =
    List.iter
      (fun id ->
        Log.exec log "UPDATE ui_note_versions SET next_try_at = ? WHERE id = ?"
          [ Sqlite3.Data.FLOAT (now +. retry_hour); Log.s id ])
      ids

  (* approval and sending *)

  let approve (log : Log.t) ~note_id ~version_id ~status =
    Log.exec log
      "UPDATE ui_notes SET status = ?, approved_version = ?, approved_at = ?, \
       held_reason = NULL WHERE id = ?"
      [ Log.s status; Log.s version_id; Log.s (now ()); Log.s note_id ]

  let posted (log : Log.t) ~note_id ~hash =
    Log.exec log "UPDATE ui_notes SET posted_hash = ? WHERE id = ?"
      [ Log.s hash; Log.s note_id ]

  (* The check at signing refused the approved version: the note waits again, with the reason. *)
  let not_sent (log : Log.t) ~note_id reason =
    Log.exec log
      "UPDATE ui_notes SET status = 'waiting', approved_version = NULL, \
       approved_at = NULL, held_reason = ? WHERE id = ?"
      [ Log.s reason; Log.s note_id ]

  (* Approved and not yet signed: the send job's. *)
  let unsent (log : Log.t) =
    List.filter
      (fun n -> n.n_status <> "waiting" && n.n_posted_hash = None)
      (List.rev (all log))

  (* Learnings: one text the agent keeps from the member's edits, which the member can also edit. *)
  let k_learnings = "ui_learnings"
  let learnings log = get_doc log k_learnings ~default:""
  let set_learnings log text = set_doc log k_learnings text

  (* The one control for auto approval, off until the member saves it. *)
  let k_approval = "ui_approval"
  let settings = [ "every_note_waits"; "auto_approve" ]

  let approval log =
    match config log k_approval with
    | Some s when List.mem s settings -> s
    | _ -> "every_note_waits"

  let approval_updated_at log = config log (k_approval ^ "_updated_at")

  (* Notes in a row the member approved with no change, behind the suggestion. An edited note, Not
     now, or turning the setting off restarts it; an auto approved note neither counts nor breaks
     it. *)
  let k_unchanged = "ui_unchanged_approvals"
  let suggest_after = 3

  let unchanged log =
    Option.value
      (Option.bind (config log k_unchanged) int_of_string_opt)
      ~default:0

  let set_unchanged log n = set_config log k_unchanged (string_of_int n)
  let restart_count log = set_unchanged log 0

  let set_approval log setting =
    set_doc log k_approval setting;
    if setting = "every_note_waits" then restart_count log

  let suggest log =
    approval log = "every_note_waits" && unchanged log >= suggest_after
end

(* ISS-38780: Note time, HH:MM in the member's time zone, kept in config. Until the member saves
   one it reads as [default_note_time]. *)
module Settings = struct
  let init (_ : Log.t) = ()
  let k_note_time = "note_time"
  let default_note_time = "07:00"

  (* "7:05" and "07:05" are 07:05; anything else is not a time of day. *)
  let parse_note_time s =
    match String.split_on_char ':' (String.trim s) with
    | [ h; m ]
      when String.length h >= 1 && String.length h <= 2 && String.length m = 2
      -> (
        match (int_of_string_opt h, int_of_string_opt m) with
        | Some h, Some m when h >= 0 && h < 24 && m >= 0 && m < 60 ->
            Some (Printf.sprintf "%02d:%02d" h m)
        | _ -> None)
    | _ -> None

  let note_time (log : Log.t) =
    match Option.bind (Log.get_config log k_note_time) parse_note_time with
    | Some t -> t
    | None -> default_note_time

  let set_note_time (log : Log.t) t = Log.set_config log k_note_time t
end

(* ISS-38784: the stage and the clock (DES-37265, Onboarding, Active and Paused; The clock).

   The stage is this member's own: Onboarding from the join until their first approved note goes
   out, Active from then, Paused from Pause until Unpause (Pause below moves it). Every summary the
   member signs carries it, which is how the rest of the circle learns it.

   The clock tracks that an Active member's machine sends a note every 24 hours. It is set when the
   store is first opened, at install, and again by any note going out and by Unpause. It is read
   only while Active: Onboarding sends nothing, and Paused stops it until Unpause sets it again. *)
module Stages = struct
  let stages = [ "onboarding"; "active"; "paused" ]
  let k_stage = "ui_stage"
  let k_clock = "ui_clock_set_at"
  let k_read_mark = "ui_read_mark"
  let day = 86400.0

  let stage log =
    match config log k_stage with
    | Some s when List.mem s stages -> s
    | _ -> "onboarding"

  let set log s =
    if not (List.mem s stages) then invalid_arg ("stage: " ^ s);
    set_config log k_stage s

  let active log = stage log = "active"
  let reset_clock ~now log = set_config log k_clock (Printf.sprintf "%.3f" now)
  let clock_set_at log = Option.bind (config log k_clock) float_of_string_opt

  let init (log : Log.t) =
    if clock_set_at log = None then reset_clock ~now:(Unix.gettimeofday ()) log

  (* When the clock runs out: 24 hours after it was last set. *)
  let clock_runs_out log =
    Option.value (clock_set_at log) ~default:(Unix.gettimeofday ()) +. day

  let clock_out log ~now = active log && now >= clock_runs_out log

  (* A note is going out: the first approved one ends Onboarding, so it already carries Active.
     Answers the stage the note carries. *)
  let going_out log =
    if stage log = "onboarding" then set log "active";
    stage log

  (* What the reading agent has been handed: the newest envelope's local order when its run was
     spawned. Messages that arrive while Onboarding or Paused are kept and read from there. *)
  let read_mark log =
    Option.value
      (Option.bind (config log k_read_mark) int_of_string_opt)
      ~default:0

  let set_read_mark log n = set_config log k_read_mark (string_of_int n)

  let newest_order (log : Log.t) =
    match Log.rows log "SELECT MAX(local_order) FROM envelopes" [] with
    | [ [| v |] ] -> Log.int v
    | _ -> 0

  (* Whether the reading agent has something to read: a message from another member past the read
     mark that is not a status note. Status notes are skipped here, in code, so they cost no model
     call. *)
  let unread (log : Log.t) ~own =
    Log.rows log
      ("SELECT " ^ Log.envelope_columns
     ^ " FROM envelopes WHERE local_order > ? AND kind IN ("
      ^ String.concat ", "
          (List.map (fun k -> "'" ^ k ^ "'") Content.feed_kinds)
      ^ ") ORDER BY local_order")
      [ Log.i (read_mark log) ]
    |> List.map Log.row_of
    |> List.exists (fun (r : Log.row) ->
        (not (List.mem r.signed.envelope.author own))
        && not
             (r.signed.envelope.kind = "summary"
             && Content.status_of r.signed.body <> None))
end

(* The member's fixed minute of the 3 AM note time, chosen once: the first time anything asks for
   it (Behaviors.minute, and the Paused page's next-note sentence). *)
let k_minute = "nightly_minute"

let note_minute (log : Log.t) =
  match Option.bind (Log.get_config log k_minute) int_of_string_opt with
  | Some m when m >= 0 && m < 60 -> m
  | _ ->
      let m = Char.code (Crypto.random 1).[0] mod 60 in
      Log.set_config log k_minute (string_of_int m);
      m

(* ISS-38785: when and why the member paused, and the last Unpause (DES-37265, Pause).

   Pause moves the stage from Active to Paused, by the member's press or because a note waited 30
   days, and Unpause moves it back to Active and sets the clock. Only Unpause ends Paused: a note
   going out does not (Stages.going_out leaves Paused alone).

   The 30 days count from when the note could first be read, the first version that passed its
   checks, or from the last Unpause, whichever is later. A version records no time its checks
   finished, so the first pass that finds a waiting note readable records it here, which is at most
   one pass late and never early. *)
module Pause = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_note_readable (
  note_id TEXT PRIMARY KEY,
  readable_at REAL NOT NULL
);
|}

  let reasons = [ "pressed_pause"; "note_waited" ]
  let k_since = "ui_paused_at"
  let k_reason = "ui_pause_reason"
  let k_unpaused = "ui_unpaused_at"
  let day = 86400.0
  let waits = 30.0 *. day
  let warns = 3.0 *. day
  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)
  let paused log = Stages.stage log = "paused"
  let float_config log k = Option.bind (config log k) float_of_string_opt
  let since log = if paused log then float_config log k_since else None

  let reason log =
    match config log k_reason with
    | Some r when List.mem r reasons -> r
    | _ -> "pressed_pause"

  let unpaused_at log = float_config log k_unpaused

  (* Pause, from Active only: answers false for any other stage. *)
  let pause log ~now ~reason =
    if not (List.mem reason reasons) then invalid_arg ("pause reason: " ^ reason);
    if not (Stages.active log) then false
    else begin
      Log.transaction log (fun () ->
          Stages.set log "paused";
          set_config log k_since (Printf.sprintf "%.3f" now);
          set_config log k_reason reason);
      true
    end

  (* Unpause: Active at once, the clock set to a normal day. Answers false when not Paused. *)
  let unpause log ~now =
    if not (paused log) then false
    else begin
      Log.transaction log (fun () ->
          Stages.set log "active";
          set_config log k_unpaused (Printf.sprintf "%.3f" now);
          Stages.reset_clock ~now log);
      true
    end

  let readable_at (log : Log.t) ~note_id =
    match
      Log.rows log "SELECT readable_at FROM ui_note_readable WHERE note_id = ?"
        [ Log.s note_id ]
    with
    | [ [| Sqlite3.Data.FLOAT f |] ] -> Some f
    | [ [| Sqlite3.Data.INT i |] ] -> Some (Int64.to_float i)
    | _ -> None

  let set_readable_at (log : Log.t) ~note_id at =
    Log.exec log
      "INSERT OR REPLACE INTO ui_note_readable (note_id, readable_at) VALUES \
       (?, ?)"
      [ Log.s note_id; Sqlite3.Data.FLOAT at ]

  (* Record [now] for each waiting note first found readable. *)
  let observe (log : Log.t) ~now =
    List.iter
      (fun (n : Notes.note) ->
        if
          readable_at log ~note_id:n.n_id = None
          && Notes.readable log ~note_id:n.n_id
        then set_readable_at log ~note_id:n.n_id now)
      (Notes.waiting log)

  (* The waiting note that pauses the member first, with when its 30 days began and when they end.
     None while no waiting note can be read. *)
  let next (log : Log.t) ~now =
    observe log ~now;
    let from at =
      match unpaused_at log with Some u when u > at -> u | _ -> at
    in
    Notes.waiting log
    |> List.filter_map (fun (n : Notes.note) ->
        Option.map
          (fun at ->
            let f = from at in
            (n, f, f +. waits))
          (readable_at log ~note_id:n.n_id))
    |> List.sort (fun (_, _, a) (_, _, b) -> compare a b)
    |> function
    | x :: _ -> Some x
    | [] -> None

  (* The note whose 30 days have run out, for an Active member. *)
  let due (log : Log.t) ~now =
    if not (Stages.active log) then None
    else
      match next log ~now with
      | Some (n, _, at) when now >= at -> Some n
      | _ -> None

  (* The banner: three days or less before the pause, for an Active member. *)
  let warning (log : Log.t) ~now =
    if not (Stages.active log) then None
    else
      match next log ~now with
      | Some (n, from, at) when now >= at -. warns -> Some (n, from, at)
      | _ -> None
end

let init (log : Log.t) =
  init_base log;
  Record.init log;
  Checks.init log;
  Problems.init log;
  Repositories.init log;
  Setup.init log;
  Notes.init log;
  Settings.init log;
  Stages.init log;
  Pause.init log
