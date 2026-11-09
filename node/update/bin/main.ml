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
  (* A manifest is a node release's or a relay release's, told apart by its format, and each is
     signed over its own domain line. *)
  let parsed =
    if revocation then
      Result.map
        (fun _ -> Release.revocation_domain)
        (Release.revocation_of_string bytes)
    else
      match Release.document_kind bytes with
      | Ok Release.Relay_release ->
          Result.map
            (fun _ -> Release.relay_release_domain)
            (Release.relay_manifest_of_string bytes)
      | _ ->
          Result.map
            (fun _ -> Release.release_domain)
            (Release.manifest_of_string bytes)
  in
  match (parsed, Keys.decode_secret (read key)) with
  | Error e, _ | _, Error e -> exit_err e
  | Ok domain, Ok secret -> (
      let existing =
        if Sys.file_exists sig_path then
          Release.signatures_of_string (read sig_path)
        else Ok []
      in
      match existing with
      | Error e -> exit_err e
      | Ok sigs ->
          let sigs = Release.add_signature ~domain ~secret bytes sigs in
          Out_channel.with_open_bin sig_path (fun oc ->
              Out_channel.output_string oc (Release.signatures_to_string sigs));
          Printf.printf "signed %s as %s into %s\n" doc (Keys.public secret)
            sig_path;
          0)

(* sign --next (docs/releases.md, Signing a release): the waiting version, shown, then signed or
   dropped with the signer's own gh login. The key is read from the signer's key command into memory
   and nothing of it is written to disk. *)
let gh args =
  match Proc.run ~timeout:300. (Array.of_list ("gh" :: args)) with
  | Ok { code = 0; stdout; _ } -> Ok stdout
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "gh %s exited %d: %s"
           (String.concat " " (List.filteri (fun i _ -> i < 2) args))
           code (String.trim stderr))
  | Error e -> Error ("gh: " ^ e)

let git_with_gh =
  [
    "-c";
    "credential.helper=";
    "-c";
    "credential.helper=!gh auth git-credential";
  ]

(* sign --next's git, for the tool's own clone (Sign_next.sync_clone): its stdout, through the
   signer's gh login. *)
let sign_git args =
  match
    Proc.run ~timeout:600. (Array.of_list (("git" :: git_with_gh) @ args))
  with
  | Ok { code = 0; stdout; _ } -> Ok stdout
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "git %s exited %d: %s" (String.concat " " args) code
           (String.trim stderr))
  | Error e -> Error ("git: " ^ e)

(* sign --next's first step (Self_update): when a newer node release is published, the held
   digestif-update-<platform> this runs as is replaced with that release's, checked against both
   signers, and run again with the same arguments; execv returns only on failure. *)
let self_update (config : Sign_next.config) =
  let self = Sys.executable_name in
  match Platform.current () with
  | Error _ -> Ok ()
  | Ok platform -> (
      let tmp = Filename.temp_dir "digestif-self-update" "" in
      match
        Self_update.run ~gh ~repo:config.repo ~signers:(Trust_root.signers ())
          ~platform ~running:(Trust_root.version ()) ~self
          ~updated:(Sys.getenv_opt Self_update.updated_env)
          ~tmp ~say:print_endline
      with
      | Error e -> Error e
      | Ok None -> Ok ()
      | Ok (Some _) -> (
          let env =
            Array.append (Unix.environment ())
              [|
                Self_update.updated_env ^ "="
                ^ Version.to_string (Trust_root.version ());
              |]
          in
          flush_all ();
          try Unix.execve self Sys.argv env
          with Unix.Unix_error (e, _, _) ->
            Error
              (Printf.sprintf
                 "%s was updated but could not be run again (%s); run the same \
                  command again"
                 self (Unix.error_message e))))

