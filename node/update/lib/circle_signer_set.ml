(* A signer-set change carried on the circle as a signer_set message (docs/protocol.md, signer_set;
   docs/releases.md, Changing the signer set). The body is the digestif-signers-v0 document, byte
   for byte in base64url, and the release signatures over it, as for release_revocation.

   Core's fold checks only an admitted author and the body's two fields and keeps the chain in fold
   order (Fold.signer_sets); what a change means is decided here, against the set the node holds in
   its update state, link by link (State.adopt_sets). The set is one per channel, so a change
   adopted from the channel that the circle lacks is posted to it ([post_missing]), and every relay
   of the circle folds the same chain. *)

open Release

let kind = "signer_set"
let ( let* ) = Result.bind
let to_body (s : signer_set signed) : Yojson.Safe.t = body_of_signed s

(* The change a body carries, its document parsed and its signatures read but not yet checked. *)
let of_body (json : Yojson.Safe.t) : (signer_set signed, string) result =
  signed_of_body signer_set_of_string json

(* The change an approval's last signature completed (Approval.signed): its document's bytes and
   every signature over them, as the signer_set message carries them. *)
let of_approval ~document ~(signatures : (string * string) list) =
  let* doc = signer_set_of_string document in
  let* signatures =
    all
      (fun (key, signature) ->
        let* by = Keys.parse_ed25519 key in
        Ok { by; signature })
      signatures
  in
  Ok { bytes = document; doc; signatures }

let fault (node : Node.t) (e : Fold.entry) detail =
  Log.add_fault node.log ~kind ~author:e.envelope.author ~seq:e.envelope.seq
    ~detail:(e.hash ^ " " ^ detail)

(* Every signer_set the fold applied, parsed, in fold order. One whose document does not parse is
   recorded as a fault the member is shown and left out. *)
let on_circle (node : Node.t) (fold : Fold.t) : signer_set signed list =
  List.filter_map
    (fun (e : Fold.entry) ->
      match of_body (Option.value e.body ~default:`Null) with
      | Ok s -> Some s
      | Error why ->
          fault node e why;
          None)
    (Fold.signer_sets fold)

(* The node's half of the circle route, run after every sync, beside Circle_revocation.from_circle:
   adopt every change the circle carries that verifies against the set the update state at
   [state_path] holds, with the circle's revocations applied after every link, and persist the
   set. A change no link of the chain reaches is a fault only when it is not an old link this node
   already followed past. Returns the changes this call newly adopted. *)
let from_circle ~state_path (node : Node.t) (fold : Fold.t) :
    (signer_set signed list, string) result =
  match on_circle node fold with
  | [] -> Ok []
  (* A circle whose root names its own admins changes their set, never the release signer set:
     its signer_set messages are read by Circle_admins. *)
  | _ when Fold.root_admins fold <> None -> Ok []
  | changes ->
      let* state = State.load state_path in
      let revocations = Circle_revocation.on_circle fold node in
      let state', a = State.adopt_sets state ~revocations changes in
      List.iter
        (fun ((c : signer_set signed), r) ->
          match
            List.find_opt
              (fun (e : Fold.entry) ->
                match of_body (Option.value e.body ~default:`Null) with
                | Ok s -> s.bytes = c.bytes
                | Error _ -> false)
              (Fold.signer_sets fold)
          with
          | Some e ->
              fault node e
                ("the signer set it names is not adopted: "
               ^ Policy.refusal_to_string r)
          | None -> ())
        a.refused;
      if a.adopted <> [] then State.save state_path state';
      Ok a.adopted

(* Adopt [change] now, as the node that recorded an approval's last signature does before its
   signer_set reaches a relay. *)
let adopt ~state_path (change : signer_set signed) =
  let* state = State.load state_path in
  let state', a = State.adopt_sets state ~revocations:[] [ change ] in
  match (a.adopted, a.refused) with
  | _ :: _, _ ->
      State.save state_path state';
      Ok ()
  | [], (_, r) :: _ -> Error (Policy.refusal_to_string r)
  | [], [] -> Ok ()

(* The changes the update state at [state_path] holds that the circle does not carry yet. *)
let missing ~state_path (node : Node.t) (fold : Fold.t) =
  if Fold.root_admins fold <> None then Ok []
  else
  let* state = State.load state_path in
  let carried =
    List.map (fun (s : signer_set signed) -> s.bytes) (on_circle node fold)
  in
  Ok
    (List.filter
       (fun (s : signer_set signed) -> not (List.mem s.bytes carried))
       state.signer_sets)

(* Post every change the node holds and the circle lacks, oldest first, so a circle on the same
   channel whose admins changed the set elsewhere folds the same chain (docs/protocol.md,
   signer_set). Any admitted member's node may post one: a relay adopts it only when it verifies
   against the set the relay holds. A circle whose root names its own admins carries none: the
   release signer set is not its admins. Returns the hashes written. *)
let post_missing ~state_path (node : Node.t) (fold : Fold.t) =
  let* sets = missing ~state_path node fold in
  all
    (fun s ->
      let* hash, _ = Node.write node ~kind (to_body s) in
      Ok hash)
    sets
