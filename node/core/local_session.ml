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

(* The cookie and header every API request carries (node/web/server.ml, Who may call the API). A
   browser keeps cookies by host and not by port, and every node on a machine answers on 127.0.0.1,
   so each node names its cookie for the port its UI bound: [cookie_name] on the standard port (and
   before any port is recorded), digestif_session_<port> on any other. The node's launch sets it,
   its API reads it, and a behavior and `digestif-update approve` send it, each from the URL the
   node recorded (behaviors/src/writer.ts sessionCookieName is this function's mirror). DIG-275 *)
let cookie_name = "digestif_session"

let port_of_url url =
  let rest =
    match String.index_opt url '/' with
    | Some i when String.length url > i + 1 && url.[i + 1] = '/' ->
        String.sub url (i + 2) (String.length url - i - 2)
    | _ -> url
  in
  let authority =
    match String.index_opt rest '/' with
    | Some i -> String.sub rest 0 i
    | None -> rest
  in
  match String.rindex_opt authority ':' with
  | Some i when not (String.contains_from authority i ']') ->
      int_of_string_opt
        (String.sub authority (i + 1) (String.length authority - i - 1))
  | _ -> None

let cookie_name_of url =
  match Option.bind url port_of_url with
  | None -> cookie_name
  | Some p when p = Service.standard_ui_port -> cookie_name
  | Some p -> cookie_name ^ "_" ^ string_of_int p

(* [url] is the node's recorded UI URL, the base the request goes to. *)
let headers ~url token =
  [
    ("Cookie", cookie_name_of (Some url) ^ "=" ^ token); ("Digestif-Local", "1");
  ]
