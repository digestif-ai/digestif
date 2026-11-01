(* A release-key revocation carried on the circle as a release_revocation message (docs/protocol.md).
   The body is the channel's revocation document, byte for byte in base64url, and the signatures
   from its .sig.json, so it verifies exactly as the channel's copy does. *)

open Release

let kind = "release_revocation"
let ( let* ) = Result.bind

let to_body (r : revocation signed) : Yojson.Safe.t =
  `Assoc
    [
      ("document", `String (B64url.encode r.bytes));
      ( "signatures",
        `List
          (List.map
             (fun s ->
               `Assoc
                 [ ("key", `String s.by); ("signature", `String s.signature) ])
             r.signatures) );
    ]

(* The revocation a body carries, its document parsed and its signatures read but not yet checked
   against any signer set. *)
let of_body (json : Yojson.Safe.t) : (revocation signed, string) result =
  let* encoded = string_field "document" json in
  let* bytes =
    Result.map_error
      (fun e -> "field \"document\" is not base64url: " ^ e)
      (B64url.decode encoded)
  in
  let* doc = revocation_of_string bytes in
  let* signatures = list_field "signatures" json in
  let* signatures =
    all
      (fun s ->
        let* by = string_field "key" s in
        let* by = Keys.parse_ed25519 by in
        let* signature = string_field "signature" s in
        Ok { by; signature })
      signatures
  in
  Ok { bytes; doc; signatures }

type outcome =
  | Revoked of Keys.public_key
      (** Newly recorded; updates halt until a signer-set change. *)
  | Already_revoked of Keys.public_key
  | Not_signed_by_a_current_signer of Keys.public_key
      (** Changes nothing: no key in the node's own signer set signed it. A
          fault to show. *)

let outcome_to_string = function
  | Revoked k ->
      "release key " ^ k
      ^ " is revoked; updates halt until the signer set is replaced"
  | Already_revoked k -> "release key " ^ k ^ " was already revoked"
  | Not_signed_by_a_current_signer k ->
      "a revocation of release key " ^ k
      ^ " on the circle is not signed by any current release signer, so it was \
         ignored"

(* What [r] does to [state]: the same rule the channel's revocations meet, Policy.apply_revocations
   against the node's own signer set. *)
let receive (state : State.t) (r : revocation signed) : State.t * outcome =
  let key = r.doc.revoked_key in
  if Policy.is_revoked state.trust key then (state, Already_revoked key)
  else
    let trust = Policy.apply_revocations state.trust [ r ] in
    if Policy.is_revoked trust key then ({ state with trust }, Revoked key)
    else (state, Not_signed_by_a_current_signer key)

(* The node's handler for a release_revocation body read from a relay: verify it and persist the
   revoked key in the update state at [state_path]. *)
let receive_body ~state_path (json : Yojson.Safe.t) : (outcome, string) result =
  let* r = of_body json in
  let* state = State.load state_path in
  let state', outcome = receive state r in
  (match outcome with Revoked _ -> State.save state_path state' | _ -> ());
  Ok outcome

(* The node's half of the circle route, run after every sync: each release_revocation the fold
   applied (an admitted, unrevoked device key wrote it, with both fields) is verified against the
   update state at [state_path] and the newly revoked keys persisted, in the order the log holds
   them. One no current signer signed, or whose document does not parse, changes nothing and is
   recorded as a fault the member is shown. Returns the keys this call newly revoked. *)
let from_circle ~state_path (node : Node.t) (fold : Fold.t) :
    (Keys.public_key list, string) result =
  let applied = Hashtbl.create 64 in
  List.iter (fun h -> Hashtbl.replace applied h ()) fold.applied;
  match
    List.filter
      (fun (row : Log.row) -> Hashtbl.mem applied row.hash)
      (Log.of_kind node.log kind)
  with
  | [] -> Ok []
  | rows ->
      let* state = State.load state_path in
      let fault (row : Log.row) detail =
        Log.add_fault node.log ~kind ~author:row.signed.envelope.author
          ~seq:row.signed.envelope.seq
          ~detail:(row.hash ^ " " ^ detail)
      in
      let state', revoked =
        List.fold_left
          (fun (state, revoked) (row : Log.row) ->
            match of_body (Option.value row.signed.body ~default:`Null) with
            | Error e ->
                fault row e;
                (state, revoked)
            | Ok r -> (
                match receive state r with
                | state, Revoked k -> (state, k :: revoked)
                | state, Already_revoked _ -> (state, revoked)
                | state, (Not_signed_by_a_current_signer _ as o) ->
                    fault row (outcome_to_string o);
                    (state, revoked)))
          (state, []) rows
      in
      if revoked <> [] then State.save state_path state';
      Ok (List.rev revoked)
