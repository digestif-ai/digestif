(* What a signer-set change does once every current and every new key signed it (docs/protocol.md,
   signer_set), run once on the node that recorded the last signature (Api.Approvals.take_effect):
   it adopts the set itself at once, checked against the one it holds, then posts the signer_set
   message to the circle, so a change that does not verify here never reaches a relay. Every other
   node adopts it as it folds the message (Circle_signer_set.from_circle), and the next sign --next
   any admin runs publishes it to the channel (Signers_channel). In a circle whose root names its own
   admins the change is theirs alone (Circle_admins): it is checked against their set, and neither
   the update state nor the channel learns of it. *)

open Digestif_core
module U = Digestif_update

let ( let* ) = Result.bind

let on_signed (node : Node.t) (a : Approval.signed) : (unit, string) result =
  match a.kind with
  | Approval.Invite -> Error "an invite's admission is not a signer-set change"
  | Approval.Promotion | Approval.Removal | Approval.Replacement ->
      let* change =
        U.Circle_signer_set.of_approval ~document:a.document
          ~signatures:
            (List.map
               (fun (s : Approval.signature) -> (s.key, s.signature))
               a.signatures)
      in
      let* () =
        match U.Circle_admins.of_fold node (Node.fold node) with
        | Some trust ->
            (* A circle with its own admins: the change is theirs, checked against their set, and
               the release signer set in the update state is not touched. *)
            Result.map_error U.Policy.refusal_to_string
              (Result.map ignore (U.Policy.check_set_change trust change))
        | None ->
            U.Circle_signer_set.adopt
              ~state_path:(U.Schedule.state_path node.dir)
              change
      in
      let* _ =
        Node.write node ~kind:U.Circle_signer_set.kind
          (U.Circle_signer_set.to_body change)
      in
      Ok ()
