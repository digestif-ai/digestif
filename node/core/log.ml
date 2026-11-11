(* The node's log: every envelope it has read or written, where each relay holds it, a cursor per
   relay, the faults it found, and a little configuration. SQLite, one file in the data directory.
   Envelopes are immutable facts; the fold is recomputed from them, never stored. *)

module D = Sqlite3.Data

type t = {
  db : Sqlite3.db;
  mutable depth : int;
      (** How many [transaction]s are open on this connection: the outer one is
          BEGIN IMMEDIATE, each one inside it a savepoint. *)
}

(* The node's ask store (Asks). lapses_at is NULL for an ask that never lapses. *)
let asks_table name =
  Printf.sprintf
    {|CREATE TABLE IF NOT EXISTS %s (
  key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  detail TEXT NOT NULL,
  about TEXT,
  options TEXT NOT NULL,
  recommended TEXT NOT NULL,
  on_no_answer TEXT NOT NULL,
  lapses_at TEXT,
  raised_at TEXT NOT NULL,
  answer TEXT,
  answered_at TEXT,
  envelope TEXT,
  answered_via TEXT,
  decision TEXT,
  kind TEXT
);
|}
    name

let schema =
  asks_table "asks"
  ^ {|
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
CREATE INDEX IF NOT EXISTS envelopes_created ON envelopes (created_at, hash);
CREATE INDEX IF NOT EXISTS envelopes_author_created ON envelopes (author, created_at, hash);
CREATE INDEX IF NOT EXISTS envelopes_local_order ON envelopes (local_order);
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
CREATE TABLE IF NOT EXISTS adopted_relay_messages (
  hash TEXT PRIMARY KEY,
  url TEXT NOT NULL,
  adopted_at TEXT NOT NULL
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
DROP TABLE IF EXISTS pending_asks;
DROP TABLE IF EXISTS ask_outcomes;
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
|}

let check db rc =
  match rc with
  | Sqlite3.Rc.OK | DONE | ROW -> ()
  | rc ->
      failwith
        (Printf.sprintf "sqlite: %s: %s" (Sqlite3.Rc.to_string rc)
           (Sqlite3.errmsg db))

let close t = ignore (Sqlite3.db_close t.db)

let with_stmt t sql params f =
  let stmt = Sqlite3.prepare t.db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
    (fun () ->
      List.iteri (fun i p -> check t.db (Sqlite3.bind stmt (i + 1) p)) params;
      f stmt)

let exec t sql params =
  with_stmt t sql params (fun stmt -> check t.db (Sqlite3.step stmt))

let rows t sql params =
  with_stmt t sql params (fun stmt ->
      let rec go acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> go (Sqlite3.row_data stmt :: acc)
        | DONE -> List.rev acc
        | rc ->
            check t.db rc;
            List.rev acc
      in
      go [])

let text = function D.TEXT s -> s | D.NULL -> "" | d -> D.to_string_coerce d
let text_opt = function D.TEXT s -> Some s | _ -> None
let int = function D.INT i -> Int64.to_int i | _ -> 0
let s x = D.TEXT x
let i x = D.INT (Int64.of_int x)
let opt = function Some x -> D.TEXT x | None -> D.NULL

(* Columns a table gained after a log was first created: CREATE TABLE IF NOT EXISTS leaves an older
   table as it was, so each is added where it is missing. *)
let added_columns =
  [
    ("envelopes", "reply_to", "TEXT");
    ("asks", "envelope", "TEXT");
    ("asks", "answered_via", "TEXT");
    ("asks", "decision", "TEXT");
    ("asks", "kind", "TEXT");
  ]

let missing_columns t =
  List.filter
    (fun (table, column, _) ->
      not
        (rows t (Printf.sprintf "PRAGMA table_info(%s)" table) []
        |> List.exists (fun r -> Array.length r > 1 && text r.(1) = column)))
    added_columns

(* The message a body answers, which a content body names in the clear beside anything sealed
   (protocol.md, Content bodies). Kept as a column so the replies to one message are read by an
   index rather than by opening every message. *)
let reply_to_of = function
  | Some (`Assoc f) -> (
      match List.assoc_opt "reply_to" f with
      | Some (`String h) -> Some h
      | _ -> None)
  | _ -> None

(* A log made before envelopes carried reply_to: fill it from the bodies that name one. *)
let backfill_reply_to t =
  rows t "SELECT hash, body FROM envelopes WHERE body LIKE '%\"reply_to\"%'" []
  |> List.iter (fun r ->
      match
        reply_to_of (Option.map Yojson.Safe.from_string (text_opt r.(1)))
      with
      | Some h ->
          exec t "UPDATE envelopes SET reply_to = ? WHERE hash = ?"
            [ s h; r.(0) ]
      | None -> ())

(* Every write that reads first runs here. BEGIN IMMEDIATE takes the write lock up front, where the
   busy handler waits for it; a deferred transaction that reads and then writes is refused BUSY under
   WAL without waiting, whenever another connection committed after its read. *)
(* A transaction opened inside another (a store write the daily digest's transaction reaches) is a
   savepoint of the outer one: SQLite refuses a second BEGIN, and the inner write commits with the
   outer one, or rolls back alone when it raises. *)
let transaction t f =
  let open_, commit, rollback =
    if t.depth = 0 then ("BEGIN IMMEDIATE", [ "COMMIT" ], [ "ROLLBACK" ])
    else
      let name = Printf.sprintf "nested_%d" t.depth in
      ( "SAVEPOINT " ^ name,
        [ "RELEASE " ^ name ],
        [ "ROLLBACK TO " ^ name; "RELEASE " ^ name ] )
  in
  exec t open_ [];
  t.depth <- t.depth + 1;
  let close stmts =
    t.depth <- t.depth - 1;
    List.iter (fun sql -> exec t sql []) stmts
  in
  match f () with
  | v ->
      close commit;
      v
  | exception e ->
      close rollback;
      raise e

(* A log made while every ask lapsed holds lapses_at NOT NULL, which SQLite cannot relax in place:
   the table is rebuilt with every row, in one transaction. *)
let asks_lapse_optional t =
  let not_null () =
    rows t "PRAGMA table_info(asks)" []
    |> List.exists (fun r ->
        Array.length r > 3 && text r.(1) = "lapses_at" && int r.(3) = 1)
  in
  let columns =
    "key, title, detail, about, options, recommended, on_no_answer, lapses_at, \
     raised_at, answer, answered_at, envelope, answered_via, decision, kind"
  in
  (* Read again under the write lock, so a second process opening the same log rebuilds nothing. *)
  if not_null () then
    transaction t (fun () ->
        if not_null () then begin
          check t.db (Sqlite3.exec t.db (asks_table "asks_rebuilt"));
          exec t
            (Printf.sprintf "INSERT INTO asks_rebuilt (%s) SELECT %s FROM asks"
               columns columns)
            [];
          exec t "DROP TABLE asks" [];
          exec t "ALTER TABLE asks_rebuilt RENAME TO asks" []
        end)

(* How long a statement waits for another connection's lock before it answers BUSY. The daemon, its
   per-request connections, the behaviors and every CLI call share one log, and a writer holds the
   lock only for a local transaction (no transaction spans a relay call), so this is a ceiling a
   healthy node never reaches. *)
let busy_timeout_ms = 5000

(* [transaction] when the write lock is free now, [None] when another connection holds it. For upkeep a
   reader can go without (bringing a derived index up to the log): a request that waits for the lock
   waits for whatever the holder is doing, a page store of a sync, the scan's writes, a behavior's
   CLI call, and a page waiting on it paints nothing. Inside an open transaction it is a savepoint, as
   [transaction] is. ISS-78820 *)
let try_transaction t f =
  if t.depth > 0 then Some (transaction t f)
  else begin
    Sqlite3.busy_timeout t.db 0;
    let rc =
      Fun.protect
        ~finally:(fun () -> Sqlite3.busy_timeout t.db busy_timeout_ms)
        (fun () -> Sqlite3.exec t.db "BEGIN IMMEDIATE")
    in
    match rc with
    | Sqlite3.Rc.BUSY | LOCKED -> None
    | rc -> (
        check t.db rc;
        t.depth <- 1;
        let close stmts =
          t.depth <- 0;
          List.iter (fun sql -> exec t sql []) stmts
        in
        match f () with
        | v ->
            close [ "COMMIT" ];
            Some v
        | exception e ->
            close [ "ROLLBACK" ];
            raise e)
  end

(* The journal mode a log runs in, read or set by the pragma. *)
let journal_mode db sql =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
    (fun () ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Ok (D.to_string_coerce (Sqlite3.column stmt 0))
      | rc -> Error rc)

(* Every connection runs the log in WAL, so readers never wait for a writer. A log already in WAL
   answers at once. Switching a new log takes an exclusive lock that SQLite does not wait for through
   the busy handler, so processes creating the same log at once are refused BUSY: the switch is tried
   again until it lands or the busy timeout has passed, and whichever process won it leaves the log
   in WAL for the rest. ISS-47731 *)
let use_wal db =
  let deadline = Unix.gettimeofday () +. (float busy_timeout_ms /. 1000.) in
  let rec go () =
    match journal_mode db "PRAGMA journal_mode=WAL" with
    | Ok "wal" -> ()
    | (Ok _ | Error (Sqlite3.Rc.BUSY | LOCKED))
      when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.02;
        go ()
    | Ok mode ->
        failwith ("sqlite: the log could not run in WAL, it is in " ^ mode)
    | Error rc -> check db rc
  in
  go ()

let open_ path =
  let db = Sqlite3.db_open path in
  (* The busy handler goes on before any statement runs, so every statement after it waits for
     another connection's lock rather than answering BUSY at once. ISS-47731 *)
  Sqlite3.busy_timeout db busy_timeout_ms;
  use_wal db;
  check db (Sqlite3.exec db "PRAGMA foreign_keys=ON;");
  check db (Sqlite3.exec db schema);
  let t = { db; depth = 0 } in
  (* A column and what fills it land together, so a log is never left with one and not the other.
     Read again under the write lock: two processes opening an older log at once both see the column
     missing, and only the first adds it. *)
  if missing_columns t <> [] then
    transaction t (fun () ->
        List.iter
          (fun (table, column, ty) ->
            exec t
              (Printf.sprintf "ALTER TABLE %s ADD COLUMN %s %s" table column ty)
              [];
            if (table, column) = ("envelopes", "reply_to") then
              backfill_reply_to t)
          (missing_columns t));
  asks_lapse_optional t;
  check db
    (Sqlite3.exec db
       "CREATE INDEX IF NOT EXISTS envelopes_reply_to ON envelopes (reply_to);");
  t

(* config *)

let get_config t key =
  match rows t "SELECT value FROM config WHERE key = ?" [ s key ] with
  | [ [| v |] ] -> Some (text v)
  | _ -> None

let unset_config t key = exec t "DELETE FROM config WHERE key = ?" [ s key ]

let set_config t key value =
  exec t
    "INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE \
     SET value = excluded.value"
    [ s key; s value ]

(* relays *)

type relay_row = {
  url : string;
  cursor : int;
  last_sync_at : string option;
  last_error : string option;
}

let add_relay t url =
  exec t "INSERT OR IGNORE INTO relays (url, added_at) VALUES (?, ?)"
    [ s url; s (Time_fmt.now ()) ]

let remove_relay t url = exec t "DELETE FROM relays WHERE url = ?" [ s url ]

(* A relay message adds its URL once, so a relay removed here stays removed. *)
let relay_message_adopted t hash =
  rows t "SELECT 1 FROM adopted_relay_messages WHERE hash = ?" [ s hash ] <> []

let adopt_relay_message t ~hash url =
  add_relay t url;
  exec t
    "INSERT OR IGNORE INTO adopted_relay_messages (hash, url, adopted_at) \
     VALUES (?, ?, ?)"
    [ s hash; s url; s (Time_fmt.now ()) ]

let relays t =
  List.map
    (function
      | [| u; c; l; e |] ->
          {
            url = text u;
            cursor = int c;
            last_sync_at = text_opt l;
            last_error = text_opt e;
          }
      | _ -> assert false)
    (rows t
       "SELECT url, cursor, last_sync_at, last_error FROM relays ORDER BY url"
       [])

let set_cursor t url cursor =
  exec t "UPDATE relays SET cursor = ? WHERE url = ?" [ i cursor; s url ]

let record_sync t url error =
  exec t "UPDATE relays SET last_sync_at = ?, last_error = ? WHERE url = ?"
    [ s (Time_fmt.now ()); opt error; s url ]

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
        match Envelope.of_json (Yojson.Safe.from_string (text env)) with
        | Ok e -> e
        | Error _ -> failwith "corrupt log row"
      in
      let body = Option.map Yojson.Safe.from_string (text_opt body) in
      {
        hash = text h;
        signed = { envelope; body };
        retracted_by = text_opt r;
        local_order = int lo;
      }
  | _ -> assert false

let find t hash =
  match
    rows t
      ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE hash = ?")
      [ s hash ]
  with
  | [ r ] -> Some (row_of r)
  | _ -> None

let by_author_seq t ~author ~seq =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns
      ^ " FROM envelopes WHERE author = ? AND seq = ? ORDER BY hash")
       [ s author; i seq ])

let all t =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns ^ " FROM envelopes ORDER BY local_order")
       [])

