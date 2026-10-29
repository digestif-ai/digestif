(* The release signer set this binary was built with (node/update/release-signers.json) and its
   version. A node's first trust; after that, only a release both signers signed changes it. *)

let ( let* ) = Result.bind

let signers_of_string bytes =
  let* json = Release.parse_json "signer set" bytes in
  let* () = Release.expect_format "digestif-signers-v0" json in
  let* l = Release.list_field "signers" json in
  Release.all Release.signer_of_json l

let signers () =
  match signers_of_string Trust_root_data.signers_json with
  | Ok s -> s
  | Error e -> failwith ("node/update/release-signers.json: " ^ e)

let version () =
  match Version.of_string (String.trim Trust_root_data.version) with
  | Ok v -> v
  | Error e -> failwith ("node/VERSION: " ^ e)
