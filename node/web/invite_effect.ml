(* What an invite does once every admin signed its admission (docs/protocol.md, approval): the
   starting admin's node writes the dinner listing the guest with the signed admission beside the
   entry, counts the guest's 72 hours from then, and records the email the admins signed, with the
   install command and the expiry filled in when it is shown (Digestif_invite.Approved_invite). Run
   on the starting admin's node alone; another node that records the last signature leaves it to
   that one, and a second call for the same approval writes nothing, so the caller may call it
   every time it sees the approval signed. *)

open Digestif_core

let on_signed (node : Node.t) (signed : Approval.signed) : (unit, string) result
    =
  Result.map ignore (Digestif_invite.Approved_invite.take_effect node signed)
