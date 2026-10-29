(* digestif-update: the node's self-update, and the tools a release signer uses. *)

open Digestif_update
open Cmdliner

let default_state () =
  let home = Option.value (Sys.getenv_opt "HOME") ~default:"." in
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some d when d <> "" -> Filename.concat d "digestif/update.json"
  | _ ->
      if Sys.file_exists (Filename.concat home "Library") then
        Filename.concat home "Library/Application Support/Digestif/update.json"
      else Filename.concat home ".local/state/digestif/update.json"

let state_arg =
  Arg.(
    value
    & opt string (default_state ())
    & info [ "state" ] ~docv:"FILE" ~doc:"Update state file.")

let feed_arg =
  Arg.(
    value
    & opt string Feed.default_url
    & info [ "feed" ] ~docv:"URL"
        ~doc:
          "Release channel: an https URL or a local directory holding \
           index.json.")

let exit_err msg =
  prerr_endline ("digestif-update: " ^ msg);
  1

let platform () =
  match Platform.current () with Ok p -> p | Error e -> failwith e

let print_plan (plan : Policy.plan) problems =
  List.iter (fun p -> Printf.printf "unreadable: %s\n" p) problems;
  List.iter
    (fun (s : Policy.skipped) ->
      Printf.printf "refused %s: %s\n"
        (Version.to_string s.skipped_version)
        s.reason)
    plan.skipped;
  Option.iter
    (fun v -> Printf.printf "pinned at %s\n" (Version.to_string v))
    plan.pinned_at;
  Printf.printf "signers: %s\n"
    (match plan.trust.signers with
    | [] -> "none configured"
    | l ->
        String.concat ", "
          (List.map (fun (s : Release.signer) -> s.name ^ " " ^ s.key) l));
  List.iter (fun k -> Printf.printf "revoked: %s\n" k) plan.trust.revoked

let check_cmd =
  let go state_path base =
    match State.load state_path with
    | Error e -> exit_err e
    | Ok state -> (
        match
          Updater.check ~fetch:Feed.default_fetch ~base ~platform:(platform ())
            state
        with
        | Error e -> exit_err e
        | Ok (plan, problems) ->
            Printf.printf "installed %s\n" (Version.to_string state.installed);
            print_plan plan problems;
            (match plan.install with
            | Some r ->
                Printf.printf "would install %s\n"
                  (Version.to_string r.doc.version)
            | None -> print_endline "nothing to install");
            0)
  in
  Cmd.v
    (Cmd.info "check" ~doc:"Say what an update would install, changing nothing.")
    Term.(const go $ state_arg $ feed_arg)

let apply_cmd =
  let binary =
    Arg.(
      value
      & opt string Sys.executable_name
      & info [ "binary" ] ~docv:"PATH" ~doc:"The node binary to replace.")
  in
  let go state_path base binary =
    match
      Updater.run ~fetch:Feed.default_fetch ~base ~platform:(platform ())
        ~state_path ~binary
    with
    | Error e -> exit_err e
    | Ok o ->
        print_plan o.plan o.problems;
        (match o.installed with
        | Some v ->
            Printf.printf "installed %s; restart the node to run it\n"
              (Version.to_string v)
        | None -> print_endline "nothing to install");
        0
  in
  Cmd.v
    (Cmd.info "apply"
       ~doc:"Install the newest release both signers signed, or the pinned one.")
    Term.(const go $ state_arg $ feed_arg $ binary)

let update_state state_path f =
  match State.load state_path with
  | Error e -> exit_err e
  | Ok s -> (
      match f s with
      | Error e -> exit_err e
      | Ok s ->
          State.save state_path s;
          0)

let pin_cmd =
  let v = Arg.(required & pos 0 (some string) None & info [] ~docv:"VERSION") in
  let go state_path v =
    update_state state_path (fun s ->
        Result.map
          (fun v -> { s with State.pin = Some v })
          (Version.of_string v))
  in
  Cmd.v
    (Cmd.info "pin" ~doc:"Install only VERSION from now on; nothing newer.")
    Term.(const go $ state_arg $ v)

let unpin_cmd =
  let go state_path =
    update_state state_path (fun s -> Ok { s with State.pin = None })
  in
  Cmd.v
    (Cmd.info "unpin" ~doc:"Follow the newest release again.")
    Term.(const go $ state_arg)

(* Signer tools. *)

let keygen_cmd =
  let out =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"SECRET_FILE")
  in
  let go out =
    if Sys.file_exists out then
      exit_err (out ^ " exists; refusing to overwrite a signing key")
    else
      let secret =
        Crypto.secret_of_seed (Mirage_crypto_rng_unix.getrandom 32)
      in
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 out
        (fun oc ->
          Out_channel.output_string oc (Crypto.secret_to_string secret ^ "\n"));
      print_endline (Crypto.public_key_of_secret secret);
      0
  in
  Cmd.v
    (Cmd.info "keygen"
       ~doc:"Make a release signing key; prints the public half.")
    Term.(const go $ out)

