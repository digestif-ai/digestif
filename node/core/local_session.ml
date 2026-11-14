(* A session on this machine's local API (spec/digestif-node.json): the token a launch URL's cookie
   carries, which a behavior and `digestif-update approve` are handed directly. The log keeps only
   its hash, so the database never holds a value that opens the API. The table is the web store's
   (ui_sessions), created when the node first serves. *)

let digest token = Crypto.sha256_hex token

let mint (log : Log.t) =
  let token = B64url.encode (Crypto.random 32) in
  Log.exec log "INSERT INTO ui_sessions (token_hash, created_at) VALUES (?, ?)"
    [ Log.s (digest token); Log.s (Time_fmt.now ()) ];
  token

let valid (log : Log.t) token =
  Log.rows log "SELECT 1 FROM ui_sessions WHERE token_hash = ?"
    [ Log.s (digest token) ]
  <> []

let end_ (log : Log.t) token =
  Log.exec log "DELETE FROM ui_sessions WHERE token_hash = ?"
    [ Log.s (digest token) ]

(* The cookie and header every API request carries (node/web/server.ml, Who may call the API). *)
let cookie_name = "digestif_session"

let headers token =
  [ ("Cookie", cookie_name ^ "=" ^ token); ("Digestif-Local", "1") ]
