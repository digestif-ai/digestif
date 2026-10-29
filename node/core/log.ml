(* The node's log: every envelope it has read or written, where each relay holds it, a cursor per
   relay, the faults it found, and a little configuration. SQLite, one file in the data directory.
   Envelopes are immutable facts; the fold is recomputed from them, never stored. *)

module D = Sqlite3.Data

type t = { db : Sqlite3.db }

let schema =
  {|
CREATE TABLE IF NOT EXISTS envelopes (
  hash TEXT PRIMARY KEY,
  author TEXT NOT NULL,
  seq INTEGER NOT NULL,
  prev TEXT,
  kind TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  envelope TEXT NOT NULL,
  body TEXT,
  retracted_by TEXT,
  local_order INTEGER NOT NULL,
  stored_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS envelopes_author_seq ON envelopes (author, seq);
CREATE INDEX IF NOT EXISTS envelopes_kind ON envelopes (kind);
CREATE TABLE IF NOT EXISTS sightings (
  relay TEXT NOT NULL,
  relay_id INTEGER NOT NULL,
  hash TEXT NOT NULL,
  received_at TEXT,
  PRIMARY KEY (relay, hash)
);
CREATE INDEX IF NOT EXISTS sightings_hash ON sightings (hash);
CREATE TABLE IF NOT EXISTS relays (
  url TEXT PRIMARY KEY,
  cursor INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL,
  last_sync_at TEXT,
  last_error TEXT
);
CREATE TABLE IF NOT EXISTS faults (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  author TEXT NOT NULL,
  seq INTEGER NOT NULL,
  detail TEXT NOT NULL,
  detected_at TEXT NOT NULL,
  resolved_at TEXT,
  UNIQUE (kind, author, seq, detail)
);
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
|}

let check db rc =
  match rc with
  | Sqlite3.Rc.OK | DONE | ROW -> ()
  | rc -> failwith (Printf.sprintf "sqlite: %s: %s" (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db))

let open_ path =
  let db = Sqlite3.db_open path in
  check db (Sqlite3.exec db "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;");
  check db (Sqlite3.exec db schema);
  { db }

let close t = ignore (Sqlite3.db_close t.db)

let with_stmt t sql params f =
  let stmt = Sqlite3.prepare t.db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
    (fun () ->
      List.iteri (fun i p -> check t.db (Sqlite3.bind stmt (i + 1) p)) params;
      f stmt)

let exec t sql params = with_stmt t sql params (fun stmt -> check t.db (Sqlite3.step stmt))

let rows t sql params =
  with_stmt t sql params (fun stmt ->
      let rec go acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> go (Sqlite3.row_data stmt :: acc)
        | DONE -> List.rev acc
        | rc -> check t.db rc; List.rev acc
      in
      go [])

let text = function D.TEXT s -> s | D.NULL -> "" | d -> D.to_string_coerce d
let text_opt = function D.TEXT s -> Some s | _ -> None
let int = function D.INT i -> Int64.to_int i | _ -> 0
let s x = D.TEXT x
let i x = D.INT (Int64.of_int x)
let opt = function Some x -> D.TEXT x | None -> D.NULL

let transaction t f =
  exec t "BEGIN IMMEDIATE" [];
  match f () with
  | v -> exec t "COMMIT" []; v
  | exception e -> exec t "ROLLBACK" []; raise e

(* config *)

let get_config t key =
  match rows t "SELECT value FROM config WHERE key = ?" [ s key ] with [ [| v |] ] -> Some (text v) | _ -> None

let set_config t key value =
  exec t "INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value"
    [ s key; s value ]

(* relays *)

type relay_row = { url : string; cursor : int; last_sync_at : string option; last_error : string option }

let add_relay t url = exec t "INSERT OR IGNORE INTO relays (url, added_at) VALUES (?, ?)" [ s url; s (Time_fmt.now ()) ]
let remove_relay t url = exec t "DELETE FROM relays WHERE url = ?" [ s url ]

let relays t =
  List.map
    (function
      | [| u; c; l; e |] -> { url = text u; cursor = int c; last_sync_at = text_opt l; last_error = text_opt e }
      | _ -> assert false)
    (rows t "SELECT url, cursor, last_sync_at, last_error FROM relays ORDER BY url" [])

let set_cursor t url cursor = exec t "UPDATE relays SET cursor = ? WHERE url = ?" [ i cursor; s url ]

let record_sync t url error =
  exec t "UPDATE relays SET last_sync_at = ?, last_error = ? WHERE url = ?" [ s (Time_fmt.now ()); opt error; s url ]

(* envelopes *)

type row = {
  hash : string;
  signed : Envelope.signed;
  retracted_by : string option;
  local_order : int;
}

let envelope_columns = "hash, envelope, body, retracted_by, local_order"

let row_of = function
  | [| h; env; body; r; lo |] ->
      let envelope =
        match Envelope.of_json (Yojson.Safe.from_string (text env)) with Ok e -> e | Error _ -> failwith "corrupt log row"
      in
      let body = Option.map Yojson.Safe.from_string (text_opt body) in
      { hash = text h; signed = { envelope; body }; retracted_by = text_opt r; local_order = int lo }
  | _ -> assert false

let find t hash =
  match rows t ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE hash = ?") [ s hash ] with
  | [ r ] -> Some (row_of r)
  | _ -> None

let by_author_seq t ~author ~seq =
  List.map row_of
    (rows t ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE author = ? AND seq = ? ORDER BY hash") [ s author; i seq ])

let all t = List.map row_of (rows t ("SELECT " ^ envelope_columns ^ " FROM envelopes ORDER BY local_order") [])

let by_author t author =
  List.map row_of
    (rows t ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE author = ? ORDER BY seq, hash") [ s author ])

let of_kind t kind =
  List.map row_of
    (rows t ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE kind = ? ORDER BY local_order") [ s kind ])

let authors t = List.map (fun r -> text r.(0)) (rows t "SELECT DISTINCT author FROM envelopes ORDER BY author" [])

let max_seq t author =
  match rows t "SELECT MAX(seq) FROM envelopes WHERE author = ?" [ s author ] with
  | [ [| D.INT n |] ] -> Some (Int64.to_int n)
  | _ -> None

let count t = match rows t "SELECT COUNT(*) FROM envelopes" [] with [ [| n |] ] -> int n | _ -> 0

type insert = Inserted | Already_held | Body_restored

(* Store a verified envelope. Idempotent by hash; a body arriving for an envelope held without one
   is kept unless the envelope was retracted. *)
let insert t ~hash (sg : Envelope.signed) =
  let e = sg.envelope in
  let body = Option.map Yojson.Safe.to_string sg.body in
  match find t hash with
  | Some r ->
      if r.signed.body = None && body <> None && r.retracted_by = None then begin
        exec t "UPDATE envelopes SET body = ? WHERE hash = ?" [ opt body; s hash ];
        Body_restored
      end
      else Already_held
  | None ->
      exec t
        "INSERT INTO envelopes (hash, author, seq, prev, kind, epoch, created_at, envelope, body, local_order, stored_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(local_order), 0) + 1 FROM envelopes), ?)"
        [
          s hash;
          s e.author;
          i e.seq;
          opt e.prev;
          s e.kind;
          i e.epoch;
          s e.created_at;
          s (Yojson.Safe.to_string (Envelope.to_json e));
          opt body;
          s (Time_fmt.now ());
        ];
      Inserted

(* Drop a retracted envelope's body, keeping the envelope as a verifiable tombstone. *)
let drop_body t ~hash ~retracted_by =
  exec t "UPDATE envelopes SET body = NULL, retracted_by = ? WHERE hash = ?" [ s retracted_by; s hash ]

(* sightings *)

let add_sighting t ~relay ~relay_id ~hash ~received_at =
  exec t
    "INSERT INTO sightings (relay, relay_id, hash, received_at) VALUES (?, ?, ?, ?) \
     ON CONFLICT (relay, hash) DO UPDATE SET relay_id = excluded.relay_id"
    [ s relay; i relay_id; s hash; opt received_at ]

let sightings t hash =
  List.map
    (function [| r; id; at |] -> (text r, int id, text_opt at) | _ -> assert false)
    (rows t "SELECT relay, relay_id, received_at FROM sightings WHERE hash = ? ORDER BY relay" [ s hash ])

let held_by t ~relay hash =
  rows t "SELECT 1 FROM sightings WHERE relay = ? AND hash = ?" [ s relay; s hash ] <> []

(* faults *)

type fault = { kind : string; author : string; seq : int; detail : string; detected_at : string }

let add_fault t ~kind ~author ~seq ~detail =
  exec t
    "INSERT OR IGNORE INTO faults (kind, author, seq, detail, detected_at) VALUES (?, ?, ?, ?, ?)"
    [ s kind; s author; i seq; s detail; s (Time_fmt.now ()) ]

let resolve_faults t ~kind ~author ~seq =
  exec t "UPDATE faults SET resolved_at = ? WHERE kind = ? AND author = ? AND seq = ? AND resolved_at IS NULL"
    [ s (Time_fmt.now ()); s kind; s author; i seq ]

let open_faults t =
  List.map
    (function
      | [| k; a; sq; d; at |] -> { kind = text k; author = text a; seq = int sq; detail = text d; detected_at = text at }
      | _ -> assert false)
    (rows t "SELECT kind, author, seq, detail, detected_at FROM faults WHERE resolved_at IS NULL ORDER BY id" [])

(* The fold's input: every entry in the log. *)
let fold_entries t =
  List.map (fun r -> { Fold.hash = r.hash; envelope = r.signed.envelope; body = r.signed.body }) (all t)
