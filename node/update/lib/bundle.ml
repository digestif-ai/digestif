(* A release archive: a gzipped tar of bin/digestif, the parts of behaviors/ the node runs, and
   runtime/, the platform's Node.js the behaviors run with (docs/releases.md, Cutting a release).
   The signer's `digestif-update bundle` writes one, and a local install (Stage.local) lays a
   release directory out from the same parts, without a runtime. *)

let behavior_parts = [ "bin"; "src"; "prompts"; "launchd"; "package.json" ]
let ( let* ) = Result.bind

let check_ok what argv =
  match Proc.run ~timeout:300. argv with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "%s exited %d: %s" what code (String.trim stderr))
  | Error e -> Error e

(* Write [out] from the node binary [binary], the checkout's [behaviors] directory and [runtime], a
   directory holding bin/node (and Node.js's LICENSE) that becomes the archive's runtime/. *)
let write ?runtime ~binary ~behaviors ~out () =
  if not (Sys.file_exists (Filename.concat behaviors "bin/nightly-hook")) then
    Error
      (behaviors ^ " holds no bin/nightly-hook; pass the checkout's behaviors/")
  else if
    match runtime with
    | Some r -> not (Sys.file_exists (Filename.concat r "bin/node"))
    | None -> false
  then Error (Option.get runtime ^ " holds no bin/node")
  else
    let tmp = Filename.temp_dir "digestif-bundle" "" in
    let* () =
      check_ok "mkdir"
        [|
          "mkdir";
          "-p";
          Filename.concat tmp "bin";
          Filename.concat tmp "behaviors";
        |]
    in
    let* () =
      check_ok "cp" [| "cp"; binary; Filename.concat tmp "bin/digestif" |]
    in
    let* () =
      check_ok "chmod" [| "chmod"; "755"; Filename.concat tmp "bin/digestif" |]
    in
    let* () =
      List.fold_left
        (fun acc part ->
          let* () = acc in
          let src = Filename.concat behaviors part in
          if Sys.file_exists src then
            check_ok "cp"
              [| "cp"; "-R"; src; Filename.concat tmp "behaviors/" |]
          else Ok ())
        (Ok ()) behavior_parts
    in
    let* () =
      match runtime with
      | None -> Ok ()
      | Some r ->
          check_ok "cp" [| "cp"; "-R"; r; Filename.concat tmp "runtime" |]
    in
    let parts =
      [ "bin"; "behaviors" ] @ if runtime = None then [] else [ "runtime" ]
    in
    let* () =
      check_ok "tar" (Array.of_list ([ "tar"; "-czf"; out; "-C"; tmp ] @ parts))
    in
    check_ok "rm" [| "rm"; "-rf"; tmp |]
