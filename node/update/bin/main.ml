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

let sign_document ~key ~doc ~revocation =
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

let sign_cmd =
  let key =
    Arg.(value & opt (some string) None & info [ "key" ] ~docv:"SECRET_FILE")
  in
  let doc = Arg.(value & pos 0 (some string) None & info [] ~docv:"DOCUMENT") in
  let revocation =
    Arg.(
      value & flag
      & info [ "revocation" ] ~doc:"DOCUMENT is a revocation, not a manifest.")
  in
  let next =
    Arg.(
      value & flag
      & info [ "next" ]
          ~doc:
            "Sign the version waiting for signatures (docs/releases.md, \
             Signing a release).")
  in
  let go key doc revocation next =
    match (next, key, doc) with
    | true, _, _ -> exit_err "sign --next is not built yet (ISS-37087)"
    | false, None, _ -> exit_err "sign needs --key SECRET_FILE"
    | false, _, None -> exit_err "sign needs the DOCUMENT to sign"
    | false, Some key, Some doc -> sign_document ~key ~doc ~revocation
  in
  Cmd.v
    (Cmd.info "sign" ~doc:"Add your signature beside a manifest or revocation.")
    Term.(const go $ key $ doc $ revocation $ next)

(* A recall: one signer's signed statement that a published version is bad (docs/releases.md, A
   recall). It needs nothing of the fleet: the signer's key, their own `gh` login to commit it to
   the channel branch, and, on a machine running a node, that node to post it on the circle. *)

let git_with_gh =
  [
    "-c";
    "credential.helper=";
    "-c";
    "credential.helper=!gh auth git-credential";
  ]

let git ?cwd args =
  let argv =
    Array.of_list
      (("git" :: (match cwd with Some d -> [ "-C"; d ] | None -> []))
      @ git_with_gh @ args)
  in
  match Proc.run ~timeout:300. argv with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "git %s exited %d: %s" (List.hd args) code
           (String.trim stderr))
  | Error e -> Error e

(* Commit what [write] puts into a fresh clone of [branch] and push it, so the recall is on the
   channel in one commit. *)
let commit_to_channel ~repo ~branch ~message write =
  let ( let* ) = Result.bind in
  let dir = Filename.temp_dir "digestif-recall" "" in
  let checkout = Filename.concat dir "channel" in
  Fun.protect
    ~finally:(fun () -> try Stage.remove_tree dir with _ -> ())
    (fun () ->
      let* () =
        git
          [
            "clone";
            "--quiet";
            "--depth";
            "1";
            "--branch";
            branch;
            "https://github.com/" ^ repo ^ ".git";
            checkout;
          ]
      in
      let* written = write checkout in
      let* () = git ~cwd:checkout [ "add"; "--all"; "." ] in
      let* () = git ~cwd:checkout [ "commit"; "--quiet"; "-m"; message ] in
      let* () =
        git ~cwd:checkout [ "push"; "--quiet"; "origin"; "HEAD:" ^ branch ]
      in
      Ok written)

(* Post the recall on the circle from the node at [data_dir], or say how to from one that runs. *)
let post_to_circle ~data_dir (r : Release.recall Release.signed) =
  let body = Circle_recall.to_body r in
  if Sys.file_exists (Filename.concat data_dir "log.sqlite3") then
    let node = Node.open_ data_dir in
    Fun.protect
      ~finally:(fun () -> Node.close node)
      (fun () ->
        match Node.write node ~kind:Circle_recall.kind body with
        | Ok (hash, _) ->
            Printf.printf
              "posted on the circle as %s; the node's next sync carries it\n"
              hash
        | Error e ->
            Printf.printf
              "not posted on the circle (%s); post it from a machine running a \
               node:\n"
              e;
            Printf.printf
              "  printf '%%s' '%s' | digestif post --kind %s --body -\n"
              (Yojson.Safe.to_string body)
              Circle_recall.kind)
  else (
    print_endline
      "no node runs here; post it on the circle from a machine running one:";
    Printf.printf "  printf '%%s' '%s' | digestif post --kind %s --body -\n"
      (Yojson.Safe.to_string body)
      Circle_recall.kind)

