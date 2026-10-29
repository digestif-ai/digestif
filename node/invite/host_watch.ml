(* The host's node watching the joins on its dinners.

   Whoever reads an invite email first can post its join, so every join on one of the host's
   invites reaches the host's person. A join the host expected (the person recorded hearing that
   the guest installed) is shown in the feed and the digest; any other is an ask: confirm, or
   revoke the identity. *)

type expectation =
  | Sent
      (** The invite went out; the host has not heard that the guest installed.
      *)
  | Expected
      (** The host's person recorded hearing from the guest that they installed.
      *)

type state =
  | Open of expectation
  | Joined of { identity_key : string; confirmed : bool }
  | Revoked of { identity_key : string }

type record = {
  dinner_hash : string;
  guest_name : string;
  guest_email : string;
  invite_key : string;
  expires_at : Ptime.t;
  state : state;
}

type ledger = record list

let records_of_dinner ~dinner_hash (d : Dinner.t) =
  List.map
    (fun (i : Dinner.invite) ->
      {
        dinner_hash;
        guest_name = i.guest.name;
        guest_email = i.guest.email;
        invite_key = i.invite_key;
        expires_at = i.expires_at;
        state = Open Sent;
      })
    d.invites

let update ledger key f =
  List.map (fun r -> if r.invite_key = key then f r else r) ledger

let mark_expected ledger ~invite_key =
  update ledger invite_key (fun r ->
      match r.state with Open _ -> { r with state = Open Expected } | _ -> r)

type option_ = Confirm | Revoke

type ask = {
  key : string;  (** join:<invite key>, one ask per invite. *)
  title : string;
  context : string;
  options : option_ list;
  recommended : option_;
  default : option_;  (** What happens when the ask lapses unanswered. *)
  lapses_at : Ptime.t;
}

type outcome =
  | Not_ours  (** The join is on an invite this host did not write. *)
  | Shown of record
      (** An expected join: shown in the feed and the digest, nothing asked. *)
  | Asked of record * ask
  | Already_handled of record  (** The same join seen again on another relay. *)

(* An unanswered ask revokes. A revoked guest who really was the guest gets a new invite in a
   minute; a stranger left in the circle reads everything from the join forward, and what was
   read cannot be taken back. *)
let ask_lapse = Ptime.Span.of_int_s (72 * 3600)

let ask_for ~now r ~identity_key ~why =
  {
    key = "join:" ^ r.invite_key;
    title =
      Printf.sprintf "Confirm %s joined, or revoke the identity" r.guest_name;
    context =
      Printf.sprintf "%s %s Identity %s." why
        "If you do not answer, the identity is revoked and the guest can be \
         invited again."
        identity_key;
    options = [ Confirm; Revoke ];
    recommended = Revoke;
    default = Revoke;
    lapses_at = Dinner.expiry ~now ask_lapse;
  }

let observe ~now ledger (join : Join.t) =
  match List.find_opt (fun r -> r.invite_key = join.invite_key) ledger with
  | None -> (ledger, Not_ours)
  | Some r -> (
      let joined confirmed =
        {
          r with
          state = Joined { identity_key = join.identity_key; confirmed };
        }
      in
      match r.state with
      | Open Expected ->
          let r' = joined true in
          (update ledger r.invite_key (fun _ -> r'), Shown r')
      | Open Sent ->
          let r' = joined false in
          let why =
            Printf.sprintf
              "Someone joined with %s's invite before you heard they installed."
              r.guest_name
          in
          ( update ledger r.invite_key (fun _ -> r'),
            Asked (r', ask_for ~now r' ~identity_key:join.identity_key ~why) )
      | (Joined { identity_key; _ } | Revoked { identity_key })
        when identity_key = join.identity_key ->
          (ledger, Already_handled r)
      | Joined _ | Revoked _ ->
          (* A second identity on one invite: two relays each accepted a different join. The fold
             keeps one per relay; the host decides which person this is. *)
          let why =
            Printf.sprintf
              "A second identity joined with %s's invite, through another \
               relay."
              r.guest_name
          in
          ( ledger,
            Asked (r, ask_for ~now r ~identity_key:join.identity_key ~why) ))

(* The person's answer. Confirm records it; Revoke returns the revoke body the identity key
   (derived from the host's phrase just long enough to sign) authorizes. *)
let answer ledger ~invite_key ~(identity_key : string) choice ~host_identity =
  match choice with
  | Confirm ->
      ( update ledger invite_key (fun r ->
            { r with state = Joined { identity_key; confirmed = true } }),
        None )
  | Revoke ->
      let by = Invite_wire.public_key host_identity in
      let signature =
        Invite_wire.sign host_identity
          (Invite_wire.jcs
             (`Assoc [ ("target", `String identity_key); ("by", `String by) ]))
      in
      ( update ledger invite_key (fun r ->
            { r with state = Revoked { identity_key } }),
        Some
          (`Assoc
             [
               ("target", `String identity_key);
               ("by", `String by);
               ("signature", `String signature);
             ]
            : Yojson.Safe.t) )

(* ---- persistence: the node keeps the ledger beside its log ---- *)

let state_to_json = function
  | Open Sent -> `Assoc [ ("state", `String "sent") ]
  | Open Expected -> `Assoc [ ("state", `String "expected") ]
  | Joined { identity_key; confirmed } ->
      `Assoc
        [
          ("state", `String "joined");
          ("identity_key", `String identity_key);
          ("confirmed", `Bool confirmed);
        ]
  | Revoked { identity_key } ->
      `Assoc
        [ ("state", `String "revoked"); ("identity_key", `String identity_key) ]

let record_to_json r : Yojson.Safe.t =
  let state = match state_to_json r.state with `Assoc fs -> fs | _ -> [] in
  `Assoc
    ([
       ("dinner", `String r.dinner_hash);
       ("guest_name", `String r.guest_name);
       ("guest_email", `String r.guest_email);
       ("invite_key", `String r.invite_key);
       ("expires_at", `String (Invite_wire.iso8601 r.expires_at));
     ]
    @ state)

let to_json ledger : Yojson.Safe.t = `List (List.map record_to_json ledger)

let record_of_json j =
  let open Invite_wire in
  let str k = match field k j with Some (`String s) -> Some s | _ -> None in
  let ( let* ) = Option.bind in
  let* dinner_hash = str "dinner" in
  let* guest_name = str "guest_name" in
  let* guest_email = str "guest_email" in
  let* invite_key = str "invite_key" in
  let* expires_at = Option.bind (str "expires_at") parse_iso8601 in
  let* state =
    match (str "state", str "identity_key", field "confirmed" j) with
    | Some "sent", _, _ -> Some (Open Sent)
    | Some "expected", _, _ -> Some (Open Expected)
    | Some "joined", Some identity_key, Some (`Bool confirmed) ->
        Some (Joined { identity_key; confirmed })
    | Some "revoked", Some identity_key, _ -> Some (Revoked { identity_key })
    | _ -> None
  in
  Some { dinner_hash; guest_name; guest_email; invite_key; expires_at; state }

let of_json = function
  | `List items ->
      let records = List.filter_map record_of_json items in
      if List.length records = List.length items then Ok records
      else Error "a ledger record does not parse"
  | _ -> Error "the ledger is a list"
