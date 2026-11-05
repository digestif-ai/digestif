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
CREATE INDEX IF NOT EXISTS ui_deny_created ON ui_deny (created_at, id);
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

(* The sources in the order the page lists them: every one, or with [limit] one page of them,
   starting after the source [after] (ISS-41944). An [after] the store does not hold starts
   nowhere: the page is empty. *)
let sources ?after ?limit (log : Log.t) =
  let cursor, cursor_params =
    match after with
    | None -> ("", [])
    | Some id ->
        ( " WHERE position > (SELECT position FROM ui_sources WHERE id = ?)",
          [ Log.s id ] )
  in
  let lim, lim_params =
    match limit with None -> ("", []) | Some n -> (" LIMIT ?", [ Log.i n ])
  in
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
       ("SELECT id, kind, label, paths, yields, selected FROM ui_sources"
      ^ cursor ^ " ORDER BY position" ^ lim)
       (cursor_params @ lim_params))

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

(* The deny list in the order Settings lists it, oldest first: every entry, or with [limit] one page
   of them, starting after the entry [after] (ISS-41988). An [after] the store does not hold starts
   nowhere: the page is empty. *)
let deny_list ?after ?limit (log : Log.t) =
  let cursor, cursor_params =
    match after with
    | None -> ("", [])
    | Some id ->
        ( " WHERE (created_at, id) > (SELECT created_at, id FROM ui_deny WHERE \
           id = ?)",
          [ Log.s id ] )
  in
  let lim, lim_params =
    match limit with None -> ("", []) | Some n -> (" LIMIT ?", [ Log.i n ])
  in
  List.map deny_of
    (Log.rows log
       ("SELECT " ^ deny_columns ^ " FROM ui_deny" ^ cursor
      ^ " ORDER BY created_at, id" ^ lim)
       (cursor_params @ lim_params))

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

(* ISS-38781: where each note starts, per source, and the first note's reach (DES-37265, The
   record and where each note starts). A source is keyed [source:<id>] (a session directory or a
   command), [repository:<id>] or [author:<email>]. Its POINT is how far the last approved note
   read it: a time, and for a repository the newest default-branch commit read. A note fixes where
   it ends when it is handed over ([set_ends]); approval moves every source it read to that end
   ([approve]), and nothing else moves a point, so a waiting or unwritten note skips no work. A
   source with no point starts at the 24 hours before the node first saw it approved; until the
   first note is approved, no source has a start and the behavior reads the first note's reach. *)
