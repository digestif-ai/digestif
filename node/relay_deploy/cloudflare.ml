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
  | Failed of string
      (** Anything else: no answer, a 5xx, a body that is not Cloudflare's. *)

let error_to_string = function
  | Unauthorized (status, m) ->
      Printf.sprintf "Cloudflare refused the deploy token (%d): %s" status m
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
