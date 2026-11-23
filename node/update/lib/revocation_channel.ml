(* A signer's revocation of a release key (docs/releases.md, Revoking a release key): put it into
   checkouts of the channel. `digestif-update revoke` commits what this writes to release/ on main
   and to the `channel` branch with the signer's own `gh` login, as a recall is committed, and says
   how to post the same document on the circle (Circle_revocation).

   revocations/<key>.json, named for the revoked key without its ed25519: prefix, is written once
   and never edited: a second signer revoking the same key signs those bytes, and their signature
   joins the first in revocations/<key>.sig.json (Takeback). *)

open Release

let ( let* ) = Result.bind

let name (key : Keys.public_key) =
  let prefix = "ed25519:" in
  if String.starts_with ~prefix key then
    String.sub key (String.length prefix)
      (String.length key - String.length prefix)
  else key

let document_path key = "revocations/" ^ name key ^ ".json"
let signatures_path key = "revocations/" ^ name key ^ ".sig.json"

let entry key =
  `Assoc
    [
      ("document", `String (document_path key));
      ("signatures", `String (signatures_path key));
    ]

type written = {
  revocation : revocation signed;
  first : bool;  (** This call wrote the document; otherwise it signed one. *)
}

(* Revoke [key] in every checkout of [dirs], signed with [secret]. *)
let write_revocations ~dirs ~secret ~key ~reason ~revoked_at =
  let* key = Keys.parse_ed25519 key in
  let* w =
    Takeback.write ~dirs ~document:(document_path key)
      ~signatures:(signatures_path key) ~list:"revocations" ~entry:(entry key)
      ~fresh:(fun () ->
        revocation_to_string { revoked_key = key; reason; revoked_at })
      ~parse:revocation_of_string
      ~check:(fun doc ->
        if doc.revoked_key = key then Ok ()
        else Error (document_path key ^ " revokes another key"))
      ~domain:revocation_domain ~secret
  in
  Ok { revocation = w.signed; first = w.first }
