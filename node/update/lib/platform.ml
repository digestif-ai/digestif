(* The artifact name of the machine this runs on: darwin-arm64, darwin-x86_64, linux-x86_64 or
   linux-arm64. *)

let run argv =
  let ic = Unix.open_process_args_in argv.(0) argv in
  let out = String.trim (In_channel.input_all ic) in
  match Unix.close_process_in ic with Unix.WEXITED 0 -> Some out | _ -> None

let of_uname ~system ~machine =
  let os = match String.lowercase_ascii system with "darwin" -> Some "darwin" | "linux" -> Some "linux" | _ -> None in
  let arch =
    match machine with
    | "arm64" | "aarch64" -> Some "arm64"
    | "x86_64" | "amd64" -> Some "x86_64"
    | _ -> None
  in
  match os, arch with
  | Some os, Some arch -> Ok (os ^ "-" ^ arch)
  | _ -> Error (Printf.sprintf "no release is built for %s %s" system machine)

let current () =
  match run [| "uname"; "-s" |], run [| "uname"; "-m" |] with
  | Some system, Some machine -> of_uname ~system ~machine
  | _ -> Error "uname failed"
