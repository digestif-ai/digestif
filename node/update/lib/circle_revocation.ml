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
        let* by = Crypto.public_key_of_string by in
        let* signature = string_field "signature" s in
        Ok { by; signature })
      signatures
  in
  Ok { bytes; doc; signatures }

type outcome =
  | Revoked of Crypto.public_key
      (** Newly recorded; updates halt until a signer-set change. *)
  | Already_revoked of Crypto.public_key
  | Not_signed_by_a_current_signer of Crypto.public_key
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