let by_author t author =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns
      ^ " FROM envelopes WHERE author = ? ORDER BY seq, hash")
       [ s author ])

let of_kind t kind =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns
      ^ " FROM envelopes WHERE kind = ? ORDER BY local_order")
       [ s kind ])

(* The envelopes of any of [kinds], read by the kind index, so a reader of a few kinds never decodes
   the rest of the log. *)
let of_kinds t kinds =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns ^ " FROM envelopes WHERE kind IN ("
       ^ String.concat ", " (List.map (fun _ -> "?") kinds)
       ^ ") ORDER BY local_order")
       (List.map s kinds))

let placeholders xs = String.concat ", " (List.map (fun _ -> "?") xs)

(* The envelopes matching [where], newest first by (created_at, hash), each handed to [f] as SQLite
   steps to it, until [f] answers [`Stop]. An index walks them in that order with no sort, the
   created_at one or, given [author], that author's, so a reader that wants one page decodes that
   page and the rows it passed over on the way, never the rest of the log. *)
let newest_first t ?author ~where params f =
  let index, where, params =
    match author with
    | Some a ->
        ("envelopes_author_created", "author = ? AND " ^ where, s a :: params)
    | None -> ("envelopes_created", where, params)
  in
  with_stmt t
    ("SELECT " ^ envelope_columns ^ " FROM envelopes INDEXED BY " ^ index
   ^ " WHERE " ^ where ^ " ORDER BY created_at DESC, hash DESC")
    params
    (fun stmt ->
      let rec go () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> (
            match f (row_of (Sqlite3.row_data stmt)) with
            | `Continue -> go ()
            | `Stop -> ())
        | DONE -> ()
        | rc -> check t.db rc
      in
      go ())

(* Whether any envelope matches [where]. *)
let exists t ~where params =
  rows t ("SELECT 1 FROM envelopes WHERE " ^ where ^ " LIMIT 1") params <> []

(* The envelopes of [kinds] that answer [hash], oldest first, by the reply_to index. *)
let replies t ~kinds hash =
  List.map row_of
    (rows t
       ("SELECT " ^ envelope_columns
      ^ " FROM envelopes WHERE reply_to = ? AND kind IN (" ^ placeholders kinds
      ^ ") ORDER BY created_at, hash")
       (s hash :: List.map s kinds))

let authors t =
  List.map
    (fun r -> text r.(0))
    (rows t "SELECT DISTINCT author FROM envelopes ORDER BY author" [])

let max_seq t author =
  match
    rows t "SELECT MAX(seq) FROM envelopes WHERE author = ?" [ s author ]
  with
  | [ [| D.INT n |] ] -> Some (Int64.to_int n)
  | _ -> None

let count t =
  match rows t "SELECT COUNT(*) FROM envelopes" [] with
  | [ [| n |] ] -> int n
  | _ -> 0

type insert = Inserted | Already_held | Body_restored

(* Store a verified envelope. Idempotent by hash; a body arriving for an envelope held without one
   is kept unless the envelope was retracted. Its local_order is one past the highest held, which
   envelopes_local_order answers from the index's end rather than a scan of the log (ISS-47475). *)
let insert t ~hash (sg : Envelope.signed) =
  let e = sg.envelope in
  let body = Option.map Yojson.Safe.to_string sg.body in
  match find t hash with
  | Some r ->
      if r.signed.body = None && body <> None && r.retracted_by = None then begin
        exec t "UPDATE envelopes SET body = ?, reply_to = ? WHERE hash = ?"
          [ opt body; opt (reply_to_of sg.body); s hash ];
        Body_restored
      end
      else Already_held
  | None ->
      exec t
        "INSERT INTO envelopes (hash, author, seq, prev, kind, epoch, \
         created_at, envelope, body, reply_to, local_order, stored_at) VALUES \
         (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(local_order), 0) \
         + 1 FROM envelopes), ?)"
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
          opt (reply_to_of sg.body);
          s (Time_fmt.now ());
        ];
      Inserted

(* Drop a retracted envelope's body, keeping the envelope as a verifiable tombstone. *)
let drop_body t ~hash ~retracted_by =
  exec t "UPDATE envelopes SET body = NULL, retracted_by = ? WHERE hash = ?"
    [ s retracted_by; s hash ]

(* sightings *)

let add_sighting t ~relay ~relay_id ~hash ~received_at =
  exec t
    "INSERT INTO sightings (relay, relay_id, hash, received_at) VALUES (?, ?, \
     ?, ?) ON CONFLICT (relay, hash) DO UPDATE SET relay_id = \
     excluded.relay_id"
    [ s relay; i relay_id; s hash; opt received_at ]

let sightings t hash =
  List.map
    (function
      | [| r; id; at |] -> (text r, int id, text_opt at) | _ -> assert false)
    (rows t
       "SELECT relay, relay_id, received_at FROM sightings WHERE hash = ? \
        ORDER BY relay"
       [ s hash ])

let held_by t ~relay hash =
  rows t "SELECT 1 FROM sightings WHERE relay = ? AND hash = ?"
    [ s relay; s hash ]
  <> []

(* Whether any relay holds [hash]: an envelope no relay holds is one no other node can have read. *)
let sighted t hash =
  rows t "SELECT 1 FROM sightings WHERE hash = ? LIMIT 1" [ s hash ] <> []

(* The columns outside the envelopes table that name an envelope by hash, and what becomes of a row
   whose envelope is removed: [`Null] clears the column, [`Delete] drops the row (an index keyed by
   the hash), [`Keep] leaves the record of what was posted alone. A store that keeps such a column registers it once, where it creates its table. *)
