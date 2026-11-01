(* digestif-update: the tools a release signer uses. A node checks, installs, pins and unpins
   through `digestif update`, and `digestif run` updates itself (docs/releases.md). *)

open Digestif_update
open Digestif_core
open Cmdliner

(* The node's own update state, the file `digestif run` and `digestif update` read. *)
let default_state () = Schedule.state_path (Digestif_core.Node.default_dir ())

let state_arg =
  Arg.(
    value
    & opt string (default_state ())
    & info [ "state" ] ~docv:"FILE" ~doc:"Update state file.")

let exit_err msg =
  prerr_endline ("digestif-update: " ^ msg);
  1

(* Signer tools. *)

let keygen_cmd =
  let out =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"SECRET_FILE")
  in
  let go out =
    if Sys.file_exists out then
      exit_err (out ^ " exists; refusing to overwrite a signing key")
    else
      let secret = Crypto.generate_signing_key () in
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 out
        (fun oc ->
          Out_channel.output_string oc (Keys.encode_secret secret ^ "\n"));
      print_endline (Keys.public secret);
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
    match (parsed, Keys.decode_secret (read key)) with
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
            Printf.printf "signed %s as %s into %s\n" doc (Keys.public secret)
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
    Printf.printf "{ \"sha256\": %S, \"size\": %d }\n" (Keys.hash_of_bytes b)
      (String.length b);
    0
  in
  Cmd.v
    (Cmd.info "hash"
       ~doc:"Print an artifact's sha256 and size for its manifest entry.")
    Term.(const go $ file)

let bundle_cmd =
  let binary =
    Arg.(
      required
      & opt (some file) None
      & info [ "binary" ] ~docv:"FILE"
          ~doc:"The node binary built for this platform.")
  in
  let behaviors =
    Arg.(
      required
      & opt (some dir) None
      & info [ "behaviors" ] ~docv:"DIR"
          ~doc:"The checkout's behaviors/ directory.")
  in
  let out =
    Arg.(required & opt (some string) None & info [ "out" ] ~docv:"FILE")
  in
  let go binary behaviors out =
    match Bundle.write ~binary ~behaviors ~out with
    | Error e -> exit_err e
    | Ok () ->
        let b = read out in
        Printf.printf "{ \"sha256\": %S, \"size\": %d }\n"
          (Keys.hash_of_bytes b) (String.length b);
        0
  in
  Cmd.v
    (Cmd.info "bundle"
       ~doc:
         "Write a release archive of the node binary and its behaviors, and \
          print its sha256 and size.")
    Term.(const go $ binary $ behaviors $ out)

let manifest_cmd =
  let version =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"VERSION")
  in
  let notes = Arg.(value & opt string "" & info [ "notes" ] ~docv:"TEXT") in
  let url_base =
    Arg.(
      required
      & opt (some string) None
      & info [ "url-base" ] ~docv:"URL"
          ~doc:
            "Where the archives are downloaded from; each artifact's url is \
             URL/<file name>.")
  in
  let artifacts =
    Arg.(
      non_empty
      & opt_all (pair ~sep:'=' string file) []
      & info [ "artifact" ] ~docv:"PLATFORM=FILE")
  in
  let go version notes url_base artifacts =
    match Version.of_string version with
    | Error e -> exit_err e
    | Ok _ ->
        let base =
          if String.ends_with ~suffix:"/" url_base then url_base
          else url_base ^ "/"
        in
        let now = Unix.gmtime (Unix.time ()) in
        let published_at =
          Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.000Z"
            (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday now.tm_hour
            now.tm_min now.tm_sec
        in
        let artifact (platform, file) =
          let b = read file in
          `Assoc
            [
              ("platform", `String platform);
              ("url", `String (base ^ Filename.basename file));
              ("sha256", `String (Keys.hash_of_bytes b));
              ("size", `Int (String.length b));
            ]
        in
        print_string
          (Yojson.Safe.pretty_to_string
             (`Assoc
                [
                  ("format", `String Release.manifest_format);
                  ("version", `String version);
                  ("published_at", `String published_at);
                  ("notes", `String notes);
                  ("artifacts", `List (List.map artifact artifacts));
                ])
          ^ "\n");
        0
  in
  Cmd.v
    (Cmd.info "manifest"
       ~doc:
         "Print a release manifest for the archives given, to commit before \
          anyone signs it.")
    Term.(const go $ version $ notes $ url_base $ artifacts)

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
            keygen_cmd;
            sign_cmd;
            hash_cmd;
            bundle_cmd;
            manifest_cmd;
            circle_body_cmd;
            circle_receive_cmd;
          ]))
