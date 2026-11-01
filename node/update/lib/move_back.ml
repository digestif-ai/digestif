(* Moving a node back from a recalled version to the newest older release on its own disk
   (docs/releases.md, A recall): find it, self-test it against a copy of the store, point current
   and good at it and save it as installed. Nothing is fetched, so no signature is involved. *)

(* The release the node moved back to, or why it stays on [from]. *)
let run ~(from : Version.t) : (Version.t, string) result =
  ignore from;
  Error "moving back is not built yet (ISS-37088)"
