(* What the daily acts keep beside the log: asks a behavior queued for the next digest, the mail
   requests the mailing relay has not yet accepted, and the outcome the node settled for each ask.
   Envelopes stay in the log; these tables hold only what no envelope carries. *)

open Digestif_core

let schema =
  [
    {|CREATE TABLE IF NOT EXISTS pending_asks (
  id INTEGER PRIMARY KEY,
  ask TEXT NOT NULL,
  queued_at TEXT NOT NULL
)|};
    {|CREATE TABLE IF NOT EXISTS mail_requests (
  digest TEXT PRIMARY KEY,
  relay TEXT NOT NULL,
  request TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_error TEXT
)|};
    {|CREATE TABLE IF NOT EXISTS ask_outcomes (
  ask TEXT PRIMARY KEY,
  option TEXT NOT NULL,
  decision TEXT,
  source TEXT NOT NULL,
  decided_at TEXT NOT NULL
)|};
  ]

let ensure (log : Log.t) = List.iter (fun sql -> Log.exec log sql []) schema

(* pending asks *)

let queue_ask log (ask : Digestif_mail.Ask.t) =
  ensure log;
  Log.exec log "INSERT INTO pending_asks (ask, queued_at) VALUES (?, ?)"
    [
      Log.s (Yojson.Safe.to_string (Digestif_mail.Ask.plaintext ask));
      Log.s (Time_fmt.now ());
    ]

let pending_asks log =
  ensure log;
  List.filter_map
    (function
      | [| id; a |] -> (
          match
            Digestif_mail.Ask.of_plaintext
              (Yojson.Safe.from_string (Log.text a))
          with
          | Ok ask -> Some (Log.int id, ask)
          | Error _ -> None)
      | _ -> None)
    (Log.rows log "SELECT id, ask FROM pending_asks ORDER BY id" [])

let drop_pending_ask log id =
  Log.exec log "DELETE FROM pending_asks WHERE id = ?" [ Log.i id ]

(* mail requests: sealed to the mailing relay's key, so the link secrets are on disk only inside a
   value that relay alone opens, and only until it accepts the request. *)

type mail_request = {
  digest : string;
  relay : string;
  request : Yojson.Safe.t;
  last_error : string option;
}

let add_mail_request log ~digest ~relay request =
  ensure log;
  Log.exec log
    "INSERT OR REPLACE INTO mail_requests (digest, relay, request, created_at) \
     VALUES (?, ?, ?, ?)"
    [
      Log.s digest;
      Log.s relay;
      Log.s (Yojson.Safe.to_string request);
      Log.s (Time_fmt.now ());
    ]

let mail_requests log =
  ensure log;
  List.map
    (function
      | [| d; r; q; e |] ->
          {
            digest = Log.text d;
            relay = Log.text r;
            request = Yojson.Safe.from_string (Log.text q);
            last_error = Log.text_opt e;
          }
      | _ -> assert false)
    (Log.rows log
       "SELECT digest, relay, request, last_error FROM mail_requests ORDER BY \
        created_at"
       [])

let drop_mail_request log digest =
  Log.exec log "DELETE FROM mail_requests WHERE digest = ?" [ Log.s digest ]

let mail_request_failed log digest error =
  Log.exec log "UPDATE mail_requests SET last_error = ? WHERE digest = ?"
    [ Log.s error; Log.s digest ]

(* outcomes *)

type source = Decided | Lapsed

type outcome = {
  option : string;
  decision : string option;  (** the decision envelope acted on *)
  source : source;
  decided_at : string;
}

let outcome log ask =
  ensure log;
  match
    Log.rows log
      "SELECT option, decision, source, decided_at FROM ask_outcomes WHERE ask \
       = ?"
      [ Log.s ask ]
  with
  | [ [| o; d; s; at |] ] ->
      Some
        {
          option = Log.text o;
          decision = Log.text_opt d;
          source = (if Log.text s = "lapsed" then Lapsed else Decided);
          decided_at = Log.text at;
        }
  | _ -> None

let record_outcome log ~ask o =
  Log.exec log
    "INSERT OR IGNORE INTO ask_outcomes (ask, option, decision, source, \
     decided_at) VALUES (?, ?, ?, ?, ?)"
    [
      Log.s ask;
      Log.s o.option;
      Log.opt o.decision;
      Log.s (match o.source with Decided -> "decision" | Lapsed -> "lapsed");
      Log.s o.decided_at;
    ]
