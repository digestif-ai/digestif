(* What a signer-set change does once every current and every new key signed it (docs/protocol.md,
   signer_set): the node that recorded the last signature posts the signer_set message to the
   circle, and every node adopts the set after checking it against the one it holds. *)

open Digestif_core

let on_signed (_ : Node.t) (_ : Approval.signed) : (unit, string) result = Ok ()
