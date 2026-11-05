(* The Cloudflare API, as the operator's node calls it with the relay's deploy token
   (docs/releases.md, Who operates a relay). The token reaches curl in a config file on stdin
   (`curl -K -`), never on an argv, where every process on the machine could read it; the same
   discipline the keystore keeps with `security -i`. The transport is a function so tests put a fake
   account behind it. *)

let api_base = "https://api.cloudflare.com/client/v4"

type transport =
  meth:string ->
  path:string ->
  token:string ->
  body:string option ->
  (Relay_client.response, string) result

(* A value in curl's config syntax: double-quoted, with backslash escapes. *)
let config_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* The config curl reads on stdin: the url, the method, the token's header and a body. Exposed so a
   test can prove the token is in it and in no argv. *)
let curl_config ~meth ~path ~token ~body =
  String.concat ""
    (List.map
       (fun (k, v) -> k ^ " = " ^ config_quote v ^ "\n")
       ([
          ("url", api_base ^ path);
          ("request", meth);
          ("header", "Authorization: Bearer " ^ token);
          ("header", "Content-Type: application/json");
        ]
       @ match body with Some b -> [ ("data-binary", b) ] | None -> []))

let curl_argv =
  [|
    "curl";
    "-sS";
    "--proto";
    "=https";
    "--proto-redir";
    "=https";
    "--max-time";
    "60";
    "-w";
    "\n%{http_code}";
    "-K";
    "-";
  |]

let curl : transport =
 fun ~meth ~path ~token ~body ->
  match Proc.run ~stdin:(curl_config ~meth ~path ~token ~body) curl_argv with
  | Error e -> Error e
  | Ok { code = 0; stdout; _ } -> (
      match String.rindex_opt stdout '\n' with
      | None -> Error "curl: no status"
      | Some i -> (
          match
            int_of_string_opt
              (String.sub stdout (i + 1) (String.length stdout - i - 1))
          with
          | Some status ->
              Ok { Relay_client.status; body = String.sub stdout 0 i }
          | None -> Error "curl: no status"))
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "curl exited %d: %s" code (String.trim stderr))

type error =
  | Unauthorized of int * string
      (** 401 or 403: the token is wrong, expired or lacks a permission. It is
          not retried until the token changes (docs/releases.md, The deploy
          step). *)
  | Rejected of int * string
      (** A 4xx other than 401 and 403, or a 200 whose envelope says it did not
          succeed: Cloudflare read the request and refused it, so the same
          request would be refused again (a migration's SQL, an upload's
          metadata). Only the requests of the deploy pass tell it apart from
          [Failed]. *)
  | Failed of string
      (** Anything else: no answer, a 5xx, a body that is not Cloudflare's. *)

let error_to_string = function
  | Unauthorized (status, m) ->
      Printf.sprintf "Cloudflare refused the deploy token (%d): %s" status m
  | Rejected (status, m) ->
      Printf.sprintf "Cloudflare refused the request (%d): %s" status m
  | Failed m -> m

(* Cloudflare's envelope: { success, errors: [{code, message}], result }. *)
let messages body =
  match Yojson.Safe.from_string body with
  | `Assoc f -> (
      match List.assoc_opt "errors" f with
      | Some (`List l) ->
          String.concat "; "
            (List.filter_map
               (function
                 | `Assoc e -> (
                     match
                       (List.assoc_opt "code" e, List.assoc_opt "message" e)
                     with
                     | Some (`Int c), Some (`String m) ->
                         Some (Printf.sprintf "%d %s" c m)
                     | _, Some (`String m) -> Some m
                     | _ -> None)
                 | _ -> None)
               l)
      | _ -> "")
  | _ | (exception _) ->
      let b = String.trim body in
      if String.length b > 200 then String.sub b 0 200 ^ "..." else b

