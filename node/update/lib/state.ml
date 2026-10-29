(* What a node has installed and whom it trusts to sign the next release, kept in one JSON file.
   Written atomically, so a crash leaves the old state or the new one. *)

open Release

type t = {
  installed : Version.t;
  trust : Policy.trust;
  pin : Version.t option;
}

let ( let* ) = Result.bind

let initial () =
  { installed = Trust_root.version (); trust = { signers = Trust_root.signers (); revoked = [] }; pin = None }

let to_string t =
  Yojson.Safe.pretty_to_string
    (`Assoc
      [ ("format", `String "digestif-update-state-v0");
        ("installed", `String (Version.to_string t.installed));
        ("pin", match t.pin with None -> `Null | Some v -> `String (Version.to_string v));
        ("signers", `List (List.map signer_to_json t.trust.signers));
        ("revoked", `List (List.map (fun k -> `String k) t.trust.revoked)) ])
  ^ "\n"

let of_string bytes =
  let* json = parse_json "update state" bytes in
  let* () = expect_format "digestif-update-state-v0" json in
  let* installed = string_field "installed" json in
  let* installed = Version.of_string installed in
  let* pin =
    match field "pin" json with
    | None | Some `Null -> Ok None
    | Some (`String s) ->
      let* v = Version.of_string s in
      Ok (Some v)
    | Some _ -> Error "field \"pin\" must be a string"
  in
  let* signers = list_field "signers" json in
  let* signers = all signer_of_json signers in
  let* revoked = list_field "revoked" json in
  let* revoked =
    all (function `String k -> Crypto.public_key_of_string k | _ -> Error "revoked keys are strings") revoked
  in
  Ok { installed; trust = { signers; revoked }; pin }

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_atomic path contents =
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 tmp (fun oc ->
      Out_channel.output_string oc contents);
  Unix.rename tmp path

(* The state at [path], or the build's own state when the file does not exist yet. A file that
   exists and does not parse is an error, never silently replaced by the build's trust root. *)
let load path =
  if Sys.file_exists path then
    match of_string (read_file path) with
    | Ok t -> Ok t
    | Error e -> Error (path ^ ": " ^ e)
  else Ok (initial ())

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o700
  end

let save path t =
  mkdir_p (Filename.dirname path);
  write_atomic path (to_string t)
