(* A release archive: a gzipped tar of bin/digestif and the parts of behaviors/ the node runs
   (docs/releases.md, Cutting a release). The signer's `digestif-update bundle` writes one, and a
   local install (Stage.local) lays a release directory out from the same parts. *)

let behavior_parts = [ "bin"; "src"; "prompts"; "launchd"; "package.json" ]
let ( let* ) = Result.bind

let check_ok what argv =
  match Proc.run ~timeout:300. argv with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "%s exited %d: %s" what code (String.trim stderr))
  | Error e -> Error e

(* Write [out] from the node binary [binary] and the checkout's [behaviors] directory. *)
let write ~binary ~behaviors ~out =
  if not (Sys.file_exists (Filename.concat behaviors "bin/nightly-hook")) then
    Error
      (behaviors ^ " holds no bin/nightly-hook; pass the checkout's behaviors/")
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
      check_ok "tar" [| "tar"; "-czf"; out; "-C"; tmp; "bin"; "behaviors" |]
    in
    check_ok "rm" [| "rm"; "-rf"; tmp |]