let sign_next ~relay =
  let prompt =
    if Unix.isatty Unix.stdin then Some (Sign_next.read_hidden ?prompt:None)
    else None
  in
  match Sign_next.key_reader ~path:(Sign_next.config_path ()) ~prompt with
  | Error e -> exit_err e
  | Ok (config, read_key) -> (
      match self_update config with
      | Error e -> exit_err e
      | Ok () -> (
          let ask q =
            print_string q;
            flush stdout;
            Option.value (In_channel.input_line stdin) ~default:""
          in
          let tmp = Filename.temp_dir "digestif-sign" "" in
          match
            Sign_next.run ~gh ~git:sign_git
              ~clone:(Sign_next.clone_path config.repo)
              ~signers:(Trust_root.signers ()) ~config ~read_key ~ask
              ~say:print_endline ~tmp ~relay:(relay config)
          with
          | Ok () -> 0
          | Error e -> exit_err e))

(* A recall: one signer's signed statement that a published version is bad (docs/releases.md, A
   recall). It needs nothing of the fleet: the signer's key, their own `gh` login to commit it to
   the channel branch, and, on a machine running a node, that node to post it on the circle. *)

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

(* Commit what [write] puts into a fresh clone of the channel branch and push it as one commit; a
   write that changes nothing commits nothing, and answers false. *)
let commit_if_changed ~repo ~branch ~message write =
  let ( let* ) = Result.bind in
  let dir = Filename.temp_dir "digestif-relay-publish" "" in
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
      let* () = write checkout in
      let* () = git ~cwd:checkout [ "add"; "--all"; "." ] in
      match
        Proc.run ~timeout:60.
          [| "git"; "-C"; checkout; "diff"; "--cached"; "--quiet" |]
      with
      | Ok { code = 0; _ } -> Ok false
      | Ok { code = 1; _ } ->
          let* () = git ~cwd:checkout [ "commit"; "--quiet"; "-m"; message ] in
          let* () =
            git ~cwd:checkout [ "push"; "--quiet"; "origin"; "HEAD:" ^ branch ]
          in
          Ok true
      | Ok { code; stderr; _ } ->
          Error
            (Printf.sprintf "git diff exited %d: %s" code (String.trim stderr))
      | Error e -> Error e)

(* This machine's node, when one runs here: what the relay line reads every relay's version with,
   and what posts the announcement. *)
let with_node ~data_dir f =
  if Sys.file_exists (Filename.concat data_dir "log.sqlite3") then
    let node = Node.open_ data_dir in
    Fun.protect ~finally:(fun () -> Node.close node) (fun () -> Some (f node))
  else None

let relay_versions ~data_dir () =
  with_node ~data_dir (Relay_publish.read_relays ~transport:Relay_client.curl)

let relay_announce ~data_dir signed =
  match
    with_node ~data_dir (fun node ->
        Relay_publish.announce
          ~reads:(fun () ->
            Relay_publish.read_relays ~transport:Relay_client.curl node)
          node signed)
  with
  | Some r -> r
  | None ->
      Ok
        (Relay_publish.No_node
           (Relay_publish.post_line (Circle_relay_release.to_body signed)))

let relay_publish_env ~repo ~branch ~data_dir : Relay_publish.env =
  {
    gh;
    repo;
    signers = Trust_root.signers ();
    channel = commit_if_changed ~repo ~branch;
    announce = relay_announce ~data_dir;
    say = print_endline;
  }

(* sign --next's relay line: the node at the default data directory, and relay-publish on the
   channel branch when a signature completes the signer set. A held announcement is said and is
   not a failure of the signing. *)