let recall_cmd =
  let version =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"VERSION")
  in
  let reason =
    Arg.(
      required
      & opt (some string) None
      & info [ "reason" ] ~docv:"TEXT" ~doc:"Why the version is recalled.")
  in
  let key =
    Arg.(
      required
      & opt (some string) None
      & info [ "key" ] ~docv:"SECRET_FILE"
          ~doc:"Your release key, as for sign: /dev/stdin to pipe it in.")
  in
  let channel =
    Arg.(
      value
      & opt (some string) None
      & info [ "channel" ] ~docv:"DIR"
          ~doc:
            "Write into this checkout of the channel and commit nothing, \
             instead of committing to the channel branch.")
  in
  let repo =
    Arg.(
      value
      & opt string "digestif-ai/digestif"
      & info [ "repo" ] ~docv:"OWNER/NAME"
          ~doc:"The repository holding the channel.")
  in
  let branch =
    Arg.(
      value & opt string "channel"
      & info [ "branch" ] ~docv:"BRANCH" ~doc:"The channel's branch.")
  in
  let data_dir =
    Arg.(
      value
      & opt string (Node.default_dir ())
      & info [ "data-dir" ] ~docv:"DIR"
          ~doc:"The node that posts the recall on the circle.")
  in
  let go version reason key channel repo branch data_dir =
    match (Version.of_string version, Keys.decode_secret (read key)) with
    | Error e, _ | _, Error e -> exit_err e
    | Ok version, Ok secret -> (
        let write dir =
          Recall_channel.write_recall ~dir ~secret ~version ~reason
            ~recalled_at:(Time_fmt.now ())
        in
        let message =
          Printf.sprintf "Recall %s: %s" (Version.to_string version) reason
        in
        let written =
          match channel with
          | Some dir -> write dir
          | None -> commit_to_channel ~repo ~branch ~message write
        in
        match written with
        | Error e -> exit_err e
        | Ok w ->
            let v = Version.to_string version in
            (match (w.first, channel) with
            | true, None ->
                Printf.printf "recalled %s on %s's %s branch\n" v repo branch
            | false, None ->
                Printf.printf
                  "signed the recall of %s already on %s's %s branch\n" v repo
                  branch
            | true, Some d -> Printf.printf "recalled %s in %s\n" v d
            | false, Some d ->
                Printf.printf "signed the recall of %s already in %s\n" v d);
            if (not w.first) && w.recall.doc.reason <> reason then
              Printf.printf "the recall's reason stays the first signer's: %s\n"
                w.recall.doc.reason;
            post_to_circle ~data_dir w.recall;
            0)
  in
  Cmd.v
    (Cmd.info "recall" ~doc:"Recall a published version with your key alone.")
    Term.(
      const go $ version $ reason $ key $ channel $ repo $ branch $ data_dir)

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
  let platforms =
    Arg.(
      required
      & opt (some file) None
      & info [ "platforms" ] ~docv:"FILE"
          ~doc:
            "The platforms a release ships (ci/platforms.json); the manifest \
             must name an artifact for each, once.")
  in
  let go version notes url_base platforms artifacts =
    let shipped =
      Result.map_error
        (fun e -> platforms ^ ": " ^ e)
        (Platform.shipped_of_string (read platforms))
    in
    match (Version.of_string version, shipped) with
    | Error e, _ | _, Error e -> exit_err e
    | Ok _, Ok shipped -> (
        match Platform.check_shipped ~shipped (List.map fst artifacts) with
        | Error e ->
            exit_err ("the manifest does not name every shipped platform: " ^ e)
        | Ok () ->
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
            0)
  in
  Cmd.v
    (Cmd.info "manifest"
       ~doc:
         "Print a release manifest for the archives given, to commit before \
          anyone signs it.")
    Term.(const go $ version $ notes $ url_base $ platforms $ artifacts)

(* The checks a node runs on a release it stages (Stage.from_archive), run on a release archive
   before it is published: unpack it, find bin/digestif, find the Node.js its behaviors need, and
   self-test the binary at VERSION against a fresh node's data. *)
let stage_test_cmd =
  let archive =
    Arg.(required & pos 0 (some file) None & info [] ~docv:"ARCHIVE")
  in
  let version =
    Arg.(
      required
      & opt (some string) None
      & info [ "expect-version" ] ~docv:"VERSION"
          ~doc:"The version the archive's binary must report.")
  in
  let go archive version =
    match Version.of_string version with
    | Error e -> exit_err e
    | Ok v -> (
        let dir = Filename.temp_dir "digestif-stage-test" "" in
        match Stage.from_archive ~dir ~version:v (read archive) with
        | Ok name ->
            Printf.printf "%s staged as %s in %s\n" archive name dir;
            0
        | Error (Stage.Retry e | Stage.Refuse e) ->
            exit_err (archive ^ " would not stage: " ^ e))
  in
  Cmd.v
    (Cmd.info "stage-test"
       ~doc:
         "Stage a release archive the way a node stages one, into a fresh data \
          directory, and fail if a node would not.")
    Term.(const go $ archive $ version)

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

(* A file a command names that cannot be read (a --key path that does not exist) ends the command
   with one line naming it, never cmdliner's uncaught-exception report. *)
let () =
  let info =
    Cmd.info "digestif-update"
      ~version:(Version.to_string (Trust_root.version ()))
  in
  exit
  @@
    try
      Cmd.eval' ~catch:false
        (Cmd.group info
           [
             keygen_cmd;
             sign_cmd;
             recall_cmd;
             hash_cmd;
             bundle_cmd;
             manifest_cmd;
             stage_test_cmd;
             circle_body_cmd;
             circle_receive_cmd;
           ])
    with Sys_error e -> exit_err e
