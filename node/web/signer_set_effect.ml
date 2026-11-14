(* What a signer-set change does once every current and every new key signed it (docs/protocol.md,
   signer_set). The node that recorded the last signature has posted the signer_set message to the
   circle (the approvals' fold, which then calls this once); here it adopts the set itself at once,
   checked against the one it holds, rather than waiting for its own message to come back from a
   relay. Every other node adopts it as it folds the message (Circle_signer_set.from_circle), and
   the next sign --next any admin runs publishes it to the channel (Signers_channel). *)

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
      U.Circle_signer_set.adopt
        ~state_path:(U.Schedule.state_path node.dir)
        change
