(* An approval every admin signs with their release key (docs/protocol.md, approval): an invite,
   whose document is a digestif-admission-v0, or a signer-set change, whose document is a
   digestif-signers-v0. Each signature is Ed25519 over the kind's domain line and the document's
   exact bytes, the way a release manifest or a revocation is signed (docs/releases.md, The
   channel), so one release signature is never replayed as another kind's. *)

let admission_format = "digestif-admission-v0"
let admission_domain = "DIGESTIF-ADMISSION-V0\n"
let signers_format = "digestif-signers-v0"
let signers_domain = "DIGESTIF-SIGNERS-V0\n"

(* How long an approval waits for its last signature, judged from its created_at. *)
let lifetime_seconds = 7. *. 24. *. 3600.

type kind = Invite | Promotion | Removal | Replacement

let kind_to_string = function
  | Invite -> "invite"
  | Promotion -> "promotion"
  | Removal -> "removal"
  | Replacement -> "replacement"

let kind_of_string = function
  | "invite" -> Some Invite
  | "promotion" -> Some Promotion
  | "removal" -> Some Removal
  | "replacement" -> Some Replacement
  | _ -> None

(* The domain line a kind's document is signed over. *)
let domain = function
  | Invite -> admission_domain
  | Promotion | Removal | Replacement -> signers_domain

type signature = { key : string; signature : string }

(* An approval whose last signature is in: its envelope hash, its kind, the document's exact bytes
   and every signature over them. What the kind's effect takes (Invite_effect, Signer_set_effect). *)
type signed = {
  id : string;
  kind : kind;
  document : string;
  signatures : signature list;
}