let sign_next_relay (config : Sign_next.config) : Sign_next.relay =
  let data_dir = Node.default_dir () in
  {
    relay_versions = relay_versions ~data_dir;
    publish =
      (fun version ->
        Result.map_error Relay_publish.error_to_string
          (Result.map ignore
             (Relay_publish.run
                (relay_publish_env ~repo:config.repo ~branch:"channel" ~data_dir)
                ~version)));
  }

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
    | true, Some _, _ | true, _, Some _ ->
        exit_err
          "sign --next takes no --key or DOCUMENT: it reads the key from the \
           command ~/.config/digestif/signer.json names, else asks you to \
           paste it at a hidden prompt"
    | true, None, None -> sign_next ~relay:sign_next_relay
    | false, None, _ -> exit_err "sign needs --key SECRET_FILE"
    | false, _, None -> exit_err "sign needs the DOCUMENT to sign"
    | false, Some key, Some doc -> sign_document ~key ~doc ~revocation
  in
  Cmd.v
    (Cmd.info "sign" ~doc:"Add your signature beside a manifest or revocation.")
    Term.(const go $ key $ doc $ revocation $ next)

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
      value
      & opt (some string) None
      & info [ "key" ] ~docv:"SECRET_FILE"
          ~doc:
            "Your release key, as for sign: /dev/stdin to pipe it in. Without \
             it the key is read from the command \
             ~/.config/digestif/signer.json names, as sign --next reads it.")
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
      & opt (some string) None
      & info [ "repo" ] ~docv:"OWNER/NAME"
          ~doc:
            "The repository holding the channel: signer.json's \"repo\" when \
             the key is read from it, else digestif-ai/digestif.")
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
  (* The key and the channel's repository: --key's file, else the command signer.json names, which
     runs only once the version parses. *)
  let signer key repo =
    let ( let* ) = Result.bind in
    match key with
    | Some path ->
        let* secret = Keys.decode_secret (read path) in
        Ok (secret, Option.value repo ~default:Sign_next.default_repo)
    | None ->
        let* config = Sign_next.load_config (Sign_next.config_path ()) in
        let* secret = Sign_next.secret config in
        Ok (secret, Option.value repo ~default:config.repo)
  in
  let go version reason key channel repo branch data_dir =
    match
      Result.bind (Version.of_string version) (fun version ->
          Result.map (fun s -> (version, s)) (signer key repo))
    with
    | Error e -> exit_err e
    | Ok (version, (secret, repo)) -> (
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

(* Whether a manifest carries every signature a node needs, checked with a node's own Policy.check
   against the signer set this binary was built with (docs/releases.md, The channel). It is what
   `ci/release.sh candidate` runs before a version reaches a test node, and every node checks again
   with the set it holds. Revocations are not read: a revoked signer still halts every node.

   A relay manifest (digestif-relay-release-v1) is checked the same way, over its own domain line,
   with Policy.check_relay: the rule a node's fold of a relay_release announcement applies. *)
let verify_signatures ~manifest ~sig_files ~signers ~version ~out =
  let ( let* ) = Result.bind in
  let bytes = read manifest in
  let parsed =
    let* kind = Release.document_kind bytes in
    let* doc =
      match kind with
      | Release.Node_release ->
          Result.map (fun d -> `Node d) (Release.manifest_of_string bytes)
      | Release.Relay_release ->
          Result.map
            (fun d -> `Relay d)
            (Release.relay_manifest_of_string bytes)
      | Release.Other f ->
          Error
            (Printf.sprintf "format %S is neither %S nor %S" f
               Release.manifest_format Release.relay_manifest_format)
    in
    let* set =
      match signers with
      | None -> Ok (Trust_root.signers ())
      | Some f -> Trust_root.signers_of_string (read f)
    in
    let* lists =
      Release.all (fun f -> Release.signatures_of_string (read f)) sig_files
    in
    let doc_version =
      match doc with
      | `Node (d : Release.manifest) -> d.version
      | `Relay (d : Release.relay_manifest) -> d.relay_version
    in
    let* () =
      match version with
      | Some want when want <> Version.to_string doc_version ->
          Error
            (Printf.sprintf "%s is version %s, not %s" manifest
               (Version.to_string doc_version)
               want)
      | _ -> Ok ()
    in
    Ok (doc, set, List.concat lists)
  in
  match parsed with
  | Error e -> exit_err e
  | Ok (doc, set, sigs) -> (
      let next_signers, domain =
        match doc with
        | `Node d -> (Option.value d.signers ~default:[], Release.release_domain)
        | `Relay _ -> ([], Release.relay_release_domain)
      in
      let wanted =
        List.fold_left
          (fun acc (s : Release.signer) ->
            if List.exists (fun (a : Release.signer) -> a.key = s.key) acc then
              acc
            else acc @ [ s ])
          [] (set @ next_signers)
      in
      let msg = Release.signed_bytes ~domain bytes in
      let kept =
        List.fold_left
          (fun acc (s : Release.signature) ->
            if
              List.exists (fun (k : Release.signature) -> k.by = s.by) acc
              || (not
                    (List.exists
                       (fun (w : Release.signer) -> w.key = s.by)
                       wanted))
              || not (Keys.verify ~pub:s.by ~signature:s.signature msg)
            then acc
            else acc @ [ s ])
          [] sigs
      in
      List.iter
        (fun (w : Release.signer) ->
          let signed =
            List.exists (fun (k : Release.signature) -> k.by = w.key) kept
          in
          Printf.printf "%s %s\n"
            (if signed then "signed" else "missing")
            w.name)
        wanted;
      let trust : Policy.trust = { signers = set; revoked = [] } in
      let checked =
        match doc with
        | `Node doc ->
            Result.map ignore
              (Policy.check trust { Release.bytes; doc; signatures = kept })
        | `Relay doc ->
            Policy.check_relay trust { Release.bytes; doc; signatures = kept }
      in
      match checked with
      | Error r -> exit_err (Policy.refusal_to_string r)
      | Ok () ->
          Option.iter
            (fun path ->
              Out_channel.with_open_bin path (fun oc ->
                  Out_channel.output_string oc
                    (Release.signatures_to_string kept)))
            out;
          0)

let verify_cmd =
  let manifest =
    Arg.(required & pos 0 (some file) None & info [] ~docv:"MANIFEST")
  in
  let sig_files =
    Arg.(
      value & pos_right 0 file []
      & info [] ~docv:"SIGNATURES"
          ~doc:
            "Signature files beside the manifest, each a {signatures: [...]}.")
  in
  let signers =
    Arg.(
      value
      & opt (some file) None
      & info [ "signers" ] ~docv:"FILE"
          ~doc:
            "The signer set to check against, a digestif-signers-v0 file; by \
             default the set this binary was built with.")
  in
  let version =
    Arg.(
      value
      & opt (some string) None
      & info [ "expect-version" ] ~docv:"VERSION"
          ~doc:"Refuse a manifest of any other version.")
  in
  let out =
    Arg.(
      value
      & opt (some string) None
      & info [ "out" ] ~docv:"FILE"
          ~doc:
            "When every signer signed, write their signatures, one per key, as \
             the manifest's .sig.json.")
  in
  let go manifest sig_files signers version out =
    verify_signatures ~manifest ~sig_files ~signers ~version ~out
  in
  Cmd.v
    (Cmd.info "verify"
       ~doc:
         "Print which signers signed a manifest, one 'signed NAME' or 'missing \
          NAME' line each; exit 0 only when a node would accept the \
          signatures.")
    Term.(const go $ manifest $ sig_files $ signers $ version $ out)

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
  let runtime =
    Arg.(
      required
      & opt (some dir) None
      & info [ "runtime" ] ~docv:"DIR"
          ~doc:
            "This platform's Node.js: a directory holding bin/node, carried as \
             the archive's runtime/.")
  in
  let update_binary =
    Arg.(
      value
      & opt (some file) None
      & info [ "update-binary" ] ~docv:"FILE"
          ~doc:
            "The digestif-update built beside it, carried as \
             bin/digestif-update.")
  in
  let out =
    Arg.(required & opt (some string) None & info [ "out" ] ~docv:"FILE")
  in
  let go binary update_binary behaviors runtime out =
    match Bundle.write ?update_binary ~runtime ~binary ~behaviors ~out () with
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
         "Write a release archive of the node binary, its behaviors and the \
          Node.js they run with, and print its sha256 and size.")
    Term.(const go $ binary $ update_binary $ behaviors $ runtime $ out)

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

(* The relay release's manifest (docs/releases.md, Relay releases), written by the relay release
   build from the bundle it packed, before anyone signs it. Every migration is read out of the
   bundle itself, so the manifest names exactly the bytes the bundle carries. *)
let relay_manifest_cmd =
  let version =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"VERSION")
  in
  let notes = Arg.(value & opt string "" & info [ "notes" ] ~docv:"TEXT") in
  let bundle =
    Arg.(
      required
      & opt (some file) None
      & info [ "bundle" ] ~docv:"FILE"
          ~doc:"The relay bundle, digestif-relay-<version>.tar.gz.")
  in
  let url_base =
    Arg.(
      required
      & opt (some string) None
      & info [ "url-base" ] ~docv:"URL"
          ~doc:
            "Where the bundle is downloaded from; its url is URL/<file name>.")
  in
  let compatible_with =
    Arg.(
      required
      & opt (some string) None
      & info [ "compatible-with" ] ~docv:"VERSION"
          ~doc:
            "The oldest relay version this one is wire-compatible with \
             (docs/releases.md, Mixed relay versions).")
  in
  let go version notes bundle url_base compatible_with =
    match
      Relay_bundle.manifest ~version ~notes ~url_base ~compatible_with
        ~published_at:(Time_fmt.now ()) ~archive:bundle
    with
    | Error e -> exit_err e
    | Ok m ->
        print_string (Release.relay_manifest_to_string m);
        0
  in
  Cmd.v
    (Cmd.info "relay-manifest"
       ~doc:
         "Print a relay release manifest for the bundle given, to sign as a \
          relay release.")
    Term.(const go $ version $ notes $ bundle $ url_base $ compatible_with)