module Record = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_record_points (
  key TEXT PRIMARY KEY,
  at_ms INTEGER NOT NULL,
  sha TEXT
);
CREATE TABLE IF NOT EXISTS ui_record_approved (
  key TEXT PRIMARY KEY,
  at_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_record_ends (
  note_id TEXT NOT NULL,
  key TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  sha TEXT,
  PRIMARY KEY (note_id, key)
);
|}

  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)

  (* Set when a note's ends first move the points: from then on, no note is the first. *)
  let k_first_approved = "record_first_approved"

  (* A source with no point starts this long before it was approved. *)
  let fresh_ms = 86_400_000

  type point = { at_ms : int; sha : string option }

  let source_key id = "source:" ^ id
  let repository_key id = "repository:" ^ id
  let author_key email = "author:" ^ String.lowercase_ascii (String.trim email)
  let first_note (log : Log.t) = config log k_first_approved = None

  let point (log : Log.t) key =
    match
      Log.rows log "SELECT at_ms, sha FROM ui_record_points WHERE key = ?"
        [ Log.s key ]
    with
    | [ [| at; sha |] ] -> Some { at_ms = Log.int at; sha = Log.text_opt sha }
    | _ -> None

  let approved_at (log : Log.t) key =
    match
      Log.rows log "SELECT at_ms FROM ui_record_approved WHERE key = ?"
        [ Log.s key ]
    with
    | [ [| at |] ] -> Some (Log.int at)
    | _ -> None

  (* Records when each key was first seen approved. The node asks on every pass, so a source
     approved between two notes is dated within a pass of its approval. *)
  let observe (log : Log.t) ~now_ms keys =
    List.iter
      (fun key ->
        Log.exec log
          "INSERT OR IGNORE INTO ui_record_approved (key, at_ms) VALUES (?, ?)"
          [ Log.s key; Log.i now_ms ])
      keys

  (* Where a source starts: its point; else, after the first note, the 24 hours before it was
     approved; else nothing, which is the first note's reach. [recorded] says it is a point.
     ISS-42314 (DES-37153, correcting DES-37265's start rule): a repository a scan after setup
     found ([found_ms]) starts at the 24 hours before it was found, not before it was approved, so
     the member's delay in answering costs no work done meanwhile. *)
  type start = {
    start_ms : int option;
    start_sha : string option;
    recorded : bool;
  }

  let start ?found_ms (log : Log.t) ~now_ms key =
    match point log key with
    | Some p -> { start_ms = Some p.at_ms; start_sha = p.sha; recorded = true }
    | None when first_note log ->
        { start_ms = None; start_sha = None; recorded = false }
    | None ->
        let at =
          match found_ms with
          | Some found -> found
          | None -> Option.value (approved_at log key) ~default:now_ms
        in
        { start_ms = Some (at - fresh_ms); start_sha = None; recorded = false }

  (* Where a note ends, per source, as the behavior handed it over with the note. *)
  let set_ends (log : Log.t) ~note_id (ends : (string * point) list) =
    Log.transaction log (fun () ->
        List.iter
          (fun (key, p) ->
            Log.exec log
              "INSERT OR REPLACE INTO ui_record_ends (note_id, key, at_ms, \
               sha) VALUES (?, ?, ?, ?)"
              [ Log.s note_id; Log.s key; Log.i p.at_ms; Log.opt p.sha ])
          ends)

  (* The note is approved: every source it read starts at its end from now on. A note handed
     over with no ends (an older behavior) moves nothing but still ends the first note. *)
  let approve (log : Log.t) ~note_id =
    Log.transaction log (fun () ->
        Log.exec log
          "INSERT OR REPLACE INTO ui_record_points (key, at_ms, sha) SELECT \
           key, at_ms, sha FROM ui_record_ends WHERE note_id = ?"
          [ Log.s note_id ];
        Log.exec log "DELETE FROM ui_record_ends WHERE note_id = ?"
          [ Log.s note_id ];
        if first_note log then set_config log k_first_approved (now ()))

  (* A note that will never be approved (the deny layer refused it) moves nothing. *)
  let forget (log : Log.t) ~note_id =
    Log.exec log "DELETE FROM ui_record_ends WHERE note_id = ?"
      [ Log.s note_id ]
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

(* ISS-38778: organizations, repositories and commit authors (DES-37265, Repositories). A
   repository is one remote, every clone of it counted once, and its organization is the remote's
   owner; a clone with no remote is a repository and an organization of its own. What the machine
   holds comes in through [apply_scan]; the member's choices are only ever changed by the member. *)
module Repositories = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_organizations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  choice TEXT NOT NULL,
  found_at TEXT NOT NULL,
  sort_key TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS ui_repositories (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL,
  found_at TEXT NOT NULL,
  paths TEXT NOT NULL,
  sort_key TEXT NOT NULL DEFAULT '',
  found_by TEXT,
  last_own_commit_at TEXT
);
CREATE INDEX IF NOT EXISTS ui_repositories_org ON ui_repositories (organization_id, name);
CREATE TABLE IF NOT EXISTS ui_commit_authors (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT,
  label TEXT NOT NULL,
  member_set INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
|}

  (* ISS-41944: each list reads one page from an index, in the order the page shows it. An
     organization's sort key is its name, case aside, then its id; a repository's is its
     organization's, then its own name, case aside, then its id. The parts are joined by \x01,
     which sorts below every character a name holds, so the keys sort exactly as the tuples do and
     a page starts after the key of the row before it. *)
  let sep = "\x01"
  let org_sort_key ~id ~name = String.lowercase_ascii name ^ sep ^ id

  let repo_sort_key ~org_key ~id ~name =
    org_key ^ sep ^ String.lowercase_ascii name ^ sep ^ id

  let indexes =
    {|
CREATE INDEX IF NOT EXISTS ui_organizations_sort ON ui_organizations (sort_key);
CREATE INDEX IF NOT EXISTS ui_repositories_sort ON ui_repositories (sort_key);
CREATE INDEX IF NOT EXISTS ui_repositories_org_sort ON ui_repositories (organization_id, sort_key);
CREATE INDEX IF NOT EXISTS ui_repositories_status_sort ON ui_repositories (status, sort_key);
|}

  let has_column (log : Log.t) table column =
    Log.rows log (Printf.sprintf "PRAGMA table_info(%s)" table) []
    |> List.exists (fun r -> Array.length r > 1 && Log.text r.(1) = column)

  (* A data directory from before the sort keys gains them, each row's computed once. *)
  let add_sort_keys (log : Log.t) =
    List.iter
      (fun table ->
        if not (has_column log table "sort_key") then
          Log.exec log
            (Printf.sprintf
               "ALTER TABLE %s ADD COLUMN sort_key TEXT NOT NULL DEFAULT ''"
               table)
            [])
      [ "ui_organizations"; "ui_repositories" ];
    Log.transaction log (fun () ->
        Log.rows log "SELECT id, name FROM ui_organizations WHERE sort_key = ''"
          []
        |> List.iter (function
          | [| id; name |] ->
              Log.exec log
                "UPDATE ui_organizations SET sort_key = ? WHERE id = ?"
                [
                  Log.s (org_sort_key ~id:(Log.text id) ~name:(Log.text name));
                  id;
                ]
          | _ -> ());
        Log.rows log
          "SELECT r.id, r.name, o.sort_key FROM ui_repositories r JOIN \
           ui_organizations o ON o.id = r.organization_id WHERE r.sort_key = \
           ''"
          []
        |> List.iter (function
          | [| id; name; org_key |] ->
              Log.exec log
                "UPDATE ui_repositories SET sort_key = ? WHERE id = ?"
                [
                  Log.s
                    (repo_sort_key ~org_key:(Log.text org_key) ~id:(Log.text id)
                       ~name:(Log.text name));
                  id;
                ]
          | _ -> ()))

  (* ISS-42314: a data directory from before the where-and-how line gains its columns, empty: a
     repository stored then was found by setup, or carries no own commit yet. *)
  let add_found_columns (log : Log.t) =
    List.iter
      (fun column ->
        if not (has_column log "ui_repositories" column) then
          Log.exec log
            (Printf.sprintf "ALTER TABLE ui_repositories ADD COLUMN %s TEXT"
               column)
            [])
      [ "found_by"; "last_own_commit_at" ]

  let init (log : Log.t) =
    Log.check log.db (Sqlite3.exec log.db schema);
    add_sort_keys log;
    add_found_columns log;
    Log.check log.db (Sqlite3.exec log.db indexes)

  (* organization_choice, repository_status and author_label, as the spec spells them. *)
  let choices = [ "all_automatic"; "all"; "chosen" ]
  let statuses = [ "approved"; "declined"; "undecided" ]
  let labels = [ "yours"; "your_fleet" ]

  type organization = {
    o_id : string;
    o_name : string;
    choice : string;
    repositories : int;
  }

  type repository = {
    r_id : string;
    organization_id : string;
    r_name : string;
    status : string;
    found_at : string;
    r_paths : string list;
    found_by : string option;
        (** [new_clone] or [new_remote] for a repository found after setup; None
            for setup's *)
    last_own_commit_at : string option;
        (** the newest commit by one of the member's authors in any clone,
            author date *)
  }

  (* One clone the scan found: its remote's repository and organization, and where it is. *)
  type found = {
    f_id : string;
    f_name : string;
    f_org_id : string;
    f_org_name : string;
    f_path : string;
  }

  let k_scanned = "ui_repositories_scanned"

  let org_of = function
    | [| id; name; choice; n |] ->
        {
          o_id = Log.text id;
          o_name = Log.text name;
          choice = Log.text choice;
          repositories = Log.int n;
        }
    | _ -> assert false

  let org_select =
    "SELECT o.id, o.name, o.choice, (SELECT COUNT(*) FROM ui_repositories r \
     WHERE r.organization_id = o.id) FROM ui_organizations o"

  (* The organizations in the order the page lists them, by name: every one, or with [limit] one
     page of them, starting after the organization [after] (ISS-41944). An [after] the store does
     not hold starts nowhere: the page is empty. *)
  let organizations ?after ?limit (log : Log.t) =
    let cursor, cursor_params =
      match after with
      | None -> ("", [])
      | Some id ->
          ( " WHERE o.sort_key > (SELECT sort_key FROM ui_organizations WHERE \
             id = ?)",
            [ Log.s id ] )
    in
    let lim, lim_params =
      match limit with None -> ("", []) | Some n -> (" LIMIT ?", [ Log.i n ])
    in
    List.map org_of
      (Log.rows log
         (org_select ^ cursor ^ " ORDER BY o.sort_key" ^ lim)
         (cursor_params @ lim_params))

  let organization (log : Log.t) id =
    match Log.rows log (org_select ^ " WHERE o.id = ?") [ Log.s id ] with
    | [ r ] -> Some (org_of r)
    | _ -> None

  let repo_columns =
    "r.id, r.organization_id, r.name, r.status, r.found_at, r.paths, \
     r.found_by, r.last_own_commit_at"

  let repo_of = function
    | [| id; org; name; status; found_at; paths; found_by; last_own |] ->
        {
          r_id = Log.text id;
          organization_id = Log.text org;
          r_name = Log.text name;
          status = Log.text status;
          found_at = Log.text found_at;
          r_paths = strings_of_json (Log.text paths);
          found_by = Log.text_opt found_by;
          last_own_commit_at = Log.text_opt last_own;
        }
    | _ -> assert false

  (* The WHERE clause for the filters given and only those, so the store reads the index the
     filter names rather than every row: [q] matches a repository's or its organization's name,
     case aside. *)
  let filters ?q ?status ?organization_id ?after () =
    let clause sql param = Option.map (fun v -> (sql, [ Log.s v ])) param in
    let parts =
      List.filter_map Fun.id
        [
          Option.map
            (fun q ->
              ( "(instr(lower(r.name), lower(?)) > 0 OR instr(lower(o.name), \
                 lower(?)) > 0)",
                [ Log.s q; Log.s q ] ))
            q;
          clause "r.status = ?" status;
          clause "r.organization_id = ?" organization_id;
          clause
            "r.sort_key > (SELECT sort_key FROM ui_repositories WHERE id = ?)"
            after;
        ]
    in
    match parts with
    | [] -> ("", [])
    | _ ->
        ( " WHERE " ^ String.concat " AND " (List.map fst parts),
          List.concat_map snd parts )

  let from =
    " FROM ui_repositories r JOIN ui_organizations o ON o.id = \
     r.organization_id"

  (* One page of repositories in the order the page lists them: by organization, then name,
     starting after the repository [after] when it is given (ISS-41944), else [offset] rows in. An
     [after] the store does not hold starts nowhere: the page is empty. *)
  let repositories ?q ?status ?organization_id ?after ?(offset = 0) ~limit
      (log : Log.t) =
    let where, params = filters ?q ?status ?organization_id ?after () in
    List.map repo_of
      (Log.rows log
         ("SELECT " ^ repo_columns ^ from ^ where
        ^ " ORDER BY r.sort_key LIMIT ? OFFSET ?")
         (params @ [ Log.i limit; Log.i offset ]))

  (* ISS-38823: how many repositories the list would hold under each status, for the same [q] and
     [organization_id]: one pair per status, in [statuses]' order, a zero included. *)
  let counts ?q ?organization_id (log : Log.t) =
    let where, params = filters ?q ?organization_id () in
    let held =
      Log.rows log
        ("SELECT r.status, COUNT(*)" ^ from ^ where ^ " GROUP BY r.status")
        params
      |> List.filter_map (function
        | [| s; n |] -> Some (Log.text s, Log.int n)
        | _ -> None)
    in
    List.map
      (fun s -> (s, Option.value ~default:0 (List.assoc_opt s held)))
      statuses

  (* ISS-42316 (DES-37153, The new-repositories ask): the one local ask, New repositories, open
     while any repository is undecided and closed by itself once none is. It is held here, by every
     write that changes a repository's status, so no path that decides a repository can leave it
     stale. It holds no options: the repositories page under Undecided is where it is answered. *)
  let ask_key = "repositories"

  let undecided_count (log : Log.t) =
    match
      Log.rows log
        "SELECT COUNT(*) FROM ui_repositories WHERE status = 'undecided'" []
    with
    | [ [| n |] ] -> Log.int n
    | _ -> 0

  let ask_detail n =
    Printf.sprintf
      "%s on this machine %s for you to decide whether Digestif reads %s. \
       Until you decide, %s not read."
      (if n = 1 then "1 repository" else Printf.sprintf "%d repositories" n)
      (if n = 1 then "waits" else "wait")
      (if n = 1 then "it" else "them")
      (if n = 1 then "it is" else "they are")

  let hold_ask ?at (log : Log.t) =
    let n = undecided_count log in
    match
      Asks.hold_local log ?at ~open_:(n > 0)
        {
          Asks.key = ask_key;
          kind = Some "repositories";
          title = "New repositories";
          detail = ask_detail n;
          about = None;
          options = [];
          recommended = "";
          on_no_answer = "";
          lapses_at = None;
          raised_at = "";
          answer = None;
          answered_at = None;
          envelope = None;
          answered_via = None;
        }
    with
    | Ok () -> ()
    | Error e -> failwith e

  (* Every clone path the stored repositories carry, as the scan recorded them (with ~). *)
  let clone_paths (log : Log.t) =
    Log.rows log "SELECT paths FROM ui_repositories ORDER BY id" []
    |> List.concat_map (function
      | [| paths |] -> strings_of_json (Log.text paths)
      | _ -> [])

  let repository (log : Log.t) id =
    match
      Log.rows log
        ("SELECT " ^ repo_columns ^ " FROM ui_repositories r WHERE r.id = ?")
        [ Log.s id ]
    with
    | [ r ] -> Some (repo_of r)
    | _ -> None

  (* What an organization's choice makes of a repository found in it later. *)
  let status_for_new choice =
    if choice = "all_automatic" then "approved" else "undecided"

  (* Folds one scan in. The first scan proposes everything it found approved, under All
     repositories with new ones read automatically: the value is there, and unchecking is one
     click. After it, a repository found in a known organization takes what that organization's
     choice says, and an organization first seen later is Chosen repositories with every
     repository in it undecided, since nobody has been shown it. A known repository keeps its
     status and takes the clones found now; one not found keeps its row and its choice.
     ISS-42314: a repository found after the first scan records how it turned up: [new_remote]
     when one of its clones is a folder an earlier scan already held under another remote, else
     [new_clone]. *)
  let apply_scan (log : Log.t) ~at (found : found list) =
    let first = config log k_scanned = None in
    let scanned = Hashtbl.create 256 in
    if not first then
      List.iter (fun p -> Hashtbl.replace scanned p ()) (clone_paths log);
    let by_repo = Hashtbl.create 64 in
    List.iter
      (fun f ->
        let clones =
          Option.value ~default:[] (Hashtbl.find_opt by_repo f.f_id)
        in
        if not (List.exists (fun c -> c.f_path = f.f_path) clones) then
          Hashtbl.replace by_repo f.f_id (f :: clones))
      found;
    Log.transaction log (fun () ->
        Hashtbl.iter
          (fun id clones ->
            let clones =
              List.sort (fun a b -> compare a.f_path b.f_path) clones
            in
            let f = List.hd clones in
            let paths = json_strings (List.map (fun c -> c.f_path) clones) in
            let choice =
              match organization log f.f_org_id with
              | Some o -> o.choice
              | None ->
                  let choice = if first then "all_automatic" else "chosen" in
                  Log.exec log
                    "INSERT INTO ui_organizations (id, name, choice, found_at, \
                     sort_key) VALUES (?, ?, ?, ?, ?)"
                    [
                      Log.s f.f_org_id;
                      Log.s f.f_org_name;
                      Log.s choice;
                      Log.s at;
                      Log.s (org_sort_key ~id:f.f_org_id ~name:f.f_org_name);
                    ];
                  choice
            in
            match repository log id with
            | Some r ->
                if r.r_paths <> List.map (fun c -> c.f_path) clones then
                  Log.exec log
                    "UPDATE ui_repositories SET paths = ? WHERE id = ?"
                    [ Log.s paths; Log.s id ]
            | None ->
                let org_key =
                  match
                    Log.rows log
                      "SELECT sort_key FROM ui_organizations WHERE id = ?"
                      [ Log.s f.f_org_id ]
                  with
                  | [ [| k |] ] -> Log.text k
                  | _ -> org_sort_key ~id:f.f_org_id ~name:f.f_org_name
                in
                let found_by =
                  if first then None
                  else if
                    List.exists (fun c -> Hashtbl.mem scanned c.f_path) clones
                  then Some "new_remote"
                  else Some "new_clone"
                in
                Log.exec log
                  "INSERT INTO ui_repositories (id, organization_id, name, \
                   status, found_at, paths, sort_key, found_by) VALUES (?, ?, \
                   ?, ?, ?, ?, ?, ?)"
                  [
                    Log.s id;
                    Log.s f.f_org_id;
                    Log.s f.f_name;
                    Log.s (status_for_new choice);
                    Log.s at;
                    Log.s paths;
                    Log.s (repo_sort_key ~org_key ~id ~name:f.f_name);
                    Log.opt found_by;
                  ])
          by_repo;
        set_config log k_scanned at;
        hold_ask ~at log)

  (* ISS-42314: the newest commit by one of the member's authors in the repository's clones, as
     Repo_scan.last_own_commit read it; None when it found none. *)
  let set_last_own_commit (log : Log.t) id at =
    Log.exec log
      "UPDATE ui_repositories SET last_own_commit_at = ? WHERE id = ?"
      [ Log.opt at; Log.s id ]

  (* All approves every repository not declined when it is chosen; Chosen changes no status. *)
  let set_choice (log : Log.t) id choice =
    Log.transaction log (fun () ->
        Log.exec log "UPDATE ui_organizations SET choice = ? WHERE id = ?"
          [ Log.s choice; Log.s id ];
        if choice <> "chosen" then
          Log.exec log
            "UPDATE ui_repositories SET status = 'approved' WHERE \
             organization_id = ? AND status = 'undecided'"
            [ Log.s id ];
        hold_ask log)

  (* Unchecking a repository under All declines it and keeps the organization's choice. *)
  let set_status (log : Log.t) id status =
    Log.exec log "UPDATE ui_repositories SET status = ? WHERE id = ?"
      [ Log.s status; Log.s id ];
    hold_ask log

  (* The clones the record reads: every clone of every approved repository. *)
  let approved_paths (log : Log.t) =
    Log.rows log
      "SELECT paths FROM ui_repositories WHERE status = 'approved' ORDER BY id"
      []
    |> List.concat_map (function
      | [| p |] -> strings_of_json (Log.text p)
      | _ -> [])

  (* commit authors: the member owns the list *)

  type author = {
    a_id : string;
    email : string;
    a_name : string option;
    label : string;
    member_set : bool;
  }

  let author_of = function
    | [| id; email; name; label; member_set |] ->
        {
          a_id = Log.text id;
          email = Log.text email;
          a_name = Log.text_opt name;
          label = Log.text label;
          member_set = Log.int member_set <> 0;
        }
    | _ -> assert false

  let author_columns = "id, email, name, label, member_set"

  (* Yours first, then Your fleet, each by email. *)
  let authors (log : Log.t) =
    List.map author_of
      (Log.rows log
         ("SELECT " ^ author_columns
        ^ " FROM ui_commit_authors ORDER BY label = 'your_fleet', email")
         [])

  let author (log : Log.t) id =
    match
      Log.rows log
        ("SELECT " ^ author_columns ^ " FROM ui_commit_authors WHERE id = ?")
        [ Log.s id ]
    with
    | [ r ] -> Some (author_of r)
    | _ -> None

  let normalize_email e = String.lowercase_ascii (String.trim e)

  let author_by_email (log : Log.t) email =
    List.find_opt (fun a -> a.email = normalize_email email) (authors log)

  let insert_author (log : Log.t) ~email ~name ~label ~member_set =
    let id = random_id () in
    Log.exec log
      "INSERT INTO ui_commit_authors (id, email, name, label, member_set, \
       created_at) VALUES (?, ?, ?, ?, ?, ?)"
      [
        Log.s id;
        Log.s (normalize_email email);
        (match name with Some n -> Log.s n | None -> Sqlite3.Data.NULL);
        Log.s label;
        Log.i (if member_set then 1 else 0);
        Log.s (now ());
      ];
    id

  let k_authors_proposed = "ui_commit_authors_proposed"
  let authors_proposed log = config log k_authors_proposed <> None

  (* The scan's proposal enters the list once, when the list is first read: after that a newly
     seen identity is only ever proposed, never added, and nothing a scan sees removes or
     relabels an author. [proposals] is (email, name, label). *)
  let propose_authors (log : Log.t) proposals =
    if not (authors_proposed log) then
      Log.transaction log (fun () ->
          List.iter
            (fun (email, name, label) ->
              if author_by_email log email = None then
                ignore (insert_author log ~email ~name ~label ~member_set:false))
            proposals;
          set_config log k_authors_proposed (now ()))

  (* An identity the member added is theirs from then on. *)
  let add_author (log : Log.t) ~email ~name ~label =
    match author_by_email log email with
    | Some _ -> Error `Duplicate
    | None -> Ok (insert_author log ~email ~name ~label ~member_set:true)

  let label_author (log : Log.t) id label =
    Log.exec log
      "UPDATE ui_commit_authors SET label = ?, member_set = 1 WHERE id = ?"
      [ Log.s label; Log.s id ]

  let remove_author (log : Log.t) id =
    Log.exec log "DELETE FROM ui_commit_authors WHERE id = ?" [ Log.s id ]

  (* The emails whose default-branch commits enter the record. *)
  let owned_emails log = List.map (fun a -> a.email) (authors log)
end

(* ISS-41944: what the machine scan last read, so a rescan rereads only what changed since
   (Machine_scan). One row per clone discovery considered, keyed by its path, with the stamp of
   what was read (its .git/config's size and modification time and its own folders'), what that
   read found, and whether it holds financial records; and one row per Claude Code project
   directory, with its modification time and the paths its name decoded to. *)
module Scan_index = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_scan_clones (
  path TEXT PRIMARY KEY,
  stamp TEXT NOT NULL,
  financial INTEGER NOT NULL,
  repository_id TEXT NOT NULL,
  repository_name TEXT NOT NULL,
  organization_id TEXT NOT NULL,
  organization_name TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_scan_projects (
  name TEXT PRIMARY KEY,
  stamp TEXT NOT NULL,
  paths TEXT NOT NULL
);
|}

  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)

  type clone = {
    stamp : string;
    financial : bool;
    found : Repositories.found;  (** its f_path is the caller's to fill *)
  }

  let clones (log : Log.t) =
    let t = Hashtbl.create 256 in
    Log.rows log
      "SELECT path, stamp, financial, repository_id, repository_name, \
       organization_id, organization_name FROM ui_scan_clones"
      []
    |> List.iter (function
      | [| path; stamp; financial; id; name; org_id; org_name |] ->
          Hashtbl.replace t (Log.text path)
            {
              stamp = Log.text stamp;
              financial = Log.int financial <> 0;
              found =
                {
                  f_id = Log.text id;
                  f_name = Log.text name;
                  f_org_id = Log.text org_id;
                  f_org_name = Log.text org_name;
                  f_path = "";
                };
            }
      | _ -> ());
    t

  let put_clone (log : Log.t) path c =
    Log.exec log
      "INSERT OR REPLACE INTO ui_scan_clones (path, stamp, financial, \
       repository_id, repository_name, organization_id, organization_name) \
       VALUES (?, ?, ?, ?, ?, ?, ?)"
      [
        Log.s path;
        Log.s c.stamp;
        Log.i (if c.financial then 1 else 0);
        Log.s c.found.f_id;
        Log.s c.found.f_name;
        Log.s c.found.f_org_id;
        Log.s c.found.f_org_name;
      ]

  let remove_clone (log : Log.t) path =
    Log.exec log "DELETE FROM ui_scan_clones WHERE path = ?" [ Log.s path ]

  let projects (log : Log.t) =
    let t = Hashtbl.create 256 in
    Log.rows log "SELECT name, stamp, paths FROM ui_scan_projects" []
    |> List.iter (function
      | [| name; stamp; paths |] ->
          Hashtbl.replace t (Log.text name)
            (Log.text stamp, strings_of_json (Log.text paths))
      | _ -> ());
    t

  let put_project (log : Log.t) name ~stamp paths =
    Log.exec log
      "INSERT OR REPLACE INTO ui_scan_projects (name, stamp, paths) VALUES (?, \
       ?, ?)"
      [ Log.s name; Log.s stamp; Log.s (json_strings paths) ]

  let remove_project (log : Log.t) name =
    Log.exec log "DELETE FROM ui_scan_projects WHERE name = ?" [ Log.s name ]
end

(* ISS-41988: what the node has read of its own asks and its answers to them, so the Asks list
   reads one page from an index and opens only that page's asks, rather than opening every ask the
   log holds. One row per ask envelope, keyed by its hash, with its author, when it was written, and
   what its row on the list shows: when it lapses (NULL for an ask that never lapses), its kind, its
   title and who it is from (title NULL when the node could not open it); and one row per decision envelope, with
   the ask it answers, the option and when (NULL when it could not be opened). Envelopes are
   immutable, so a row is written once; a withdrawal is read from the log itself, which drops a
   withdrawn ask's body. Which authors are the member's own is the caller's: it is the fold's to
   say, and a device can be linked to the member after its asks arrive. *)
module Ask_index = struct
  let schema =
    {|
CREATE TABLE IF NOT EXISTS ui_ask_index (
  hash TEXT PRIMARY KEY,
  author TEXT NOT NULL,
  created_at TEXT NOT NULL,
  lapses_at REAL,
  deadline_at TEXT,
  kind TEXT,
  title TEXT,
  sender TEXT
);
CREATE INDEX IF NOT EXISTS ui_ask_index_created ON ui_ask_index (created_at, hash);
CREATE TABLE IF NOT EXISTS ui_ask_decisions (
  hash TEXT PRIMARY KEY,
  author TEXT NOT NULL,
  ask TEXT,
  option TEXT,
  decided_at TEXT,
  decided_unix REAL
);
CREATE INDEX IF NOT EXISTS ui_ask_decisions_ask ON ui_ask_decisions (ask, decided_unix);
|}

  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)

  (* The [kind] envelopes ("ask" or "decision") the index has no row for yet. *)
  let unindexed (log : Log.t) kind =
    let table =
      match kind with "ask" -> "ui_ask_index" | _ -> "ui_ask_decisions"
    in
    Log.rows log
      (Printf.sprintf
         "SELECT hash FROM envelopes e WHERE kind = ? AND NOT EXISTS (SELECT 1 \
          FROM %s i WHERE i.hash = e.hash)"
         table)
      [ Log.s kind ]
    |> List.map (fun r -> Log.text r.(0))

  let real = function
    | Some f -> Sqlite3.Data.FLOAT f
    | None -> Sqlite3.Data.NULL

  (* What an ask's row on the list shows, from the ask itself. *)
  type shown = {
    deadline_at : string option;  (** None: the ask never lapses. *)
    lapses_unix : float option;
    kind : string;
    title : string;
    sender : string option;
  }

  let put_ask (log : Log.t) ~hash ~author ~created_at (shown : shown option) =
    let f g = match shown with Some x -> g x | None -> Sqlite3.Data.NULL in
    Log.exec log
      "INSERT OR REPLACE INTO ui_ask_index (hash, author, created_at, \
       lapses_at, deadline_at, kind, title, sender) VALUES (?, ?, ?, ?, ?, ?, \
       ?, ?)"
      [
        Log.s hash;
        Log.s author;
        Log.s created_at;
        real (Option.bind shown (fun x -> x.lapses_unix));
        f (fun x -> Log.opt x.deadline_at);
        f (fun x -> Log.s x.kind);
        f (fun x -> Log.s x.title);
        f (fun x -> Log.opt x.sender);
      ]

  (* [decided] is the ask it answers, the option and when, as text and as a unix time. *)
  let put_decision (log : Log.t) ~hash ~author ~decided =
    let ask, option, at, at_unix =
      match decided with
      | Some (ask, option, at, at_unix) ->
          (Log.s ask, Log.s option, Log.s at, Sqlite3.Data.FLOAT at_unix)
      | None -> Sqlite3.Data.(NULL, NULL, NULL, NULL)
    in
    Log.exec log
      "INSERT OR REPLACE INTO ui_ask_decisions (hash, author, ask, option, \
       decided_at, decided_unix) VALUES (?, ?, ?, ?, ?, ?)"
      [ Log.s hash; Log.s author; ask; option; at; at_unix ]

  let placeholders l = String.concat ", " (List.map (fun _ -> "?") l)

  (* Every ask of [authors] the node can show, with its status at [now]: withdrawn, answered by a
     decision of [authors] made before it lapsed, lapsed, or open; and its rank, open first. *)
  let listed ~authors ~now =
    let a = placeholders authors in
    ( Printf.sprintf
        "WITH s AS (SELECT i.hash, i.created_at, i.deadline_at, i.kind, \
         i.title, i.sender, CASE WHEN e.retracted_by IS NOT NULL THEN \
         'withdrawn' WHEN EXISTS (SELECT 1 FROM ui_ask_decisions d WHERE d.ask \
         = i.hash AND d.author IN (%s) AND (i.lapses_at IS NULL OR \
         d.decided_unix < i.lapses_at)) THEN 'answered' WHEN i.lapses_at IS \
         NOT NULL AND i.lapses_at <= ? THEN 'lapsed' ELSE 'open' END AS status \
         FROM ui_ask_index i JOIN envelopes e ON e.hash = i.hash WHERE i.title \
         IS NOT NULL AND e.body IS NOT NULL AND i.author IN (%s)), r AS \
         (SELECT *, CASE status WHEN 'open' THEN 0 ELSE 1 END AS rank FROM s) "
        a a,
      List.map Log.s authors @ [ Sqlite3.Data.FLOAT now ]
      @ List.map Log.s authors )

  type listed = {
    l_hash : string;
    l_status : string;
    l_created_at : string;
    l_deadline_at : string option;
    l_kind : string;
    l_title : string;
    l_sender : string option;
  }

  (* One page of the asks of [authors] as the Asks list shows them, open first and then the newest,
     with each one's status and what its row shows: those of [status] when it is given, starting after the ask [after]
     when it is given. An [after] the index does not list starts nowhere: the page is empty. *)
  let page ~authors ~now ?status ?after ~limit (log : Log.t) =
    if authors = [] then []
    else
      let w, params = listed ~authors ~now in
      let conditions =
        List.filter_map Fun.id
          [
            Option.map (fun s -> ("status = ?", [ Log.s s ])) status;
            Option.map
              (fun h ->
                ( "EXISTS (SELECT 1 FROM r c WHERE c.hash = ? AND (r.rank > \
                   c.rank OR (r.rank = c.rank AND (r.created_at < c.created_at \
                   OR (r.created_at = c.created_at AND r.hash < c.hash)))))",
                  [ Log.s h ] ))
              after;
          ]
      in
      let where =
        match conditions with
        | [] -> ""
        | l -> " WHERE " ^ String.concat " AND " (List.map fst l)
      in
      Log.rows log
        (w
       ^ "SELECT hash, status, created_at, deadline_at, kind, title, sender \
          FROM r" ^ where ^ " ORDER BY rank, created_at DESC, hash DESC LIMIT ?"
        )
        (params @ List.concat_map snd conditions @ [ Log.i limit ])
      |> List.filter_map (function
        | [| hash; status; created_at; deadline_at; kind; title; sender |] ->
            Some
              {
                l_hash = Log.text hash;
                l_status = Log.text status;
                l_created_at = Log.text created_at;
                l_deadline_at = Log.text_opt deadline_at;
                l_kind = Log.text kind;
                l_title = Log.text title;
                l_sender = Log.text_opt sender;
              }
        | _ -> None)

  (* The status of the ask [hash] at [now], when it is one of [authors]' the node can show. *)
  let status ~authors ~now (log : Log.t) hash =
    if authors = [] then None
    else
      let w, params = listed ~authors ~now in
      match
        Log.rows log
          (w ^ "SELECT status FROM r WHERE hash = ?")
          (params @ [ Log.s hash ])
      with
      | [ [| s |] ] -> Some (Log.text s)
      | _ -> None

  (* How many of [authors]' asks are open at [now]. *)
  let open_count ~authors ~now (log : Log.t) =
    if authors = [] then 0
    else
      let w, params = listed ~authors ~now in
      match
        Log.rows log (w ^ "SELECT COUNT(*) FROM r WHERE status = 'open'") params
      with
      | [ [| n |] ] -> Log.int n
      | _ -> 0

  (* The decision of [authors] that answered the ask [hash] before [lapses_at] (at any time when it
     is None), the earliest: its option and when. *)
  let decision ~authors ~lapses_at (log : Log.t) hash =
    if authors = [] then None
    else
      match
        Log.rows log
          (Printf.sprintf
             "SELECT option, decided_at FROM ui_ask_decisions WHERE ask = ? \
              AND author IN (%s) AND (? IS NULL OR decided_unix < ?) ORDER BY \
              decided_unix, hash LIMIT 1"
             (placeholders authors))
          ((Log.s hash :: List.map Log.s authors)
          @ [ real lapses_at; real lapses_at ])
      with
      | [ [| o; at |] ] -> Some (Log.text o, Log.text at)
      | _ -> None
end

(* The setup chat starts the first note at once rather than at Note time; it is the only caller,
   since a member who wants an earlier note moves Note time. *)
let k_nightly_run_now = "behavior_nightly_run_now"
let request_nightly_run log = set_config log k_nightly_run_now "1"
let nightly_run_requested log = config log k_nightly_run_now <> None

let clear_nightly_run log =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_nightly_run_now ]

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
CREATE INDEX IF NOT EXISTS ui_notes_written ON ui_notes (written_at);
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

  (* Every note the run has handed over, newest first; with [limit] one page of them, starting after
     the note [after] (ISS-41988), which starts nowhere when the store does not hold it. The first
     note's row, from the setup chat starting it until the run hands its first version over, is not
     one: it is [pending]. *)
  let all ?after ?limit (log : Log.t) =
    let cursor, cursor_params =
      match after with
      | None -> ("", [])
      | Some id ->
          ( " AND (written_at, rowid) < (SELECT written_at, rowid FROM \
             ui_notes WHERE id = ?)",
            [ Log.s id ] )
    in
    let lim, lim_params =
      match limit with None -> ("", []) | Some n -> (" LIMIT ?", [ Log.i n ])
    in
    List.map note_of
      (Log.rows log
         ("SELECT " ^ note_columns
        ^ " FROM ui_notes WHERE EXISTS (SELECT 1 FROM ui_note_versions v WHERE \
           v.note_id = ui_notes.id)" ^ cursor
        ^ " ORDER BY written_at DESC, rowid DESC" ^ lim)
         (cursor_params @ lim_params))

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

  (* The first note (docs/design.md, The setup chat and the first note): the setup chat starting it
     makes its row, so its page has an id while the run reads, writes and checks; the run's hand-over
     fills that row rather than adding one. *)
  let k_first = "setup_first_note_id"
  let first_id (log : Log.t) = config log k_first

  let has_versions (log : Log.t) id =
    Log.rows log "SELECT 1 FROM ui_note_versions WHERE note_id = ? LIMIT 1"
      [ Log.s id ]
    <> []

  (* The first note's row while the run has not handed it over. *)
  let pending (log : Log.t) =
    match Option.bind (first_id log) (find log) with
    | Some n when not (has_versions log n.n_id) -> Some n
    | _ -> None

  let start (log : Log.t) =
    if first_id log = None then begin
      let id = local_hash () in
      Log.exec log
        ("INSERT INTO ui_notes (" ^ note_columns
       ^ ") VALUES (?, ?, 'waiting', NULL, NULL, NULL, NULL)")
        [ Log.s id; Log.s (now ()) ];
      set_config log k_first id
    end

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
    let id =
      match pending log with
      | Some n ->
          Log.exec log "UPDATE ui_notes SET written_at = ? WHERE id = ?"
            [ Log.s at; Log.s n.n_id ];
          n.n_id
      | None ->
          let id = local_hash () in
          Log.exec log
            ("INSERT INTO ui_notes (" ^ note_columns
           ^ ") VALUES (?, ?, ?, NULL, NULL, NULL, NULL)")
            [ Log.s id; Log.s at; Log.s "waiting" ];
          id
    in
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
     versions and Log. The first note's row stays, for the next note time to fill. *)
  let delete (log : Log.t) ~note_id =
    let keep = first_id log = Some note_id && Record.first_note log in
    Log.transaction log (fun () ->
        List.iter
          (fun t ->
            Log.exec log
              (Printf.sprintf "DELETE FROM %s WHERE %s = ?" t
                 (if t = "ui_notes" then "id" else "note_id"))
              [ Log.s note_id ])
          ([ "ui_note_log"; "ui_note_versions" ]
          @ if keep then [] else [ "ui_notes" ]))

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

  (* Approving a note also moves each source it read to where it ends (Record.approve). *)
  let approve (log : Log.t) ~note_id ~version_id ~status =
    Log.exec log
      "UPDATE ui_notes SET status = ?, approved_version = ?, approved_at = ?, \
       held_reason = NULL WHERE id = ?"
      [ Log.s status; Log.s version_id; Log.s (now ()); Log.s note_id ];
    Record.approve log ~note_id

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
  let suggest_after = 5

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

  (* Starts the first note: its row, so the browser opens on its page, and the run that fills it. *)
  let start_first_note log =
    if first_note_started log = None then begin
      Notes.start log;
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

(* The columns of these tables that name an envelope, moved with it when the node re-signs an own
   envelope a relay never took (Node.drop_refused). *)
let register_hash_columns () =
  Digestif_daily.Store.register_hash_columns ();
  List.iter
    (fun (table, column, on_delete) ->
      Log.register_hash_column ~table ~column on_delete)
    [
      ("ui_outbox", "posted_hash", `Keep);
      ("ui_notes", "posted_hash", `Keep);
      ("ui_ask_index", "hash", `Delete);
      ("ui_ask_decisions", "hash", `Delete);
      ("ui_ask_decisions", "ask", `Null);
    ]

let init (log : Log.t) =
  register_hash_columns ();
  init_base log;
  Record.init log;
  Checks.init log;
  Problems.init log;
  Repositories.init log;
  Scan_index.init log;
  Ask_index.init log;
  Setup.init log;
  Notes.init log;
  Settings.init log;
  Stages.init log;
  Pause.init log
