open Digestif_update
let run_cmd prefix timeout args =
  match Proc.run ~timeout (Array.of_list (prefix @ args)) with
  | Ok { code = 0; stdout; _ } -> Ok stdout
  | Ok { code; stderr; _ } -> Error (Printf.sprintf "%s exited %d: %s" (String.concat " " (List.filteri (fun i _ -> i < 3) args)) code (String.trim stderr))
  | Error e -> Error e
let gh args =
  let read_only =
    match args with
    | "api" :: rest -> not (List.exists (fun a -> List.mem a [ "-X"; "--method"; "-f"; "-F"; "--field"; "--raw-field"; "--input" ]) rest)
    | "attestation" :: ("verify" | "trusted-root") :: _ -> true
    | _ -> false
  in
  if read_only then run_cmd [ "gh" ] 300. args
  else (prerr_endline ("REFUSED gh " ^ String.concat " " args); Error "refused: measure is read-only")
let git = run_cmd [ "git"; "-c"; "credential.helper="; "-c"; "credential.helper=!gh auth git-credential" ] 600.
let () =
  let dir = Sys.argv.(1) in
  let timer = Timing.create ~path:(Filename.concat dir "timings.log") () in
  let config = { Sign_next.key_command = "false"; repo = Sign_next.default_repo; public_key = None } in
  let listed = Timing.time timer "releases-list" (fun () -> gh [ "api"; Sign_next.releases_path config.repo ]) in
  let tmp = Filename.temp_dir "digestif-sign" "" in
  let r =
    Result.bind listed (fun listed ->
        Sign_next.run ~gh ~git ~clone:(Filename.concat dir "clone.git") ~signers:(Trust_root.signers ())
          ~config ~read_key:(fun () -> Error "no key") ~ask:(fun _ -> "l") ~say:print_endline ~tmp
          ~relay:Sign_next.no_relay ~timer
          ~cache:(Attestation.file_cache (Filename.concat dir "attested.json"))
          ~listed ())
  in
  Timing.mark timer "total";
  match r with Ok () -> () | Error e -> prerr_endline ("ERROR " ^ e)
