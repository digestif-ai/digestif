(* The release signer set this binary was built with (node/update/release-signers.json) and its
   version, the release tag it was built from (node/update/lib/dune). A node's first trust; after
   that, only a release both signers signed changes it. *)

let ( let* ) = Result.bind

let signers_of_string bytes =
  let* set = Release.signer_set_of_string bytes in
  Ok set.set_signers

let signers () =
  match signers_of_string Trust_root_data.signers_json with
  | Ok s -> s
  | Error e -> failwith ("node/update/release-signers.json: " ^ e)

let version () =
  match Version.of_string (String.trim Trust_root_data.version) with
  | Ok v -> v
  | Error e -> failwith ("DIGESTIF_VERSION this binary was built with: " ^ e)
