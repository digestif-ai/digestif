(* THE SIGNING JOB'S KEYCHAIN (docs/releases.md, The signing job): the release key and the signer
   token, each a generic password in the login Keychain that the signing job's pinned
   digestif-update created itself ({!store}), so its access list trusts that binary alone and it
   reads them without a prompt ({!read}); every other reader, `security` included, is asked. The
   calls are keychain_stubs.c's; on a system other than macOS each one is an error saying so. *)

external read_raw : string -> int * string = "digestif_keychain_read"

external store_raw : string -> string -> string -> string -> int * string
  = "digestif_keychain_store"

(* The item that holds the release key, and the one that holds the signer token. *)
let release_key_service = "digestif-release-key"
let signer_token_service = "digestif-signer-token"

(* errSecItemNotFound. *)
let not_found = -25300

type read_error = Missing | Failed of string

let read service =
  match read_raw service with
  | 0, data -> Ok data
  | status, _ when status = not_found -> Error Missing
  | _, message -> Error (Failed message)

let read_error_to_string service = function
  | Missing -> Printf.sprintf "the Keychain holds no %s item" service
  | Failed m -> Printf.sprintf "the Keychain's %s item: %s" service m

(* Replace every [service] item with one holding [data], trusting the binary that calls it. *)
let store ~service ~account ~label data =
  match store_raw service account label data with
  | 0, _ -> Ok ()
  | _, message ->
      Error (Printf.sprintf "the Keychain's %s item: %s" service message)
