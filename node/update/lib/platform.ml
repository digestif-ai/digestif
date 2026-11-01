(* The artifact name of the machine this runs on: darwin-arm64, darwin-x86_64, linux-x86_64 or
   linux-arm64. *)

let run argv =
  let ic = Unix.open_process_args_in argv.(0) argv in
  let out = String.trim (In_channel.input_all ic) in
  match Unix.close_process_in ic with Unix.WEXITED 0 -> Some out | _ -> None

let of_uname ~system ~machine =
  let os =
    match String.lowercase_ascii system with
    | "darwin" -> Some "darwin"
    | "linux" -> Some "linux"
    | _ -> None
  in
  let arch =
    match machine with
    | "arm64" | "aarch64" -> Some "arm64"
    | "x86_64" | "amd64" -> Some "x86_64"
    | _ -> None
  in
  match (os, arch) with
  | Some os, Some arch -> Ok (os ^ "-" ^ arch)
  | _ -> Error (Printf.sprintf "no release is built for %s %s" system machine)

let current () =
  match (run [| "uname"; "-s" |], run [| "uname"; "-m" |]) with
  | Some system, Some machine -> of_uname ~system ~machine
  | _ -> Error "uname failed"

(* The platforms a release ships, from ci/platforms.json: { "platforms": [ { "platform": "..." },
   ... ] }. The release workflow builds one archive for each, and `digestif-update manifest`
   refuses a manifest that does not name each exactly once. *)
let shipped_of_string s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error e -> Error ("not JSON: " ^ e)
  | json -> (
      match Release.field "platforms" json with
      | Some (`List entries) ->
          let names =
            List.filter_map
              (fun e ->
                match Release.field "platform" e with
                | Some (`String p) -> Some p
                | _ -> None)
              entries
          in
          if names = [] || List.length names <> List.length entries then
            Error "every entry under platforms needs a platform name"
          else Ok names
      | _ -> Error "holds no platforms list")

(* Ok when [named] (the artifacts' platforms) is exactly [shipped], each once; otherwise every
   platform missing, unknown or named twice. *)
let check_shipped ~shipped named =
  let missing = List.filter (fun p -> not (List.mem p named)) shipped in
  let unknown = List.filter (fun p -> not (List.mem p shipped)) named in
  let twice =
    List.sort_uniq compare
      (List.filter
         (fun p -> List.length (List.filter (String.equal p) named) > 1)
         named)
  in
  let say what = function
    | [] -> []
    | ps -> [ what ^ " " ^ String.concat ", " ps ]
  in
  match
    say "missing" missing
    @ say "not a shipped platform:" unknown
    @ say "named twice:" twice
  with
  | [] -> Ok ()
  | problems -> Error (String.concat "; " problems)
