(* The guest's side: read the dinner that names the invite key, then write the join.

   The app is not admitted yet, so it reads the dinner through the bootstrap read
   GET /v0/invites/{invite_key}, signed by the invite key itself, and appends the join, whose own
   signatures are its proof, to every relay the dinner names. *)

let empty_body_hash = Invite_wire.sha256_hex ""

let request_string ~meth ~path ~timestamp ~nonce ~body_sha256 =
  String.concat "\n" [ "DIGESTIF-REQUEST-V0"; meth; path; timestamp; nonce; body_sha256 ]

let bootstrap_path code = "/v0/invites/" ^ Invite_code.invite_public_key code

(* The headers for the bootstrap read, signed by the invite key. *)
let bootstrap_request ~now ~nonce code =
  let key = Invite_code.invite_key code in
  let path = bootstrap_path code in
  let timestamp = Invite_wire.iso8601 now in
  let nonce = Invite_wire.b64url_encode nonce in
  let signed = request_string ~meth:"GET" ~path ~timestamp ~nonce ~body_sha256:empty_body_hash in
  ( path,
    [ ("Digestif-Key", Invite_wire.public_key key);
      ("Digestif-Timestamp", timestamp);
      ("Digestif-Nonce", nonce);
      ("Digestif-Signature", Invite_wire.sign key signed) ] )

type error =
  | Not_this_invite  (** The dinner does not name this code's invite key. *)
  | Expired of Ptime.t
  | Bad_dinner of string

let error_message = function
  | Not_this_invite -> "This invite code is not on that dinner. Ask your host for a new invite."
  | Expired t ->
      Printf.sprintf "This invite expired at %s. Ask your host for a new one." (Invite_wire.iso8601 t)
  | Bad_dinner m -> "The relay answered with a dinner that does not verify: " ^ m

(* Checks what the relay handed back before anything is signed against it: the dinner envelope
   verifies, and it names this invite key, unexpired. Returns the dinner's hash and relays. *)
let check_dinner ~now ~code ~(envelope : Yojson.Safe.t) ~(body : Yojson.Safe.t) =
  if not (Invite_wire.verify_envelope envelope body) then Error (Bad_dinner "bad signature")
  else if Invite_wire.field "kind" envelope <> Some (`String "dinner") then
    Error (Bad_dinner "not a dinner")
  else
    match Dinner.parse body with
    | Error m -> Error (Bad_dinner m)
    | Ok parsed -> (
        match Dinner.find_guest parsed (Invite_code.invite_public_key code) with
        | None -> Error Not_this_invite
        | Some g when Ptime.is_later now ~than:g.listed_expires_at -> Error (Expired g.listed_expires_at)
        | Some g -> Ok (Invite_wire.envelope_hash envelope, parsed, g))

(* The join body: the identity key signed by the invite key, the first device key signed by the
   identity key. [identity] is derived from the recovery phrase just long enough to call this. *)
let body ~dinner_hash ~code ~identity ~device : Yojson.Safe.t =
  let invite = Invite_code.invite_key code in
  let identity_key = Invite_wire.public_key identity in
  let device_key = Invite_wire.public_key device in
  let identity_signature =
    Invite_wire.sign invite
      (Invite_wire.jcs (`Assoc [ ("dinner", `String dinner_hash); ("identity_key", `String identity_key) ]))
  in
  let device_signature =
    Invite_wire.sign identity
      (Invite_wire.jcs
         (`Assoc
           [ ("identity_key", `String identity_key);
             ("device_key", `String device_key);
             ("role", `String "device") ]))
  in
  `Assoc
    [ ("dinner", `String dinner_hash);
      ("identity_key", `String identity_key);
      ("identity_signature", `String identity_signature);
      ("device_key", `String device_key);
      ("device_signature", `String device_signature) ]

(* The invite key's only envelope: seq 1, no prev, epoch 0. The epoch the join creates is the
   fold's, not the envelope's: the guest cannot read the circle's epoch before it is admitted. *)
let envelope ~now ~code body =
  Invite_wire.sign_envelope ~author:(Invite_code.invite_key code) ~seq:1 ~created_at:now ~epoch:0
    ~kind:"join" body

(* ---- reading a join, as the host's watcher and any node do ---- *)

type t = {
  dinner_hash : string;
  invite_key : string;
  identity_key : string;
  device_key : string;
  created_at : Ptime.t;
}

let verify ~(envelope : Yojson.Safe.t) ~(body : Yojson.Safe.t) =
  let open Invite_wire in
  let str v = match v with Some (`String s) -> Some s | _ -> None in
  if not (verify_envelope envelope body) then Error "bad envelope signature"
  else if field "kind" envelope <> Some (`String "join") then Error "not a join"
  else
    match
      ( str (field "author" envelope),
        Option.bind (str (field "created_at" envelope)) parse_iso8601,
        str (field "dinner" body),
        str (field "identity_key" body),
        str (field "identity_signature" body),
        str (field "device_key" body),
        str (field "device_signature" body) )
    with
    | Some invite_key, Some created_at, Some dinner_hash, Some identity_key, Some isig, Some device_key, Some dsig ->
        let id_msg =
          jcs (`Assoc [ ("dinner", `String dinner_hash); ("identity_key", `String identity_key) ])
        in
        let dev_msg =
          jcs
            (`Assoc
              [ ("identity_key", `String identity_key);
                ("device_key", `String device_key);
                ("role", `String "device") ])
        in
        if not (verify ~key:invite_key ~signature:isig id_msg) then Error "identity_signature does not verify"
        else if not (verify ~key:identity_key ~signature:dsig dev_msg) then
          Error "device_signature does not verify"
        else Ok { dinner_hash; invite_key; identity_key; device_key; created_at }
    | _ -> Error "malformed join"
