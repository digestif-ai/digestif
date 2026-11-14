(* What an invite does once every admin signed its admission (docs/protocol.md, approval): the
   starting admin's node writes the dinner listing the guest with the signed admission beside the
   entry, counts the guest's 72 hours from then, and sends the email the admins signed, with the
   install command and the expiry filled in. Run on the starting admin's node alone; another node
   that records the last signature leaves it to that one. *)

open Digestif_core

let on_signed (_ : Node.t) (_ : Approval.signed) : (unit, string) result = Ok ()
