(* The relay's three routes (spec/digestif-relay.json), every request signed (Request_sign). The
   transport is a function so tests and the conformance suite can put an in-process relay behind it;
   the binary's transport is curl, which every Mac and Linux box carries and which brings the
   system's TLS and certificate store with it. *)

type response = { status : int; body : string }

type transport =
  meth:string ->
  url:string ->
  headers:(string * string) list ->
  body:string option ->
  (response, string) result

let curl : transport =
 fun ~meth ~url ~headers ~body ->
  let hs = List.concat_map (fun (k, v) -> [ "-H"; k ^ ": " ^ v ]) headers in
  let data =
    match body with Some _ -> [ "--data-binary"; "@-" ] | None -> []
  in
  let argv =
    Array.of_list
      ([
         "curl";
         "-sS";
         (* http only for a relay the member chose (one under development); never another scheme,
            and a redirect never leaves https. *)
         "--proto";
         "=http,https";
         "--proto-redir";
         "=https";
         "--max-time";
         "60";
         "-X";
         meth;
         "-w";
         "\n%{http_code}";
         "-H";
         "Content-Type: application/json";
       ]
      @ hs @ data @ [ "--"; url ])
  in
  match Proc.run ?stdin:body argv with
  | Error e -> Error e
  | Ok { code = 0; stdout; _ } -> (
      match String.rindex_opt stdout '\n' with
      | None -> Error "curl: no status"
      | Some i -> (
          match
            int_of_string_opt
              (String.sub stdout (i + 1) (String.length stdout - i - 1))
          with
          | Some status -> Ok { status; body = String.sub stdout 0 i }
          | None -> Error "curl: no status"))
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "curl exited %d: %s" code (String.trim stderr))

type error =
  | Transport of string
  | Refused of int * (string * string) list
      (** status, (code, message) pairs from relay_error *)
  | Unexpected of int * string

let error_to_string = function
  | Transport m -> m
  | Refused (status, errs) ->
      Printf.sprintf "%d %s" status
        (String.concat "; " (List.map (fun (c, m) -> c ^ ": " ^ m) errs))
  | Unexpected (status, body) ->
      let body = String.trim body in
      Printf.sprintf "unexpected %d: %s" status
        (if String.length body > 200 then String.sub body 0 200 ^ "..."
         else body)

let error_codes = function Refused (_, errs) -> List.map fst errs | _ -> []

(* Split a base URL into the part curl is given and the path prefix the request string must carry. *)
let split_base base =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let after_scheme =
    match String.index_opt base ':' with
    | Some i when i + 3 <= String.length base -> i + 3
    | _ -> 0
  in
  match String.index_from_opt base after_scheme '/' with
  | Some i -> (base, String.sub base i (String.length base - i))
  | None -> (base, "")

let request (transport : transport) ~base ~key ~meth ~path ?body () =
  let base, prefix = split_base base in
  let signed_path = prefix ^ path in
  let raw = Option.value body ~default:"" in
  let headers =
    Request_sign.headers ?key ~meth ~path:signed_path ~body:raw ()
  in
  match transport ~meth ~url:(base ^ path) ~headers ~body with
  | Error e -> Error (Transport e)
  | Ok r -> Ok r

let parse_errors body =
  let one j =
    match j with
    | `Assoc f -> (
        match (List.assoc_opt "code" f, List.assoc_opt "message" f) with
        | Some (`String c), Some (`String m) -> Some (c, m)
        | Some (`String c), _ -> Some (c, "")
        | _ -> None)
    | _ -> None
  in
  match Yojson.Safe.from_string body with
  | `List l -> List.filter_map one l
  | j -> Option.to_list (one j)
  | exception _ -> [ ("unparsable", body) ]

let json_or status body f =
  match Yojson.Safe.from_string body with
  | j -> (
      match f j with
      | Some v -> Ok v
      | None -> Error (Unexpected (status, body)))
  | exception _ -> Error (Unexpected (status, body))

type receipt = { duplicate : bool; relay_id : int; hash : string }

let field n = function `Assoc f -> List.assoc_opt n f | _ -> None

let to_int = function
  | Some (`Int i) -> Some i
  | Some (`Intlit s) -> int_of_string_opt s
  | _ -> None