let call (t : transport) ~token ~meth ~path =
  match t ~meth ~path ~token ~body:None with
  | Error e -> Error (Failed ("Cloudflare did not answer: " ^ e))
  | Ok { status = (401 | 403) as status; body } ->
      Error (Unauthorized (status, messages body))
  | Ok { status = 200; body } -> (
      match Yojson.Safe.from_string body with
      | `Assoc f when List.assoc_opt "success" f = Some (`Bool true) ->
          Ok (Option.value (List.assoc_opt "result" f) ~default:`Null)
      | _ -> Error (Failed ("Cloudflare answered " ^ messages body))
      | exception _ -> Error (Failed "Cloudflare's answer is not JSON"))
  | Ok { status; body } ->
      Error
        (Failed
           (Printf.sprintf "Cloudflare answered %d: %s" status (messages body)))

let str name = function
  | `Assoc f -> (
      match List.assoc_opt name f with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let ( let* ) = Result.bind

(* GET /user/tokens/verify: the token is live. A token owned by the account rather than a user
   answers only at the account's own verify route, which is asked when the user route refuses. *)
let verify_token t ~token ~account_id =
  let active result =
    match str "status" result with
    | Some "active" -> Ok ()
    | Some s -> Error (Unauthorized (401, "the token is " ^ s))
    | None -> Error (Failed "Cloudflare's token check named no status")
  in
  match call t ~token ~meth:"GET" ~path:"/user/tokens/verify" with
  | Ok r -> active r
  | Error (Unauthorized _) ->
      let* r =
        call t ~token ~meth:"GET"
          ~path:("/accounts/" ^ account_id ^ "/tokens/verify")
      in
      active r
  | Error e -> Error e

(* GET /accounts/:id/workers/scripts: the name of every Worker the token can see. *)
let workers t ~token ~account_id =
  let* r =
    call t ~token ~meth:"GET"
      ~path:("/accounts/" ^ account_id ^ "/workers/scripts")
  in
  match r with
  | `List l -> Ok (List.filter_map (str "id") l)
  | _ -> Error (Failed "Cloudflare's Worker list is not a list")

(* GET /accounts/:id/d1/database/:db: the token can read the relay's database. *)
let database t ~token ~account_id ~database_id =
  let* r =
    call t ~token ~meth:"GET"
      ~path:("/accounts/" ^ account_id ^ "/d1/database/" ^ database_id)
  in
  match str "uuid" r with
  | Some u when u = database_id -> Ok ()
  | Some u -> Error (Failed ("Cloudflare answered for database " ^ u))
  | None -> Error (Failed "Cloudflare's database answer names no uuid")

(* GET /accounts/:id/workers/scripts/:name/deployments: the Worker version serving now, which is the
   newest deployment's version carrying the most traffic (every deploy here is at 100%). *)
let serving_version t ~token ~account_id ~worker =
  let* r =
    call t ~token ~meth:"GET"
      ~path:
        ("/accounts/" ^ account_id ^ "/workers/scripts/" ^ worker
       ^ "/deployments")
  in
  let deployments =
    match r with
    | `Assoc f -> (
        match List.assoc_opt "deployments" f with
        | Some (`List l) -> l
        | _ -> [])
    | _ -> []
  in
  let created d = Option.value (str "created_on" d) ~default:"" in
  let newest =
    List.fold_left
      (fun acc d ->
        match acc with Some a when created a >= created d -> acc | _ -> Some d)
      None deployments
  in
  let versions = function
    | `Assoc f -> (
        match List.assoc_opt "versions" f with
        | Some (`List l) ->
            List.filter_map
              (fun v ->
                let pct =
                  match v with
                  | `Assoc g -> (
                      match List.assoc_opt "percentage" g with
                      | Some (`Int i) -> float_of_int i
                      | Some (`Float x) -> x
                      | _ -> 0.)
                  | _ -> 0.
                in
                Option.map (fun id -> (pct, id)) (str "version_id" v))
              l
        | _ -> [])
    | _ -> []
  in
  match newest with
  | None -> Error (Failed (worker ^ " has no deployment serving"))
  | Some d -> (
      match List.sort (fun (a, _) (b, _) -> compare b a) (versions d) with
      | (_, id) :: _ -> Ok id
      | [] -> Error (Failed (worker ^ "'s deployment names no version")))

(* The deploy pass's requests (docs/releases.md, The deploy step). Unlike [call], a refusal
   Cloudflare means ([Rejected]) is told apart from one that may pass on a later try ([Failed]), and
   a 201 is an answer: the assets upload answers its last bucket with one. *)
let envelope (r : Relay_client.response) =
  match r with
  | { status = (401 | 403) as status; body } ->
      Error (Unauthorized (status, messages body))
  | { status = (200 | 201) as status; body } -> (
      match Yojson.Safe.from_string body with
      | `Assoc f when List.assoc_opt "success" f = Some (`Bool true) ->
          Ok (Option.value (List.assoc_opt "result" f) ~default:`Null)
      | `Assoc _ -> Error (Rejected (status, messages body))
      | _ -> Error (Failed "Cloudflare's answer is not a JSON object")
      | exception _ -> Error (Failed "Cloudflare's answer is not JSON"))
  | { status; body } when status >= 400 && status < 500 ->
      Error (Rejected (status, messages body))
  | { status; body } ->
      Error
        (Failed
           (Printf.sprintf "Cloudflare answered %d: %s" status (messages body)))

let request (t : transport) ~token ~meth ~path ?body () =
  let body = Option.map Yojson.Safe.to_string body in
  match t ~meth ~path ~token ~body with
  | Error e -> Error (Failed ("Cloudflare did not answer: " ^ e))
  | Ok r -> envelope r

(* A multipart/form-data part: the file at [file] sent as field [name] with [content_type]. *)
type part = { name : string; file : string; content_type : string }

(* A multipart POST, the token and every part in curl's config on stdin, as for [transport]. *)
type form_transport =
  path:string ->
  token:string ->
  parts:part list ->
  (Relay_client.response, string) result

let form_config ~path ~token ~parts =
  String.concat ""
    (List.map
       (fun (k, v) -> k ^ " = " ^ config_quote v ^ "\n")
       ([
          ("url", api_base ^ path);
          ("request", "POST");
          ("header", "Authorization: Bearer " ^ token);
        ]
       @ List.map
           (fun p ->
             ("form", p.name ^ "=@" ^ p.file ^ ";type=" ^ p.content_type))
           parts))

let form_curl : form_transport =
 fun ~path ~token ~parts ->
  (* An upload carries the whole Worker or a bucket of assets: five minutes, not one. *)
  let argv =
    Array.mapi
      (fun i a ->
        if i > 0 && curl_argv.(i - 1) = "--max-time" then "300" else a)
      curl_argv
  in
  match Proc.run ~stdin:(form_config ~path ~token ~parts) argv with
  | Error e -> Error e
  | Ok { code = 0; stdout; _ } -> (
      match String.rindex_opt stdout '\n' with
      | None -> Error "curl: no status"
      | Some i -> (
          match
            int_of_string_opt
              (String.sub stdout (i + 1) (String.length stdout - i - 1))
          with
          | Some status ->
              Ok { Relay_client.status; body = String.sub stdout 0 i }
          | None -> Error "curl: no status"))
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "curl exited %d: %s" code (String.trim stderr))

let form (t : form_transport) ~token ~path parts =
  match t ~path ~token ~parts with
  | Error e -> Error (Failed ("Cloudflare did not answer: " ^ e))
  | Ok r -> envelope r

let script_path ~account_id ~worker rest =
  "/accounts/" ^ account_id ^ "/workers/scripts/" ^ worker ^ rest

(* POST /accounts/:id/d1/database/:db/query: run [sql], every statement of it, and answer the rows
   of each statement's result. A statement D1 refuses is [Rejected]. *)
let d1_query t ~token ~account_id ~database_id sql =
  let* r =
    request t ~token ~meth:"POST"
      ~path:
        ("/accounts/" ^ account_id ^ "/d1/database/" ^ database_id ^ "/query")
      ~body:(`Assoc [ ("sql", `String sql) ])
      ()
  in
  match r with
  | `List results ->
      let failed =
        List.find_opt
          (function
            | `Assoc f -> List.assoc_opt "success" f = Some (`Bool false)
            | _ -> false)
          results
      in
      if failed <> None then Error (Rejected (200, "D1 did not run the SQL"))
      else
        Ok
          (List.map
             (function
               | `Assoc f -> (
                   match List.assoc_opt "results" f with
                   | Some (`List rows) -> rows
                   | _ -> [])
               | _ -> [])
             results)
  | _ -> Error (Failed "D1's answer is not a list of results")

(* A Worker version as GET .../versions lists it: its id and its annotations. *)
type version = { id : string; tag : string option; message : string option }

let version_of_json j =
  let annotations =
    match j with
    | `Assoc f -> Option.value (List.assoc_opt "annotations" f) ~default:`Null
    | _ -> `Null
  in
  Option.map
    (fun id ->
      {
        id;
        tag = str "workers/tag" annotations;
        message = str "workers/message" annotations;
      })
    (str "id" j)

(* GET .../workers/scripts/:name/versions: the Worker's versions, newest first as Cloudflare lists
   them. *)
let versions t ~token ~account_id ~worker =
  let* r =
    request t ~token ~meth:"GET"
      ~path:(script_path ~account_id ~worker "/versions")
      ()
  in
  let items =
    match r with
    | `Assoc f -> (
        match List.assoc_opt "items" f with Some (`List l) -> l | _ -> [])
    | `List l -> l
    | _ -> []
  in
  Ok (List.filter_map version_of_json items)

(* POST .../workers/scripts/:name/assets-upload-session: the files Cloudflare lacks, in buckets,
   and the token that uploads them; with no bucket the token is already the completion token. *)
let assets_session t ~token ~account_id ~worker
    (manifest : (string * (string * int)) list) =
  let* r =
    request t ~token ~meth:"POST"
      ~path:(script_path ~account_id ~worker "/assets-upload-session")
      ~body:
        (`Assoc
           [
             ( "manifest",
               `Assoc
                 (List.map
                    (fun (path, (hash, size)) ->
                      ( path,
                        `Assoc [ ("hash", `String hash); ("size", `Int size) ]
                      ))
                    manifest) );
           ])
      ()
  in
  let buckets =
    match r with
    | `Assoc f -> (
        match List.assoc_opt "buckets" f with
        | Some (`List l) ->
            List.map
              (function
                | `List hs ->
                    List.filter_map
                      (function `String h -> Some h | _ -> None)
                      hs
                | _ -> [])
              l
        | _ -> [])
    | _ -> []
  in
  match str "jwt" r with
  | Some jwt -> Ok (jwt, List.filter (fun b -> b <> []) buckets)
  | None -> Error (Failed "Cloudflare's assets session named no token")