let hash_columns : (string * string * [ `Null | `Delete | `Keep ]) list ref =
  ref
    [
      ("adopted_relay_messages", "hash", `Delete);
      ("asks", "envelope", `Null);
      ("asks", "decision", `Null);
    ]

let register_hash_column ~table ~column on_delete =
  if not (List.mem (table, column, on_delete) !hash_columns) then
    hash_columns := !hash_columns @ [ (table, column, on_delete) ]

let has_table t name =
  rows t "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
    [ s name ]
  <> []

let each_hash_column t f =
  List.iter
    (fun (table, column, on_delete) ->
      if has_table t table then f table column on_delete)
    !hash_columns

(* An own envelope no relay holds, written over or removed (Node.drop_refused). Each is kept only
   until a relay takes it, so nothing else on the wire names it; the local rows that do are moved to
   the new hash, or let go with the removed one. *)
let delete t hash =
  exec t "DELETE FROM envelopes WHERE hash = ?" [ s hash ];
  each_hash_column t (fun table column on_delete ->
      match on_delete with
      | `Keep -> ()
      | `Delete ->
          exec t
            (Printf.sprintf "DELETE FROM %s WHERE %s = ?" table column)
            [ s hash ]
      | `Null ->
          exec t
            (Printf.sprintf "UPDATE %s SET %s = NULL WHERE %s = ?" table column
               column)
            [ s hash ])

let rewrite t ~old_hash ~hash (sg : Envelope.signed) =
  let e = sg.envelope in
  let body = Option.map Yojson.Safe.to_string sg.body in
  exec t
    "UPDATE envelopes SET hash = ?, seq = ?, prev = ?, envelope = ?, body = ?, \
     reply_to = ? WHERE hash = ?"
    [
      s hash;
      i e.seq;
      opt e.prev;
      s (Yojson.Safe.to_string (Envelope.to_json e));
      opt body;
      opt (reply_to_of sg.body);
      s old_hash;
    ];
  each_hash_column t (fun table column _ ->
      exec t
        (Printf.sprintf "UPDATE %s SET %s = ? WHERE %s = ?" table column column)
        [ s hash; s old_hash ])

(* faults *)

type fault = {
  kind : string;
  author : string;
  seq : int;
  detail : string;
  detected_at : string;
}

let add_fault t ~kind ~author ~seq ~detail =
  exec t
    "INSERT OR IGNORE INTO faults (kind, author, seq, detail, detected_at) \
     VALUES (?, ?, ?, ?, ?)"
    [ s kind; s author; i seq; s detail; s (Time_fmt.now ()) ]

let resolve_faults t ~kind ~author ~seq =
  exec t
    "UPDATE faults SET resolved_at = ? WHERE kind = ? AND author = ? AND seq = \
     ? AND resolved_at IS NULL"
    [ s (Time_fmt.now ()); s kind; s author; i seq ]

(* Resolve the faults of [kind] at [author]/[seq] that name [relay]: the faults whose detail starts
   with the relay's URL, so a push one relay took leaves another relay's refusal open. *)
let resolve_relay_faults t ~kind ~author ~seq ~relay =
  exec t
    "UPDATE faults SET resolved_at = ? WHERE kind = ? AND author = ? AND seq = \
     ? AND substr(detail, 1, ?) = ? AND resolved_at IS NULL"
    [
      s (Time_fmt.now ());
      s kind;
      s author;
      i seq;
      i (String.length relay + 1);
      s (relay ^ " ");
    ]

let open_faults t =
  List.map
    (function
      | [| k; a; sq; d; at |] ->
          {
            kind = text k;
            author = text a;
            seq = int sq;
            detail = text d;
            detected_at = text at;
          }
      | _ -> assert false)
    (rows t
       "SELECT kind, author, seq, detail, detected_at FROM faults WHERE \
        resolved_at IS NULL ORDER BY id"
       [])

(* The fold's input: every circle-state entry in the log, read by the kind index. The fold ignores
   every other kind, so content (a summary per member per night, asks and their decisions) is never
   read or decoded here, and a request's fold grows with the circle, not with the node's age. *)
let fold_entries t =
  List.map
    (fun r ->
      { Fold.hash = r.hash; envelope = r.signed.envelope; body = r.signed.body })
    (of_kinds t Envelope.circle_state_kinds)
