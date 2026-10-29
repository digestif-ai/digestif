(* The localhost server: the embedded web UI and the local API (spec/digestif-node.json) from one
   origin bound to 127.0.0.1.

   Who may call the API. A one-time launch URL, minted by `digestif open` and good for five
   minutes, sets an HttpOnly, SameSite=Strict session cookie and redirects to the UI. Every API
   request must carry that cookie and the Digestif-Local header. A page on another origin can make
   the browser send neither: the cookie is strict, and a custom header forces a CORS preflight,
   which the node never answers. The Host and Origin headers must name this machine, so a DNS
   rebinding page reaches nothing either. The static UI is public code and is served to anyone on
   the loopback. *)

open Digestif_core

let cookie_name = "digestif_session"

let security_headers =
  [
    ("X-Content-Type-Options", "nosniff");
    ("X-Frame-Options", "DENY");
    ("Referrer-Policy", "no-referrer");
    ("Content-Security-Policy", "frame-ancestors 'none'");
  ]

let respond ?(headers = []) status content_type body : Http.response =
  {
    status;
    headers = (("Content-Type", content_type) :: headers) @ security_headers;
    body;
  }

let json_response ?(headers = []) status (j : Yojson.Safe.t option) =
  match j with
  | None ->
      {
        Http.status;
        headers = (("Cache-Control", "no-store") :: headers) @ security_headers;
        body = "";
      }
  | Some j ->
      respond
        ~headers:(("Cache-Control", "no-store") :: headers)
        status "application/json" (Yojson.Safe.to_string j)

let api_error status code message =
  json_response status
    (Some
       (`List
          [ `Assoc [ ("code", `String code); ("message", `String message) ] ]))

let local_host h =
  let host =
    if String.length h > 0 && h.[0] = '[' then
      match String.index_opt h ']' with
      | Some i -> String.sub h 0 (i + 1)
      | None -> h
    else
      match String.index_opt h ':' with Some i -> String.sub h 0 i | None -> h
  in
  List.mem (String.lowercase_ascii host) [ "127.0.0.1"; "localhost"; "[::1]" ]

let origin_is_local o =
  match String.index_opt o '/' with
  | Some i when String.length o > i + 1 && o.[i + 1] = '/' ->
      let rest = String.sub o (i + 2) (String.length o - i - 2) in
      local_host rest
  | _ -> false

let cookies (req : Http.request) =
  match Http.header req "cookie" with
  | None -> []
  | Some c ->
      String.split_on_char ';' c
      |> List.filter_map (fun kv ->
          match String.index_opt kv '=' with
          | Some i ->
              Some
                ( String.trim (String.sub kv 0 i),
                  String.trim (String.sub kv (i + 1) (String.length kv - i - 1))
                )
          | None -> None)

let launch (node : Node.t) (req : Http.request) =
  match List.assoc_opt "token" req.query with
  | Some token when Store.spend_launch_token node.log token ->
      let session = Store.new_session node.log in
      respond 303 "text/plain; charset=utf-8"
        ~headers:
          [
            ("Location", "/");
            ("Cache-Control", "no-store");
            ( "Set-Cookie",
              Printf.sprintf "%s=%s; Path=/; HttpOnly; SameSite=Strict"
                cookie_name session );
          ]
        "Opening Digestif."
  | _ ->
      respond 403 "text/plain; charset=utf-8"
        "This link was already used or has expired. Run digestif open for a \
         new one."

let segments path =
  String.split_on_char '/' path
  |> List.filter (fun s -> s <> "")
  |> List.map Http.segment_decode

let static (req : Http.request) =
  match req.meth with
  | "GET" | "HEAD" -> (
      let rel =
        match segments req.path with
        | [] -> "index.html"
        | s -> String.concat "/" s
      in
      let answer (file : Assets.file) cache =
        let r =
          respond 200 file.content_type
            ~headers:[ ("Cache-Control", cache) ]
            file.data
        in
        if req.meth = "HEAD" then { r with body = "" } else r
      in
      match Assets.find rel with
      | Some f ->
          let immutable =
            String.length rel > 15 && String.sub rel 0 15 = "_app/immutable/"
          in
          answer f
            (if immutable then "public, max-age=31536000, immutable"
             else "no-cache")
      | None -> (
          (* A single-page app: any path it does not know is the shell, and its router takes over. *)
          match Assets.find "index.html" with
          | Some f -> answer f "no-cache"
          | None -> respond 404 "text/plain; charset=utf-8" "Not found."))
  | _ -> respond 405 "text/plain; charset=utf-8" "Method not allowed."

let api ?reset ~on_write (node : Node.t) (req : Http.request) =
  match Http.header req "origin" with
  | Some o when not (origin_is_local o) ->
      api_error 403 "foreign_origin" "Requests from another origin are refused."
  | _ -> (
      if Http.header req "digestif-local" <> Some "1" then
        api_error 403 "local_header" "The Digestif-Local header is required."
      else
        match List.assoc_opt cookie_name (cookies req) with
        | Some s when Store.session_valid node.log s -> (
            match segments req.path with
            | "api" :: "v0" :: [ "_reset" ] when req.meth = "POST" -> (
                match reset with
                | Some f ->
                    f ();
                    json_response 204 None
                | None -> api_error 404 "not_found" "Not found.")
            | "api" :: "v0" :: path -> (
                let body =
                  if String.trim req.body = "" then Ok None
                  else
                    match Yojson.Safe.from_string req.body with
                    | j -> Ok (Some j)
                    | exception Yojson.Json_error _ -> Error ()
                in
                match body with
                | Error () ->
                    api_error 400 "invalid_json" "The body is not JSON."
                | Ok body ->
                    let r =
                      Api.handle ~on_write node ~meth:req.meth ~path
                        ~query:req.query ~body
                    in
                    json_response r.status r.body)
            | _ -> api_error 404 "not_found" "Not found.")
        | _ ->
            api_error 401 "no_session"
              "Open Digestif with the link digestif open prints.")

let handler ?reset ?(on_write = fun () -> ()) (node : Node.t)
    (req : Http.request) =
  match Http.header req "host" with
  | Some h when local_host h ->
      let p = req.path in
      if p = "/launch" then launch node req
      else if String.length p >= 5 && String.sub p 0 5 = "/api/" then
        api ?reset ~on_write node req
      else static req
  | _ -> respond 403 "text/plain; charset=utf-8" "Unknown host."

let k_url = "ui_url"

(* Where a running node's UI answers, recorded so `digestif open` can mint a link to it. *)
let url node = Log.get_config node.Node.log k_url

let launch_url node =
  match url node with
  | None ->
      Error
        "the node's web UI is not running; start it with digestif run or \
         digestif ui"
  | Some base -> Ok (base ^ "/launch?token=" ^ Store.new_launch_token node.log)

let start ~port (node : Node.t) =
  Store.init node.log;
  match Http.listen ~port with
  | Error e -> Error e
  | Ok (fd, bound) ->
      Log.set_config node.log k_url (Printf.sprintf "http://127.0.0.1:%d" bound);
      Ok fd

let serve ?reset ?on_write ~stop (node : Node.t) fd =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Http.run ~stop (handler ?reset ?on_write node) fd