(* POST /accounts/:id/workers/assets/upload?base64=true, with the session's token: one bucket.
   Cloudflare answers every bucket but the last 202 Accepted, its body empty or an envelope with no
   token, and the last 201 with the completion token: [None] is a bucket taken with more to come. A
   202 whose envelope says it did not succeed is still a refusal. *)
let assets_upload ft ~jwt ~account_id parts =
  let path = "/accounts/" ^ account_id ^ "/workers/assets/upload?base64=true" in
  match ft ~path ~token:jwt ~parts with
  | Error e -> Error (Failed ("Cloudflare did not answer: " ^ e))
  | Ok { Relay_client.status = 202; body } -> (
      match Yojson.Safe.from_string body with
      | `Assoc f when List.assoc_opt "success" f = Some (`Bool false) ->
          Error (Rejected (202, messages body))
      | _ | (exception _) -> Ok None)
  | Ok r ->
      let* r = envelope r in
      Ok (str "jwt" r)

(* POST .../workers/scripts/:name/versions: upload [parts] (the metadata and the modules) as a new
   version, deployed nowhere yet; answers its id. *)
let upload_version ft ~token ~account_id ~worker parts =
  let* r =
    form ft ~token ~path:(script_path ~account_id ~worker "/versions") parts
  in
  match str "id" r with
  | Some id -> Ok id
  | None -> Error (Failed "Cloudflare's version upload named no id")

(* POST .../workers/scripts/:name/deployments: [version_id] serves all of the Worker's traffic. *)
let deploy t ~token ~account_id ~worker ~version_id =
  let* _ =
    request t ~token ~meth:"POST"
      ~path:(script_path ~account_id ~worker "/deployments")
      ~body:
        (`Assoc
           [
             ("strategy", `String "percentage");
             ( "versions",
               `List
                 [
                   `Assoc
                     [
                       ("version_id", `String version_id);
                       ("percentage", `Int 100);
                     ];
                 ] );
           ])
      ()
  in
  Ok ()
