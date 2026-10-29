(* The guest's side: read the dinner that names the invite key, then write the join.

   The app is not admitted yet, so it reads the dinner through the bootstrap read
   GET /v0/invites/{invite_key}, signed by the invite key itself, and appends the join, whose own
   signatures are its proof, to every relay the dinner names. *)

open Digestif_core

let bootstrap_path code = "/v0/invites/" ^ Invite_code.invite_public_key code

type error =
  | Unreadable of string
      (** The bootstrap read failed: the relay is unreachable, or answered that
          no open invite has this key. *)
  | Not_this_invite  (** The dinner does not name this code's invite key. *)
  | Expired of Ptime.t
  | Bad_dinner of string

let error_message = function
  | Unreadable m ->
      "The relay in the invite did not hand back its dinner (" ^ m
      ^ "). The invite may be used or expired; ask your host for a new one."
  | Not_this_invite ->
      "This invite code is not on that dinner. Ask your host for a new invite."
  | Expired t ->
      Printf.sprintf "This invite expired at %s. Ask your host for a new one."
        (Dinner.iso8601 t)
  | Bad_dinner m ->
      "The relay answered with a dinner that does not verify: " ^ m

(* The bootstrap read against the relay the code names, signed by the invite key. *)
let read_dinner ~transport code =
  match
    Relay_client.invite transport ~base:code.Invite_code.relay
      ~key:(Invite_code.invite_key code)
  with
  | Error (Relay_client.Refused (404, _)) ->
      Error (Unreadable "no open invite with this code")
  | Error e -> Error (Unreadable (Relay_client.error_to_string e))
  | Ok (s : Relay_client.stored) ->
      if Envelope.hash s.signed.envelope <> s.hash then
        Error (Bad_dinner "the relay's hash does not match the envelope")
      else Ok s.signed

(* Checks what the relay handed back before anything is signed against it: the dinner envelope
   verifies, and it names this invite key, unexpired. Returns the dinner's hash, its parsed body and
   this guest's entry. *)
let check_dinner ~now ~code (sg : Envelope.signed) =
  match (Envelope.verify sg, sg.body) with
  | Error e, _ -> Error (Bad_dinner (Envelope.error_message e))
  | Ok (), None -> Error (Bad_dinner "the relay withheld the dinner's body")
  | Ok (), _ when sg.envelope.kind <> "dinner" ->
      Error (Bad_dinner "not a dinner")
  | Ok (), Some body -> (
      match Dinner.parse body with
      | Error m -> Error (Bad_dinner m)
      | Ok parsed -> (
          match
            Dinner.find_guest parsed (Invite_code.invite_public_key code)
          with
          | None -> Error Not_this_invite
          | Some g when Ptime.is_later now ~than:g.listed_expires_at ->
              Error (Expired g.listed_expires_at)
          | Some g -> Ok (Envelope.hash sg.envelope, parsed, g)))

(* The join body: the identity key signed by the invite key, the first device key signed by the
   identity key. [identity] is derived from the recovery phrase just long enough to call this. *)
let body ~dinner_hash ~code ~identity ~device : Yojson.Safe.t =
  Bodies.make_join
    ~invite_key:(Invite_code.invite_key code)
    ~dinner_hash ~identity ~device

(* The invite key's only envelope: seq 1, no prev, epoch 0. The epoch the join creates is the
   fold's, not the envelope's: the guest cannot read the circle's epoch before it is admitted. *)
let envelope ~now ~code body =
  Envelope.create
    ~key:(Invite_code.invite_key code)
    ~seq:1 ~created_at:(Dinner.iso8601 now) ~epoch:0 ~kind:"join" body

type written = {
  dinner_hash : string;
  dinner : Dinner.parsed;
  join : Envelope.signed;
  appended : (string * (Relay_client.receipt, Relay_client.error) result) list;
      (** Each relay the dinner lists, and what it answered the join's append.
      *)
}

(* The whole guest act: the bootstrap read, the checks, the join, and a bootstrap append (no
   Digestif-Key; the join's signatures are the proof) to every relay the dinner lists. *)
let write ~transport ~now ~code ~identity ~device =
  match read_dinner ~transport code with
  | Error e -> Error e
  | Ok sg -> (
      match check_dinner ~now ~code sg with
      | Error e -> Error e
      | Ok (dinner_hash, dinner, _) ->
          let join =
            envelope ~now ~code (body ~dinner_hash ~code ~identity ~device)
          in
          let appended =
            List.map
              (fun relay ->
                (relay, Relay_client.append transport ~base:relay ~key:None join))
              dinner.parsed_relays
          in
          Ok { dinner_hash; dinner; join; appended })

(* ---- reading a join, as the host's watcher and any node do ---- *)

type t = {
  dinner_hash : string;
  invite_key : string;
  identity_key : string;
  device_key : string;
  created_at : Ptime.t;
}

let verify (sg : Envelope.signed) =
  match (Envelope.verify sg, sg.body) with
  | Error e, _ -> Error (Envelope.error_message e)
  | Ok (), None -> Error "the join's body is withheld"
  | Ok (), _ when sg.envelope.kind <> "join" -> Error "not a join"
  | Ok (), Some body -> (
      match
        (Bodies.parse_join body, Dinner.parse_time sg.envelope.created_at)
      with
      | Error m, _ -> Error ("malformed join: " ^ m)
      | _, None -> Error "malformed join: created_at"
      | Ok j, Some created_at ->
          if
            not
              (Keys.verify_json ~pub:sg.envelope.author
                 ~signature:j.identity_signature
                 (Bodies.identity_claim ~dinner_hash:j.dinner_hash
                    ~identity_key:j.identity_key))
          then Error "identity_signature does not verify"
          else if
            not (Bodies.join_signatures_valid ~invite_key:sg.envelope.author j)
          then Error "device_signature does not verify"
          else
            Ok
              {
                dinner_hash = j.dinner_hash;
                invite_key = sg.envelope.author;
                identity_key = j.identity_key;
                device_key = j.device_key;
                created_at;
              })