let read path = In_channel.with_open_bin path In_channel.input_all

let sign_cmd =
  let key =
    Arg.(required & opt (some string) None & info [ "key" ] ~docv:"SECRET_FILE")
  in
  let doc =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"DOCUMENT")
  in
  let revocation =
    Arg.(
      value & flag
      & info [ "revocation" ] ~doc:"DOCUMENT is a revocation, not a manifest.")
  in
  let go key doc revocation =
    let sig_path = Filename.remove_extension doc ^ ".sig.json" in
    let bytes = read doc in
    let parsed =
      if revocation then Result.map ignore (Release.revocation_of_string bytes)
      else Result.map ignore (Release.manifest_of_string bytes)
    in
    match (parsed, Crypto.secret_of_string (read key)) with
    | Error e, _ | _, Error e -> exit_err e
    | Ok (), Ok secret -> (
        let existing =
          if Sys.file_exists sig_path then
            Release.signatures_of_string (read sig_path)
          else Ok []
        in
        match existing with
        | Error e -> exit_err e
        | Ok sigs ->
            let domain =
              if revocation then Release.revocation_domain
              else Release.release_domain
            in
            let sigs = Release.add_signature ~domain ~secret bytes sigs in
            Out_channel.with_open_bin sig_path (fun oc ->
                Out_channel.output_string oc (Release.signatures_to_string sigs));
            Printf.printf "signed %s as %s into %s\n" doc
              (Crypto.public_key_of_secret secret)
              sig_path;
            0)
  in
  Cmd.v
    (Cmd.info "sign" ~doc:"Add your signature beside a manifest or revocation.")
    Term.(const go $ key $ doc $ revocation)

let hash_cmd =
  let file = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE") in
  let go file =
    let b = read file in
    Printf.printf "{ \"sha256\": %S, \"size\": %d }\n" (Crypto.sha256 b)
      (String.length b);
    0
  in
  Cmd.v
    (Cmd.info "hash"
       ~doc:"Print an artifact's sha256 and size for its manifest entry.")
    Term.(const go $ file)

(* The circle half of a revocation (docs/protocol.md, release_revocation). *)

let circle_body_cmd =
  let doc =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"REVOCATION")
  in
  let go doc =
    let sig_path = Filename.remove_extension doc ^ ".sig.json" in
    let bytes = read doc in
    match Release.revocation_of_string bytes with
    | Error e -> exit_err e
    | Ok parsed -> (
        if not (Sys.file_exists sig_path) then
          exit_err (sig_path ^ " does not exist; sign the revocation first")
        else
          match Release.signatures_of_string (read sig_path) with
          | Error e -> exit_err e
          | Ok signatures ->
              print_endline
                (Yojson.Safe.pretty_to_string
                   (Circle_revocation.to_body
                      { Release.bytes; doc = parsed; signatures }));
              0)
  in
  Cmd.v
    (Cmd.info "circle-body"
       ~doc:
         "Print the release_revocation body that carries REVOCATION and its \
          signatures on the circle.")
    Term.(const go $ doc)

let circle_receive_cmd =
  let body = Arg.(required & pos 0 (some string) None & info [] ~docv:"BODY") in
  let go state_path body =
    match Yojson.Safe.from_string (read body) with
    | exception Yojson.Json_error e -> exit_err (body ^ " is not JSON: " ^ e)
    | json -> (
        match Circle_revocation.receive_body ~state_path json with
        | Error e -> exit_err e
        | Ok outcome -> (
            print_endline (Circle_revocation.outcome_to_string outcome);
            match outcome with
            | Circle_revocation.Not_signed_by_a_current_signer _ -> 1
            | _ -> 0))
  in
  Cmd.v
    (Cmd.info "circle-receive"
       ~doc:
         "Verify a release_revocation body read from the circle and record the \
          revoked key.")
    Term.(const go $ state_arg $ body)

let () =
  let info =
    Cmd.info "digestif-update"
      ~version:(Version.to_string (Trust_root.version ()))
  in
  exit
    (Cmd.eval'
       (Cmd.group info
          [
            check_cmd;
            apply_cmd;
            pin_cmd;
            unpin_cmd;
            keygen_cmd;
            sign_cmd;
            hash_cmd;
            circle_body_cmd;
            circle_receive_cmd;
          ]))