let to_str = function Some (`String s) -> Some s | _ -> None

(* POST /v0/envelopes. [key = None] is a bootstrap append. *)
let append transport ~base ~key (sg : Envelope.signed) =
  let body = Yojson.Safe.to_string (Envelope.signed_to_json sg) in
  match
    request transport ~base ~key ~meth:"POST" ~path:"/v0/envelopes" ~body ()
  with
  | Error e -> Error e
  | Ok { status = (200 | 201) as status; body } ->
      json_or status body (fun j ->
          match (to_int (field "relay_id" j), to_str (field "hash" j)) with
          | Some relay_id, Some hash ->
              Some { duplicate = status = 200; relay_id; hash }
          | _ -> None)
  | Ok { status; body } when status = 401 || status = 422 || status = 429 ->
      Error (Refused (status, parse_errors body))
  | Ok { status; body } -> Error (Unexpected (status, body))

type stored = {
  relay_id : int;
  hash : string;
  signed : Envelope.signed;
  received_at : string option;
}

type page = { envelopes : stored list; next : int option }

let parse_stored j =
  match
    (to_int (field "relay_id" j), to_str (field "hash" j), field "envelope" j)
  with
  | Some relay_id, Some hash, Some env -> (
      match Envelope.of_json env with
      | Ok envelope ->
          let body =
            match field "body" j with None | Some `Null -> None | b -> b
          in
          Some
            {
              relay_id;
              hash;
              signed = { envelope; body };
              received_at = to_str (field "received_at" j);
            }
      | Error _ -> None)
  | _ -> None

(* GET /v0/envelopes?after=&limit= *)
let fetch transport ~base ~key ~after ~limit =
  let path = Printf.sprintf "/v0/envelopes?after=%d&limit=%d" after limit in
  match request transport ~base ~key:(Some key) ~meth:"GET" ~path () with
  | Error e -> Error e
  | Ok { status = 200; body } ->
      json_or 200 body (fun j ->
          match field "envelopes" j with
          | Some (`List l) ->
              let parsed = List.map parse_stored l in
              if List.exists Option.is_none parsed then None
              else
                Some
                  {
                    envelopes = List.filter_map Fun.id parsed;
                    next = to_int (field "next" j);
                  }
          | _ -> None)
  | Ok { status = 401; body } -> Error (Refused (401, parse_errors body))
  | Ok { status; body } -> Error (Unexpected (status, body))

(* GET /v0/circle, returned as JSON: the node trusts its own fold, and reads this to compare. *)
let circle transport ~base ~key =
  match
    request transport ~base ~key:(Some key) ~meth:"GET" ~path:"/v0/circle" ()
  with
  | Error e -> Error e
  | Ok { status = 200; body } -> json_or 200 body Option.some
  | Ok { status = 401; body } -> Error (Refused (401, parse_errors body))
  | Ok { status; body } -> Error (Unexpected (status, body))

type mail_status = Sent | Already_sent

(* POST /v0/mail (docs/protocol.md, Mailer routes): ask the mailing relay to email a digest it
   already holds. [mail_request] is Digest.mail_request's JSON. *)
let mail transport ~base ~key mail_request =
  let body = Yojson.Safe.to_string mail_request in
  match
    request transport ~base ~key:(Some key) ~meth:"POST" ~path:"/v0/mail" ~body
      ()
  with
  | Error e -> Error e
  | Ok { status = (200 | 202) as status; body } ->
      json_or status body (fun j ->
          match to_str (field "status" j) with
          | Some "sent" -> Some Sent
          | Some "already_sent" -> Some Already_sent
          | _ -> None)
  | Ok { status; body } when status = 401 || status = 404 || status = 422 ->
      Error (Refused (status, parse_errors body))
  | Ok { status; body } -> Error (Unexpected (status, body))

(* GET /v0/invites/<invite key>, the bootstrap read: signed by the invite key itself, it answers the
   dinner envelope, with its body, that lists that key while the invite is open, and 404 otherwise. *)
let invite transport ~base ~(key : Crypto.signing_key) =
  let path = "/v0/invites/" ^ Keys.public key in
  match request transport ~base ~key:(Some key) ~meth:"GET" ~path () with
  | Error e -> Error e
  | Ok { status = 200; body } -> json_or 200 body parse_stored
  | Ok { status = (401 | 404) as status; body } ->
      Error (Refused (status, parse_errors body))
  | Ok { status; body } -> Error (Unexpected (status, body))