(* relay-publish (docs/releases.md, Publishing a relay release): the three steps of
   Relay_publish, which `ci/release.sh relay-publish` runs with the newest published node
   release's digestif-update. Exits 0 once published and announced or the announcement is written
   or printed, 75 when a signer has not signed or the announcement is held (the one line it prints
   says what to run again), and 1 on a failure. *)
let relay_publish_cmd =
  let version =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"VERSION" ~doc:"The relay version, X.Y.Z.")
  in
  let repo =
    Arg.(
      value
      & opt string Sign_next.default_repo
      & info [ "repo" ] ~docv:"OWNER/NAME"
          ~doc:"The repository holding the draft and the channel.")
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
          ~doc:"The node that posts the announcement on the circle.")
  in
  let go version repo branch data_dir =
    let version =
      if String.starts_with ~prefix:Sign_next.relay_tag_prefix version then
        String.sub version
          (String.length Sign_next.relay_tag_prefix)
          (String.length version - String.length Sign_next.relay_tag_prefix)
      else version
    in
    match Version.of_string version with
    | Error e -> exit_err e
    | Ok version -> (
        match
          Relay_publish.run (relay_publish_env ~repo ~branch ~data_dir) ~version
        with
        | Ok (Relay_publish.Held _) -> 75
        | Ok _ -> 0
        | Error (Relay_publish.Waiting e) ->
            prerr_endline ("digestif-update: " ^ e);
            75
        | Error (Relay_publish.Failed e) -> exit_err e)
  in
  Cmd.v
    (Cmd.info "relay-publish"
       ~doc:
         "Publish a relay release every signer signed and announce it on the \
          circle.")
    Term.(const go $ version $ repo $ branch $ data_dir)

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
             verify_cmd;
             hash_cmd;
             bundle_cmd;
             manifest_cmd;
             relay_manifest_cmd;
             relay_publish_cmd;
             stage_test_cmd;
             circle_body_cmd;
             circle_receive_cmd;
           ])
    with Sys_error e -> exit_err e
