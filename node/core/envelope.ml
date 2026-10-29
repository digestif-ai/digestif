(* The envelope (spec model `envelope`) and its three derived values (protocol.md, The envelope):
   body_hash = sha256(JCS(body)), signature = ed25519(author, JCS(envelope without signature)),
   hash = sha256(JCS(envelope with signature)). *)

type t = {
  version : int;
  author : string;
  seq : int;
  prev : string option;
  created_at : string;
  epoch : int;
  kind : string;
  body_hash : string;
  signature : string;
}

(* What a node appends and a relay stores: the envelope and, unless dropped or withheld, its body. *)
type signed = { envelope : t; body : Yojson.Safe.t option }

let version = 0

let unsigned_json e : Yojson.Safe.t =
  `Assoc
    ([
       ("version", `Int e.version);
       ("author", `String e.author);
       ("seq", `Int e.seq);
     ]
    @ (match e.prev with Some p -> [ ("prev", `String p) ] | None -> [])
    @ [
        ("created_at", `String e.created_at);
        ("epoch", `Int e.epoch);
        ("kind", `String e.kind);
        ("body_hash", `String e.body_hash);
      ])

let to_json e : Yojson.Safe.t =
  match unsigned_json e with
  | `Assoc f -> `Assoc (f @ [ ("signature", `String e.signature) ])
  | j -> j

let body_hash body = Keys.hash_of_bytes (Jcs.encode body)
let hash e = Keys.hash_of_bytes (Jcs.encode (to_json e))
let signing_bytes e = Jcs.encode (unsigned_json e)

let create ~(key : Crypto.signing_key) ~seq ?prev
    ?(created_at = Time_fmt.now ()) ~epoch ~kind body =
  let e =
    {
      version;
      author = Keys.public key;
      seq;
      prev;
      created_at;
      epoch;
      kind;
      body_hash = body_hash body;
      signature = "";
    }
  in
  let e =
    {
      e with
      signature = Keys.encode_signature (Crypto.sign key (signing_bytes e));
    }
  in
  { envelope = e; body = Some body }

type error = Malformed of string | Bad_signature of string

let error_message = function
  | Malformed m -> "malformed: " ^ m
  | Bad_signature m -> "bad_signature: " ^ m

(* The signature verifies, and the body (when present) is the one body_hash binds. *)
let verify { envelope = e; body } =
  if e.version <> version then
    Error (Malformed (Printf.sprintf "envelope version %d" e.version))
  else if e.seq < 1 || e.epoch < 0 then
    Error (Malformed "seq must be >= 1 and epoch >= 0")
  else if not (Keys.is_hash e.body_hash) then Error (Malformed "body_hash")
  else if match e.prev with Some p -> not (Keys.is_hash p) | None -> false
  then Error (Malformed "prev")
  else
    match (Keys.decode_ed25519 e.author, Keys.decode_signature e.signature) with
    | Error m, _ -> Error (Malformed ("author: " ^ m))
    | _, Error m -> Error (Malformed ("signature: " ^ m))
    | Ok pub, Ok signature -> (
        match Jcs.encode_result (unsigned_json e) with
        | Error m -> Error (Malformed m)
        | Ok bytes -> (
            if not (Crypto.verify ~pub ~signature bytes) then
              Error (Bad_signature "envelope signature")
            else
              match body with
              | None -> Ok ()
              | Some b -> (
                  match Jcs.encode_result b with
                  | Error m -> Error (Malformed ("body: " ^ m))
                  | Ok bytes ->
                      if Keys.hash_of_bytes bytes = e.body_hash then Ok ()
                      else Error (Bad_signature "body does not match body_hash")
                  )))

let ( let* ) = Result.bind

let field name conv json =
  match json with
  | `Assoc f -> (
      match List.assoc_opt name f with
      | Some v -> (
          match conv v with
          | Some x -> Ok x
          | None -> Error (Malformed ("field " ^ name)))
      | None -> Error (Malformed ("missing " ^ name)))
  | _ -> Error (Malformed "not an object")

let opt_field name conv json =
  match json with
  | `Assoc f -> (
      match List.assoc_opt name f with
      | None | Some `Null -> Ok None
      | Some v -> (
          match conv v with
          | Some x -> Ok (Some x)
          | None -> Error (Malformed ("field " ^ name))))
  | _ -> Error (Malformed "not an object")

let str = function `String s -> Some s | _ -> None

let int = function
  | `Int i -> Some i
  | `Intlit s -> int_of_string_opt s
  | _ -> None

let of_json (j : Yojson.Safe.t) =
  let* version = field "version" int j in
  let* author = field "author" str j in
  let* seq = field "seq" int j in
  let* prev = opt_field "prev" str j in
  let* created_at = field "created_at" str j in
  let* epoch = field "epoch" int j in
  let* kind = field "kind" str j in
  let* body_hash = field "body_hash" str j in
  let* signature = field "signature" str j in
  Ok
    {
      version;
      author;
      seq;
      prev;
      created_at;
      epoch;
      kind;
      body_hash;
      signature;
    }

let signed_to_json s : Yojson.Safe.t =
  `Assoc
    ([ ("envelope", to_json s.envelope) ]
    @ match s.body with Some b -> [ ("body", b) ] | None -> [])

let signed_of_json j =
  let* env = field "envelope" (fun v -> Some v) j in
  let* envelope = of_json env in
  let* body = opt_field "body" (fun v -> Some v) j in
  Ok { envelope; body }

(* Circle-state kinds go to every reader and feed the admission fold. *)
let circle_state_kinds =
  [ "dinner"; "join"; "device"; "revoke"; "card"; "relay" ]

let content_kinds =
  [
    "summary";
    "question";
    "answer";
    "proposal";
    "ask";
    "decision";
    "digest";
    "retract";
  ]

let is_circle_state kind = List.mem kind circle_state_kinds
