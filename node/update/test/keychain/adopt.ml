(* signer adopt's work (Signing_job.adopt) as a program of its own, so test_update.ml runs it under
   a HOME whose login Keychain is the test's: the handover on stdin, the signer's public key as the
   first argument. A second argument, `refuse`, is a store that writes nothing and errors. The
   Keychain never asks: what would prompt is an error, so no run waits on a dialog. *)

open Digestif_update

external no_prompts : unit -> unit = "digestif_test_keychain_no_prompts"

let () =
  no_prompts ();
  let store =
    match Sys.argv with
    | [| _; _; "refuse" |] ->
        Some (fun ~service:_ ~account:_ ~label:_ _ -> Error "refused")
    | _ -> None
  in
  let signers = [ { Release.name = "Test"; key = Sys.argv.(1) } ] in
  match
    Result.bind
      (Signing_job.handover_of_string (In_channel.input_all stdin))
      (Signing_job.adopt ?store ~signers ~account:"test")
  with
  | Ok pub -> print_endline pub
  | Error e ->
      prerr_endline e;
      exit 1
