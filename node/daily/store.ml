(* What the daily acts keep beside the log: the mail requests the mailing relay has not yet
   accepted. Envelopes stay in the log, and asks in the node's ask store (Asks); this table holds
   only what neither carries. *)

open Digestif_core

let schema =
  [
    {|CREATE TABLE IF NOT EXISTS mail_requests (
  digest TEXT PRIMARY KEY,
  relay TEXT NOT NULL,
  request TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_error TEXT
)|};
  ]

(* A digest re-signed after an own envelope a relay refused (Node.drop_refused) moves its request
   to the new hash, and a digest dropped takes its request with it. Only the link secrets in the
   request are sealed; the digest it names is the row's own column, written into the request as it
   is read (mail_requests), so a moved row sends the new hash. *)
let register_hash_columns () =
  Log.register_hash_column ~table:"mail_requests" ~column:"digest" `Delete

let () = register_hash_columns ()
let ensure (log : Log.t) = List.iter (fun sql -> Log.exec log sql []) schema

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

(* [request] naming [digest]: the column is what a re-sign moves, so it wins over the hash the
   request was written with. *)
let naming digest = function
  | `Assoc fs ->
      `Assoc (("digest", `String digest) :: List.remove_assoc "digest" fs)
  | j -> j

let mail_requests log =
  ensure log;
  List.map
    (function
      | [| d; r; q; e |] ->
          let digest = Log.text d in
          {
            digest;
            relay = Log.text r;
            request = naming digest (Yojson.Safe.from_string (Log.text q));
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
