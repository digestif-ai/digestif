(* The admins who judge a circle's approvals and admissions (docs/protocol.md, circle; Approvals).

   A circle root that names [admins] has a signer set of its own: it starts from those keys, the
   founder's admin key when the circle was founded on its own, and changes only by the circle's
   signer_set messages, each checked against the set before it as a release signer-set change is
   (Policy.adopt_sets), with the circle's release_revocation messages applied after every link. The
   release signer set, in the update state, keeps judging releases, and never this circle's
   invites: its members need not learn who is in the circle.

   A root that names none, a founding dinner included, is judged by the release signer set the
   update state holds, which every adopted signer-set change advances (Circle_signer_set). *)

open Release

let ( let* ) = Result.bind

(* The signer_set messages the fold applied, parsed; one that does not parse is left out here and
   shown as a fault by Circle_signer_set.on_circle. *)
let changes (fold : Fold.t) =
  List.filter_map
    (fun (e : Fold.entry) ->
      match Circle_signer_set.of_body (Option.value e.body ~default:`Null) with
      | Ok s -> Some s
      | Error _ -> None)
    (Fold.signer_sets fold)

(* The circle's own signer set as [fold] holds it, or None when its root names no admins. *)
let of_fold (node : Node.t) (fold : Fold.t) : Policy.trust option =
  match Fold.root_admins fold with
  | None -> None
  | Some admins ->
      let seed : Policy.trust =
        {
          signers =
            List.map
              (fun (a : Approval.signer) -> { name = a.name; key = a.key })
              admins;
          revoked = [];
        }
      in
      Some
        (Policy.adopt_sets seed ~revocations:(Circle_revocation.on_circle fold node) (changes fold))
          .adopted_trust

(* Whether [fold]'s circle judges its admissions by its own admins. *)
let own (fold : Fold.t) = Fold.root_admins fold <> None

(* The signer set that judges [node]'s circle's approvals and admissions: the circle's own, or the
   release signer set in the update state at [state_path]. *)
let trust ~state_path (node : Node.t) : (Policy.trust, string) result =
  match of_fold node (Node.fold node) with
  | Some t -> Ok t
  | None ->
      let* st = State.load state_path in
      Ok st.trust
