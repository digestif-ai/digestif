(* What the local UI keeps that never travels: the member's brief, rules, deny list, source choice,
   mutes, the notes held for approval or refused before signing, and the UI's launch tokens and
   sessions. Tables beside the log in the same SQLite file; envelopes stay in Log. *)

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
CREATE TABLE IF NOT EXISTS ui_silence_notes (
  id TEXT PRIMARY KEY,
  at TEXT NOT NULL,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ui_silence_notes_at ON ui_silence_notes (at);
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

let first_run log = config log k_sources_saved = None

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

(* The outbox: what this member's node wrote that is not, or not yet, a signed envelope. A note
   held for approval, a message the deny layer refused, a held note the member dropped. A row whose
   note was approved points at the envelope it became. *)

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
      (** Why the business-information screen held the note for its person. *)
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

(* The first five: notes approved so far. *)
let k_approved = "ui_approved_notes"
let required_approvals = 5

let approved log =
  match config log k_approved with
  | Some n -> Option.value (int_of_string_opt n) ~default:0
  | None -> 0

let set_approved log n = set_config log k_approved (string_of_int n)

(* Write a note now: the UI asks, and the next pass of `digestif run` spawns the nightly behavior,
   which counts as that local date's run the way `digestif behavior run nightly` does. The key of
   the nightly behavior's program is Behaviors.k_exe Nightly. *)
let k_nightly_run_now = "behavior_nightly_run_now"
let nightly_set log = config log "behavior_nightly" <> None
let request_nightly_run log = set_config log k_nightly_run_now "1"
let nightly_run_requested log = config log k_nightly_run_now <> None

let clear_nightly_run log =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_nightly_run_now ]

(* The nightly tick: one row per run of the member's pipeline, written by `digestif note` when the
   run hands over a note and by `digestif tick` when it hands over none. The Members page reads it to
   say why this node has gone silent. *)

type tick_outcome =
  | Posted  (** the note was signed *)
  | Held  (** the note waits for the member's approval *)
  | Refused  (** the deny layer refused the note *)
  | Quiet  (** the run had nothing to say *)
  | Harness_signed_out  (** the run could not use the member's agent harness *)
  | Failed  (** every try of the local date failed; a silence note says why *)

let tick_outcomes =
  [
    (Posted, "posted");
    (Held, "held");
    (Refused, "refused");
    (Quiet, "quiet");
    (Harness_signed_out, "harness_signed_out");
    (Failed, "failed");
  ]

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

(* A silence note: a behavior's own words for why a run handed over no note ("the harness timed
   out", "nothing new since Friday"), recorded through the local API beside the run's tick (quiet, unless
   `digestif tick` names another outcome).
   The digest's silence report carries them with the fixed reasons. *)

type silence_note = { sn_id : string; sn_at : string; sn_text : string }

let add_silence_note (log : Log.t) ?(at = now ()) ?(outcome = Quiet) text =
  let id = "silence-" ^ random_id () in
  Log.transaction log (fun () ->
      Log.exec log
        "INSERT INTO ui_silence_notes (id, at, text) VALUES (?, ?, ?)"
        [ Log.s id; Log.s at; Log.s text ];
      add_tick log ~at outcome);
  { sn_id = id; sn_at = at; sn_text = text }

(* The newest run, when it is one that failed on every try: when, and the silence note recorded
   with its tick, if any. Approvals shows it until a later run records a tick of its own. *)
let nightly_failure (log : Log.t) =
  match ticks log ~limit:1 with
  | [ { outcome = Failed; t_at } ] ->
      let note =
        match
          Log.rows log
            "SELECT text FROM ui_silence_notes WHERE at = ? ORDER BY rowid \
             DESC LIMIT 1"
            [ Log.s t_at ]
        with
        | [| text |] :: _ -> Some (Log.text text)
        | _ -> None
      in
      Some (t_at, note)
  | _ -> None

(* The notes recorded after [since], newest first. *)
let silence_notes (log : Log.t) ~since ~limit =
  List.map
    (function
      | [| id; at; text |] ->
          { sn_id = Log.text id; sn_at = Log.text at; sn_text = Log.text text }
      | _ -> assert false)
    (Log.rows log
       "SELECT id, at, text FROM ui_silence_notes WHERE at > ? ORDER BY at \
        DESC, rowid DESC LIMIT ?"
       [ Log.s since; Log.i limit ])

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
     approved; else nothing, which is the first note's reach. [recorded] says it is a point. *)
  type start = {
    start_ms : int option;
    start_sha : string option;
    recorded : bool;
  }

  let start (log : Log.t) ~now_ms key =
    match point log key with
    | Some p -> { start_ms = Some p.at_ms; start_sha = p.sha; recorded = true }
    | None when first_note log ->
        { start_ms = None; start_sha = None; recorded = false }
    | None ->
        let at = Option.value (approved_at log key) ~default:now_ms in
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

(* ISS-38777: what each check run removed and where, and the deny list's part in the PII check. *)
module Checks = struct
  let init (_ : Log.t) = ()
end

(* ISS-38783: the problem record, by job and kind. *)
module Problems = struct
  let init (_ : Log.t) = ()
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
  found_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ui_repositories (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL,
  found_at TEXT NOT NULL,
  paths TEXT NOT NULL
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

  let init (log : Log.t) = Log.check log.db (Sqlite3.exec log.db schema)

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

  let organizations (log : Log.t) =
    List.map
      (function
        | [| id; name; choice; n |] ->
            {
              o_id = Log.text id;
              o_name = Log.text name;
              choice = Log.text choice;
              repositories = Log.int n;
            }
        | _ -> assert false)
      (Log.rows log
         "SELECT o.id, o.name, o.choice, (SELECT COUNT(*) FROM ui_repositories \
          r WHERE r.organization_id = o.id) FROM ui_organizations o ORDER BY \
          lower(o.name), o.id"
         [])

  let organization log id =
    List.find_opt (fun o -> o.o_id = id) (organizations log)

  let repo_columns =
    "r.id, r.organization_id, r.name, r.status, r.found_at, r.paths"

  let repo_of = function
    | [| id; org; name; status; found_at; paths |] ->
        {
          r_id = Log.text id;
          organization_id = Log.text org;
          r_name = Log.text name;
          status = Log.text status;
          found_at = Log.text found_at;
          r_paths = strings_of_json (Log.text paths);
        }
    | _ -> assert false

  (* One page of repositories in the order the page lists them: by organization, then name. [q]
     matches a repository's or its organization's name, case aside. *)
  let repositories ?q ?status ?organization_id ~limit ~offset (log : Log.t) =
    let where =
      "WHERE (?1 IS NULL OR instr(lower(r.name), lower(?1)) > 0 OR \
       instr(lower(o.name), lower(?1)) > 0) AND (?2 IS NULL OR r.status = ?2) \
       AND (?3 IS NULL OR r.organization_id = ?3)"
    in
    let opt = function Some s -> Log.s s | None -> Sqlite3.Data.NULL in
    List.map repo_of
      (Log.rows log
         ("SELECT " ^ repo_columns
        ^ " FROM ui_repositories r JOIN ui_organizations o ON o.id = \
           r.organization_id " ^ where
        ^ " ORDER BY lower(o.name), o.id, lower(r.name), r.id LIMIT ?4 OFFSET \
           ?5")
         [ opt q; opt status; opt organization_id; Log.i limit; Log.i offset ])

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
     status and takes the clones found now; one not found keeps its row and its choice. *)
  let apply_scan (log : Log.t) ~at (found : found list) =
    let first = config log k_scanned = None in
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
                    "INSERT INTO ui_organizations (id, name, choice, found_at) \
                     VALUES (?, ?, ?, ?)"
                    [
                      Log.s f.f_org_id;
                      Log.s f.f_org_name;
                      Log.s choice;
                      Log.s at;
                    ];
                  choice
            in
            match repository log id with
            | Some _ ->
                Log.exec log "UPDATE ui_repositories SET paths = ? WHERE id = ?"
                  [ Log.s paths; Log.s id ]
            | None ->
                Log.exec log
                  "INSERT INTO ui_repositories (id, organization_id, name, \
                   status, found_at, paths) VALUES (?, ?, ?, ?, ?, ?)"
                  [
                    Log.s id;
                    Log.s f.f_org_id;
                    Log.s f.f_name;
                    Log.s (status_for_new choice);
                    Log.s at;
                    Log.s paths;
                  ])
          by_repo;
        set_config log k_scanned at)

  (* All approves every repository not declined when it is chosen; Chosen changes no status. *)
  let set_choice (log : Log.t) id choice =
    Log.transaction log (fun () ->
        Log.exec log "UPDATE ui_organizations SET choice = ? WHERE id = ?"
          [ Log.s choice; Log.s id ];
        if choice <> "chosen" then
          Log.exec log
            "UPDATE ui_repositories SET status = 'approved' WHERE \
             organization_id = ? AND status = 'undecided'"
            [ Log.s id ])

  (* Unchecking a repository under All declines it and keeps the organization's choice. *)
  let set_status (log : Log.t) id status =
    Log.exec log "UPDATE ui_repositories SET status = ? WHERE id = ?"
      [ Log.s status; Log.s id ]

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

(* ISS-38779: setup's progress, so a chat closed halfway resumes at the first item not done. *)
module Setup = struct
  let init (_ : Log.t) = ()
end

(* ISS-38782: notes, their versions and Log, Learnings, the approval setting and the count of
   unchanged approvals behind its suggestion. *)
module Notes = struct
  let init (_ : Log.t) = ()
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

(* ISS-38784: the stage and the clock. *)
module Stages = struct
  let init (_ : Log.t) = ()
end

(* ISS-38785: when and why the member paused, and the last Unpause. *)
module Pause = struct
  let init (_ : Log.t) = ()
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
