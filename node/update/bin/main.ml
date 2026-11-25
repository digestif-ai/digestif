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

(* sign --next's first step (Out_of_date): when a newer node release is published than the
   digestif-update this runs as, it says so and how that release reaches the signer, and the run
   goes on. It reads the run's one releases listing and its one read of the channel. *)
let out_of_date ~listed ~channel =
  Out_of_date.run ~listed ~signers:(Trust_root.signers ()) ~channel
    ~running:(Trust_root.version ()) ~self:Sys.executable_name
    ~say:print_endline ()

(* The signer-set changes the node on this machine holds (State.signer_sets), when one runs here. *)
let held_signer_sets () =
  match State.load (Schedule.state_path (Node.default_dir ())) with
  | Ok st -> st.signer_sets
  | Error _ -> []

(* The set sign --next signs under (Signers_channel.current): the build's, advanced by the channel's
   signers/ and this machine's node, so a promoted admin's signature is asked for at once. *)
let current_signers ~channel =
  Signers_channel.current ~build:(Trust_root.signers ())
    ~channel:(Result.to_option channel) ~held:(held_signer_sets ())

(* The run's timing log (Timing), under the tool's state directory. *)
let sign_next_timer () =
  let path = Sign_next.timing_path () in
  (try Sign_next.mkdir_p (Filename.dirname path) with Sys_error _ -> ());
  Timing.create ~path ()

let sign_next ~timer ~relay ~auto =
  let ( let* ) = Result.bind in
  let time step f = Timing.time timer step f in
  let prompt =
    if Unix.isatty Unix.stdin then Some (Sign_next.read_hidden ?prompt:None)
    else None
  in
  match Sign_next.key_reader ~path:(Sign_next.config_path ()) ~prompt with
  | Error e -> exit_err e
  | Ok (config, read_key) -> (
      (* The two reads every later step needs, at once: GitHub's releases listing and the release
         channel. *)
      let listed, channel =
        time "list-and-channel" (fun () ->
            Parallel.both
              (fun () ->
                time "releases-list" (fun () ->
                    gh [ "api"; Sign_next.releases_path config.repo ]))
              (fun () ->
                time "channel" (fun () ->
                    Feed.read Feed.default_fetch ~base:Feed.default_url
                      ~installed:(Trust_root.version ()))))
      in
      time "out-of-date" (fun () -> out_of_date ~listed ~channel);
      let signers = time "signers" (fun () -> current_signers ~channel) in
      let ask q =
        if auto then Sign_next.answer_sign ~say:print_endline q
        else (
          print_string q;
          flush stdout;
          Option.value (In_channel.input_line stdin) ~default:"")
      in
      let tmp = Filename.temp_dir "digestif-sign" "" in
      match
        let* listed = listed in
        Sign_next.run ~gh ~git:sign_git
          ~clone:(Sign_next.clone_path config.repo)
          ~signers ~config ~read_key ~ask ~say:print_endline ~tmp
          ~relay:(relay config) ~timer
          ~cache:
            (Attestation.file_cache
               (Filename.concat (Sign_next.state_dir ()) "attested.json"))
          ~listed ()
      with
      | Ok () -> 0
      | Error e -> exit_err e)

(* A take-back (a recall, a revocation, a signer-set change) is a signer's own act and needs nothing
   of the fleet: the signer's key, their own `gh` login to commit it to the channel, and, on a
   machine running a node, that node to post it on the circle. *)

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

(* The channel's two addresses (docs/releases.md, The channel): release/ on main, which every node
   from the first main-reading version reads, and the root of the `channel` branch, which an older
   node reads until it updates. *)
let channel_dir = "release"
let channel_branch = "channel"

(* Clone [repo]'s [branch] shallow into [checkout]; for main, sparse and without blobs outside
   release/, so the clone costs the channel and not the code. *)
let clone_address ~repo ~branch checkout =
  let url = "https://github.com/" ^ repo ^ ".git" in
  if branch = "main" then
    let ( let* ) = Result.bind in
    let* () =
      git
        [
          "clone";
          "--quiet";
          "--depth";
          "1";
          "--filter=blob:none";
          "--sparse";
          "--branch";
          branch;
          url;
          checkout;
        ]
    in
    git ~cwd:checkout [ "sparse-checkout"; "set"; channel_dir ]
  else
    git
      [ "clone"; "--quiet"; "--depth"; "1"; "--branch"; branch; url; checkout ]

(* Commit and push what the checkout at [checkout] holds changed, as one commit on [branch]. Answers
   whether it pushed a commit; Error when the push lost a race or failed. *)
let push_if_changed ~branch ~message checkout =
  let ( let* ) = Result.bind in
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
      Error (Printf.sprintf "git diff exited %d: %s" code (String.trim stderr))
  | Error e -> Error e

(* THE ONE CHANNEL WRITER: [write] is handed the channel directory of a fresh clone of each address,
   release/ of main and the branch's root, and what it writes is pushed as one commit to each that
   it changed. A push that loses a race (main or the branch moved since the clone) starts again from
   new clones, where the address already pushed takes no second commit since the write finds it
   done. Answers what [write] answered and whether any address took a commit. *)
let commit_to_channel ~repo ~message write =
  let ( let* ) = Result.bind in
  let rec attempt n =
    let dir = Filename.temp_dir "digestif-channel" "" in
    let result =
      Fun.protect
        ~finally:(fun () -> try Stage.remove_tree dir with _ -> ())
        (fun () ->
          let main = Filename.concat dir "main" in
          let branch = Filename.concat dir channel_branch in
          let* () = clone_address ~repo ~branch:"main" main in
          let* () = clone_address ~repo ~branch:channel_branch branch in
          let release = Filename.concat main channel_dir in
          let* written = write ~main:release ~branch in
          let on_main = push_if_changed ~branch:"main" ~message main in
          let on_branch =
            push_if_changed ~branch:channel_branch ~message branch
          in
          match (on_main, on_branch) with
          | Ok a, Ok b -> Ok (`Done (written, a || b))
          | Error e, _ | _, Error e -> Ok (`Again e))
    in
    match result with
    | Error e -> Error e
    | Ok (`Done d) -> Ok d
    | Ok (`Again e) when n >= 3 ->
        Error ("could not push to the channel after 3 attempts: " ^ e)
    | Ok (`Again _) -> attempt (n + 1)
  in
  attempt 1

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

(* sign --next's first write (docs/releases.md, The channel): every signer-set change this machine's
   node holds and the channel lacks, committed under signers/ to both of the channel's addresses with
   the signer's own gh login before any version is signed, so the channel and ci/release.sh hold the
   set the next release is signed by. A failure is said and signing goes on: a version signed by the
   new set still waits in the draft until the channel holds it. *)
let publish_signer_sets ~timer () =
  match held_signer_sets () with
  | [] -> ()
  | held -> (
      let repo =
        match Sign_next.load_config (Sign_next.config_path ()) with
        | Ok c -> c.repo
        | Error _ -> Sign_next.default_repo
      in
      match
        Timing.time timer "publish-signer-sets push" (fun () ->
            commit_to_channel ~repo ~message:"Publish the signer set"
              (fun ~main ~branch ->
                let ( let* ) = Result.bind in
                let* on_main = Signers_channel.write_sets ~dir:main held in
                let* on_branch = Signers_channel.write_sets ~dir:branch held in
                Ok
                  (on_main
                  @ List.filter
                      (fun s ->
                        not
                          (List.exists
                             (fun m ->
                               Signers_channel.document_path m
                               = Signers_channel.document_path s)
                             on_main))
                      on_branch)))
      with
      | Ok (written, true) ->
          List.iter
            (fun s ->
              Printf.printf "published the signer set %s on %s's channel\n"
                (Signers_channel.document_path s)
                repo)
            written
      | Ok (_, false) -> ()
      | Error e ->
          Printf.printf
            "the signer set this node holds was not published to the channel: %s\n"
            e)

(* This machine's node, when one runs here: what the relay line reads every relay's version with,
   and what posts the announcement. *)
let with_node ~data_dir f =
  if Sys.file_exists (Filename.concat data_dir "log.sqlite3") then
    let node = Node.open_ data_dir in
    Fun.protect ~finally:(fun () -> Node.close node) (fun () -> Some (f node))
  else None

(* Every relay's version as this machine's node last read it: what its sync records in the
   relay_versions table (Digestif_relay_deploy.Lag), read without asking any relay. *)
let relay_versions ~data_dir () =
  with_node ~data_dir (fun node ->
      List.map
        (fun (r : Log.relay_row) ->
          ( r.url,
            match Digestif_relay_deploy.Lag.reported node.log r.url with
            | Some v -> Ok v
            | None -> Error "the node has not recorded its version yet" ))
        (Log.relays node.log))

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

(* The channel on [repo], as a node reads it: release/ on main. *)
let channel_url ~repo =
  Printf.sprintf "https://raw.githubusercontent.com/%s/main/%s/" repo
    channel_dir

(* What relay-publish checks a relay release against: the trust a node reading the channel holds,
   the build's set advanced by the channel's signers/ and this machine's node with the channel's
   revocations applied (Signers_channel.trust), the set sign --next signs under. *)
let relay_publish_trust ~repo () =
  Result.map
    (fun feed ->
      Signers_channel.trust ~build:(Trust_root.signers ()) ~channel:(Some feed)
        ~held:(held_signer_sets ()))
    (Feed.read Feed.default_fetch ~base:(channel_url ~repo)
       ~installed:(Trust_root.version ()))

let relay_publish_env ?(timer = Timing.none) ~repo ~data_dir () :
    Relay_publish.env =
  {
    gh;
    repo;
    trust = relay_publish_trust ~repo;
    announce = relay_announce ~data_dir;
    say = print_endline;
    timer;
  }

(* sign --next's relay line: the node at the default data directory, and relay-publish when a
   signature completes the signer set. A held announcement is said and is not a failure of the
   signing. *)
let sign_next_relay ~timer (config : Sign_next.config) : Sign_next.relay =
  let data_dir = Node.default_dir () in
  {
    relay_versions = relay_versions ~data_dir;
    publish =
      (fun ~manifest version ->
        Result.map_error Relay_publish.error_to_string
          (Result.map ignore
             (Relay_publish.run ~manifest
                (relay_publish_env ~timer ~repo:config.repo ~data_dir ())
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
  let auto =
    Arg.(
      value & flag
      & info [ "sign" ]
          ~doc:
            "With --next, sign every version offered without asking: \
             everything is still shown, and the question is answered s.")
  in
  let go key doc revocation next auto =
    match (next, key, doc) with
    | false, _, _ when auto -> exit_err "sign --sign goes with --next"
    | true, Some _, _ | true, _, Some _ ->
        exit_err
          "sign --next takes no --key or DOCUMENT: it reads the key from the \
           command ~/.config/digestif/signer.json names, else asks you to \
           paste it at a hidden prompt"
    | true, None, None ->
        let timer = sign_next_timer () in
        Timing.time timer "publish-signer-sets" (publish_signer_sets ~timer);
        let code = sign_next ~timer ~relay:(sign_next_relay ~timer) ~auto in
        Timing.mark timer "total";
        code
    | false, None, _ -> exit_err "sign needs --key SECRET_FILE"
    | false, _, None -> exit_err "sign needs the DOCUMENT to sign"
    | false, Some key, Some doc -> sign_document ~key ~doc ~revocation
  in
  Cmd.v
    (Cmd.info "sign" ~doc:"Add your signature beside a manifest or revocation.")
    Term.(const go $ key $ doc $ revocation $ next $ auto)

(* The release key a recall or a revocation is signed with, and the channel's repository: --key's
   file, else the command signer.json names, which runs only once the arguments parse. *)
let takeback_signer key repo =
  let ( let* ) = Result.bind in
  match key with
  | Some path ->
      let* secret = Keys.decode_secret (read path) in
      Ok (secret, Option.value repo ~default:Sign_next.default_repo)
  | None ->
      let* config = Sign_next.load_config (Sign_next.config_path ()) in
      let* secret = Sign_next.secret config in
      Ok (secret, Option.value repo ~default:config.repo)

let takeback_key_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "key" ] ~docv:"SECRET_FILE"
        ~doc:
          "Your release key, as for sign: /dev/stdin to pipe it in. Without it \
           the key is read from the command ~/.config/digestif/signer.json \
           names, as sign --next reads it.")

let takeback_channel_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "channel" ] ~docv:"DIR"
        ~doc:
          "Write into this checkout of the channel and commit nothing, instead \
           of committing to release/ on main and to the channel branch.")

let takeback_repo_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "repo" ] ~docv:"OWNER/NAME"
        ~doc:
          "The repository holding the channel: signer.json's \"repo\" when the \
           key is read from it, else digestif-ai/digestif.")

(* Write a take-back with [write], into --channel's checkout or to both of the channel's addresses
   in one commit each. *)
let write_takeback ~channel ~repo ~message write =
  match channel with
  | Some dir -> write [ dir ]
  | None ->
      Result.map fst
        (commit_to_channel ~repo ~message (fun ~main ~branch ->
             write [ main; branch ]))

let where ~channel ~repo =
  match channel with
  | Some d -> d
  | None ->
      Printf.sprintf "%s's channel (release/ on main and the %s branch)" repo
        channel_branch

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
  let data_dir =
    Arg.(
      value
      & opt string (Node.default_dir ())
      & info [ "data-dir" ] ~docv:"DIR"
          ~doc:"The node that posts the recall on the circle.")
  in
  let go version reason key channel repo data_dir =
    match
      Result.bind (Version.of_string version) (fun version ->
          Result.map (fun s -> (version, s)) (takeback_signer key repo))
    with
    | Error e -> exit_err e
    | Ok (version, (secret, repo)) -> (
        let message =
          Printf.sprintf "Recall %s: %s" (Version.to_string version) reason
        in
        match
          write_takeback ~channel ~repo ~message (fun dirs ->
              Recall_channel.write_recalls ~dirs ~secret ~version ~reason
                ~recalled_at:(Time_fmt.now ()))
        with
        | Error e -> exit_err e
        | Ok w ->
            let v = Version.to_string version in
            if w.first then
              Printf.printf "recalled %s in %s\n" v (where ~channel ~repo)
            else
              Printf.printf "signed the recall of %s already in %s\n" v
                (where ~channel ~repo);
            if (not w.first) && w.recall.doc.reason <> reason then
              Printf.printf "the recall's reason stays the first signer's: %s\n"
                w.recall.doc.reason;
            post_to_circle ~data_dir w.recall;
            0)
  in
  Cmd.v
    (Cmd.info "recall" ~doc:"Recall a published version with your key alone.")
    Term.(
      const go $ version $ reason $ takeback_key_arg $ takeback_channel_arg
      $ takeback_repo_arg $ data_dir)

(* A revocation of a release key (docs/releases.md, Revoking a release key): any one signer's
   signed statement, written to the channel's two addresses by their own gh login as a recall is,
   and printed as the release_revocation body that carries it on the circle (circle-body's). *)
let revoke_cmd =
  let revoked =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"KEY" ~doc:"The release key revoked, ed25519:...")
  in
  let reason =
    Arg.(
      required
      & opt (some string) None
      & info [ "reason" ] ~docv:"TEXT" ~doc:"Why the key is revoked.")
  in
  let go revoked reason key channel repo =
    match takeback_signer key repo with
    | Error e -> exit_err e
    | Ok (secret, repo) -> (
        let message = Printf.sprintf "Revoke %s: %s" revoked reason in
        match
          write_takeback ~channel ~repo ~message (fun dirs ->
              Revocation_channel.write_revocations ~dirs ~secret ~key:revoked
                ~reason ~revoked_at:(Time_fmt.now ()))
        with
        | Error e -> exit_err e
        | Ok w ->
            if w.first then
              Printf.printf "revoked %s in %s\n" revoked (where ~channel ~repo)
            else
              Printf.printf "signed the revocation of %s already in %s\n"
                revoked (where ~channel ~repo);
            print_endline "post it on the circle from a machine running a node:";
            Printf.printf
              "  printf '%%s' '%s' | digestif post --kind %s --body -\n"
              (Yojson.Safe.to_string (Circle_revocation.to_body w.revocation))
              Circle_revocation.kind;
            0)
  in
  Cmd.v
    (Cmd.info "revoke"
       ~doc:"Revoke a release key with your key alone, in the channel.")
    Term.(
      const go $ revoked $ reason $ takeback_key_arg $ takeback_channel_arg
      $ takeback_repo_arg)

(* Whether a manifest carries every signature a node needs, checked with a node's own Policy.check
   against the signer set this binary was built with (docs/releases.md, The channel). It is what
   `ci/release.sh candidate` runs before a version reaches a test node, and every node checks again
   with the set it holds. Revocations are not read: a revoked signer still halts every node.

   A relay manifest (digestif-relay-release-v1) is checked the same way, over its own domain line,
   with Policy.check_relay: the rule a node's fold of a relay_release announcement applies.

   With [channel], the set is the one the channel's signers/ chain leaves, each change checked
   against the set before it from the build's own (Policy.adopt_sets), exactly as a node reading
   that channel reaches it: what `ci/release.sh` checks a version against once the admins changed
   the set. *)
let verify_signatures ~manifest ~sig_files ~signers ~channel ~version ~out =
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
    let* set =
      match channel with
      | None -> Ok set
      | Some base ->
          let* feed =
            Feed.read Feed.default_fetch ~base
              ~installed:(Trust_root.version ())
          in
          let a =
            Policy.adopt_sets
              { signers = set; revoked = [] }
              ~revocations:feed.revocations feed.signer_sets
          in
          Ok a.adopted_trust.signers
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
        | `Node _ -> ([], Release.release_domain)
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
      let kept =
        Release.verified_signatures ~domain
          ~wanted:(fun k ->
            List.exists (fun (w : Release.signer) -> w.key = k) wanted)
          bytes sigs
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
  let channel =
    Arg.(
      value
      & opt (some string) None
      & info [ "channel" ] ~docv:"BASE"
          ~doc:
            "A release channel (a URL or a directory laid out as release/ on \
             main) whose signers/ changes the set is advanced by, each checked \
             against the set before it.")
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
  let go manifest sig_files signers channel version out =
    verify_signatures ~manifest ~sig_files ~signers ~channel ~version ~out
  in
  Cmd.v
    (Cmd.info "verify"
       ~doc:
         "Print which signers signed a manifest, one 'signed NAME' or 'missing \
          NAME' line each; exit 0 only when a node would accept the \
          signatures.")
    Term.(const go $ manifest $ sig_files $ signers $ channel $ version $ out)

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
    | Ok version, Ok shipped -> (
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
              {
                Release.platform;
                url = base ^ Filename.basename file;
                sha256 = Keys.hash_of_bytes b;
                size = String.length b;
              }
            in
            print_string
              (Release.manifest_to_string
                 {
                   version;
                   published_at;
                   notes;
                   artifacts = List.map artifact artifacts;
                 });
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
  let data_dir =
    Arg.(
      value
      & opt string (Node.default_dir ())
      & info [ "data-dir" ] ~docv:"DIR"
          ~doc:"The node that posts the announcement on the circle.")
  in
  let go version repo data_dir =
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
          Relay_publish.run (relay_publish_env ~repo ~data_dir ()) ~version
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
    Term.(const go $ version $ repo $ data_dir)

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
        | Error (Stage.Retry e | Stage.Suspect e | Stage.Refuse e) ->
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

(* Approvals (docs/protocol.md, approval): an admin signs an invite or a signer-set change with the
   release key `sign --next` reads, and hands the signature to the local node, which never holds
   the key. *)

let ask q =
  print_string q;
  flush stdout;
  Option.value (In_channel.input_line stdin) ~default:""

let on_node ?(data_dir = Node.default_dir ()) f =
  match Approve.with_node ~transport:Relay_client.curl ~data_dir f with
  | Ok () -> 0
  | Error e -> exit_err e

(* The circle approve acts in: --circle ID, the folder under ~/digestif, else the default node. *)
let approve_circle =
  Arg.(
    value
    & opt (some string) None
    & info [ "circle" ] ~docv:"ID"
        ~doc:
          "The circle whose approval to sign: its id under ~/digestif \
           (digestif circle list names each). Defaults to the default node.")

let circle_dir = function
  | None -> Ok (Node.default_dir ())
  | Some id -> Circles.dir id

(* The circle's own admin key, which digestif circle found made and keeps in the keystore beside the
   circle's device key: an admin signs that circle's admissions with it, no phrase and no signer.json
   needed (docs/design.md, Admins of each circle). *)
let circle_admin_key data_dir =
  match Keystore.get_signing_key (Keystore.default ~scope:data_dir) "admin" with
  | Ok (Some k) -> Some k
  | _ -> None

(* The release key, read the way sign --next reads it (Sign_next.key_reader): the command
   signer.json names, else a hidden prompt on a terminal; into memory only. A key that is not
   signer.json's public_key signs nothing. *)
let checked_secret (config : Sign_next.config) read_key =
  let ( let* ) = Result.bind in
  let* secret =
    Result.map_error
      (Sign_next.key_unread config)
      (Result.bind (read_key ()) Keys.decode_secret)
  in
  match config.public_key with
  | Some named when named <> Keys.public secret ->
      Error
        (Printf.sprintf
           "your key is %s but signer.json's public_key is %s; nothing was \
            signed. Write your key's public half there."
           (Keys.public secret) named)
  | _ -> Ok secret

(* Who approve acts as, and how it reads the key: signer.json's public_key, the key read only once
   the signer answers y, as sign --next reads it only after s. Without a public_key the key itself
   is the only way to know, so it is read first. *)
let approver () =
  let prompt =
    if Unix.isatty Unix.stdin then Some (Sign_next.read_hidden ?prompt:None)
    else None
  in
  let ( let* ) = Result.bind in
  let* config, read_key =
    Sign_next.key_reader ~path:(Sign_next.config_path ()) ~prompt
  in
  match config.public_key with
  | Some me -> Ok (me, fun () -> checked_secret config read_key)
  | None ->
      let* secret = checked_secret config read_key in
      Ok (Keys.public secret, fun () -> Ok secret)

let approve_cmd =
  let id = Arg.(value & pos 0 (some string) None & info [] ~docv:"APPROVAL") in
  let go circle id =
    match circle_dir circle with
    | Error e -> exit_err e
    | Ok data_dir -> (
        let approver =
          match circle_admin_key data_dir with
          | Some k -> Ok (Keys.public k, fun () -> Ok k)
          | None -> approver ()
        in
        match approver with
        | Error e -> exit_err e
        | Ok (me, read_secret) ->
            on_node ~data_dir (fun api ->
                match id with
                | None -> Approve.list ~api ~me ~say:print_endline
                | Some id ->
                    Approve.sign_as ~api ~me ~read_secret ~ask
                      ~say:print_endline id))
  in
  Cmd.v
    (Cmd.info "approve"
       ~doc:
         "Sign APPROVAL with your admin key and hand the signature to this \
          machine's node; with no APPROVAL, list the approvals waiting on your \
          key. The key is the circle's own admin key when its folder's \
          keystore holds one (digestif circle found made it), else your \
          release key, read only once you answer y.")
    Term.(const go $ approve_circle $ id)

let remove_cmd =
  let identity =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"IDENTITY"
          ~doc:
            "The member's identity key, as their member page and the review \
             item show it.")
  in
  let go circle identity =
    match circle_dir circle with
    | Error e -> exit_err e
    | Ok data_dir -> (
        let remover =
          match circle_admin_key data_dir with
          | Some k -> Ok (Keys.public k, fun () -> Ok k)
          | None -> approver ()
        in
        match remover with
        | Error e -> exit_err e
        | Ok (me, read_secret) ->
            on_node ~data_dir (fun api ->
                Remove.remove_as ~api ~me ~read_secret ~ask ~say:print_endline
                  identity))
  in
  Cmd.v
    (Cmd.info "remove"
       ~doc:
         "Remove the member IDENTITY from the circle: a revoke signed with \
          your admin key, posted by this machine's node. A member who still \
          holds an admin key is refused: a removal approval takes that key out \
          first. The key is read as $(b,digestif-update approve) reads it, \
          only once you answer y.")
    Term.(const go $ approve_circle $ identity)

let signers_propose_cmd =
  let replace =
    Arg.(
      required
      & opt (some string) None
      & info [ "replace" ] ~docv:"OLD" ~doc:"The release key to take out.")
  in
  let with_ =
    Arg.(
      required
      & opt (some string) None
      & info [ "with" ] ~docv:"NEW" ~doc:"The release key to put in its place.")
  in
  let go old new_ =
    on_node (fun api ->
        Approve.propose_replacement ~api ~say:print_endline ~old ~new_)
  in
  Cmd.v
    (Cmd.info "propose"
       ~doc:
         "Start a replacement of your own release key OLD by NEW through this \
          machine's node; NEW signs first with $(b,digestif-update approve).")
    Term.(const go $ replace $ with_)

let signers_cmd =
  Cmd.group
    (Cmd.info "signers" ~doc:"Change the release signer set by approval.")
    [ signers_propose_cmd ]

(* THE SIGNING JOB (docs/releases.md, The signing job): `signer install` pins this digestif-update
   and installs the launchd agent that runs the pinned copy's `signer run`. *)

let now_stamp () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.tm_year + 1900)
    (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min t.tm_sec

(* A line of the job's log, stamped, written at once. *)
let say_stamped line =
  print_endline (now_stamp () ^ " " ^ line);
  flush stdout

(* The set a signature is checked against now, as sign --next reads it. *)
let signers_now () =
  current_signers
    ~channel:
      (Feed.read Feed.default_fetch ~base:Feed.default_url
         ~installed:(Trust_root.version ()))

(* signer.json when the signer wrote one (its repo and public_key), else the default repository.
   The job never runs its key_command: the key comes from the Keychain. *)
let job_config () =
  let path = Sign_next.config_path () in
  if Sys.file_exists path then Sign_next.load_config path
  else Ok Sign_next.pasted

let keychain_value service =
  Result.map_error
    (Keychain.read_error_to_string service)
    (Keychain.read service)

let signer_run ~api ~once =
  let ( let* ) = Result.bind in
  match
    let* config = job_config () in
    let* token =
      Result.bind
        (keychain_value Keychain.signer_token_service)
        Signing_job.check_token
    in
    let read_key () = keychain_value Keychain.release_key_service in
    (* The key is read once at start, so a job that cannot read it says so at once, and its public
       half names whose signature a draft already carries. *)
    let* printed = read_key () in
    let* _, pub = Signing_job.check_key ~signers:(signers_now ()) printed in
    let* () =
      match config.public_key with
      | Some named when named <> pub ->
          Error
            (Printf.sprintf
               "the Keychain's release key is %s but signer.json's public_key \
                is %s"
               pub named)
      | _ -> Ok ()
    in
    let config = { config with public_key = Some pub } in
    say_stamped
      (Printf.sprintf
         "The signing job reads %s's decisions as %s, signing on %s." api pub
         config.repo);
    let env () =
      {
        Signing_job.gh;
        git = sign_git;
        clone = Sign_next.clone_path config.repo;
        signers = signers_now ();
        config;
        read_key;
        tmp = Filename.temp_dir "digestif-signer" "";
        relay = sign_next_relay ~timer:Timing.none config;
        cache =
          Attestation.file_cache
            (Filename.concat (Sign_next.state_dir ()) "attested.json");
        say = say_stamped;
      }
    in
    let act ~settled decisions =
      if Signing_job.to_sign ~settled decisions = [] then []
      else Signing_job.act (env ()) ~settled decisions
    in
    Signing_job.run
      ~fetch:(Signing_job.fetch ~http:Signing_job.curl ~api ~token)
      ~act ~sleep:Unix.sleepf ~say:say_stamped
      ?rounds:(if once then Some 1 else None)
      ()
  with
  | Ok () -> 0
  | Error e ->
      say_stamped ("digestif-update signer run: " ^ e);
      1

let copy_file ~src ~dst =
  let bytes = In_channel.with_open_bin src In_channel.input_all in
  let tmp = dst ^ ".partial" in
  (try Sys.remove tmp with Sys_error _ -> ());
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    0o755 tmp (fun oc -> Out_channel.output_string oc bytes);
  Unix.chmod tmp 0o555;
  Unix.rename tmp dst

let launchctl args =
  match Proc.run ~timeout:60. (Array.of_list ("launchctl" :: args)) with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "launchctl %s exited %d: %s" (String.concat " " args)
           code (String.trim stderr))
  | Error e -> Error ("launchctl: " ^ e)

let signer_install () =
  let ( let* ) = Result.bind in
  let self =
    try Unix.realpath Sys.executable_name
    with Unix.Unix_error _ -> Sys.executable_name
  in
  let version = Version.to_string (Trust_root.version ()) in
  match
    let* () =
      match Platform.current () with
      | Ok p when String.starts_with ~prefix:"darwin-" p -> Ok ()
      | _ ->
          Error
            "the signing job runs on a Mac: it reads the key from the login \
             Keychain"
    in
    let* () =
      if Out_of_date.in_a_node Sys.executable_name && version <> "0.0.0" then
        Ok ()
      else
        Error
          "signer install pins a published digestif-update: run it as the one \
           your node holds, ~/.local/bin/digestif-update signer install"
    in
    let pinned = Signing_job.pinned_path ~version in
    Sign_next.mkdir_p (Signing_job.signer_dir ());
    if not (Sys.file_exists pinned) then copy_file ~src:self ~dst:pinned;
    let signers = signers_now () in
    let* key =
      if Keychain.holds Keychain.release_key_service then Ok ""
      else
        let* pasted = Sign_next.read_hidden () in
        let* key, _ = Signing_job.check_key ~signers pasted in
        Ok key
    in
    let* token =
      let has = Keychain.holds Keychain.signer_token_service in
      let prompt =
        if has then
          "Paste your signer token, or press Enter to keep the one in the \
           Keychain: "
        else "Paste your signer token (it is not shown): "
      in
      let* pasted =
        match Sign_next.read_hidden ~prompt () with
        | Error _ when has -> Ok ""
        | r -> r
      in
      if String.trim pasted = "" then
        if has then Ok "" else Error "no signer token was pasted"
      else Signing_job.check_token pasted
    in
    print_endline
      "The pinned copy now takes the key and the token into the Keychain. If \
       the Keychain asks, answer Allow, never Always Allow.";
    let* () =
      match
        Proc.run ~timeout:900.
          ~stdin:(Signing_job.handover_to_string { Signing_job.key; token })
          [| pinned; "signer"; "adopt" |]
      with
      | Ok { code = 0; stdout; _ } ->
          print_string stdout;
          Ok ()
      | Ok { stdout; stderr; _ } ->
          print_string stdout;
          Error (String.trim stderr)
      | Error e -> Error e
    in
    let path = Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin" in
    let plist = Signing_job.plist_path () in
    Sign_next.mkdir_p (Filename.dirname plist);
    Out_channel.with_open_bin plist (fun oc ->
        Out_channel.output_string oc
          (Signing_job.plist ~pinned ~path ~log:(Signing_job.log_path ())));
    let domain = Printf.sprintf "gui/%d" (Unix.getuid ()) in
    ignore (launchctl [ "bootout"; domain ^ "/" ^ Signing_job.label ]);
    let* () = launchctl [ "bootstrap"; domain; plist ] in
    (* Older pinned copies: the Keychain no longer trusts them, and nothing runs them. *)
    Array.iter
      (fun n ->
        let p = Filename.concat (Signing_job.signer_dir ()) n in
        if
          String.starts_with ~prefix:"digestif-update-" n
          && p <> pinned
          && not (Filename.check_suffix n ".partial")
        then try Sys.remove p with Sys_error _ -> ())
      (Sys.readdir (Signing_job.signer_dir ()));
    Printf.printf "The signing job runs %s signer run as %s; its log is %s.\n"
      pinned Signing_job.label (Signing_job.log_path ());
    List.iter
      (fun job ->
        Printf.printf
          "%s runs sign --next on its own; the signing job replaces it: \
           launchctl bootout %s/%s\n"
          job domain job)
      (Signing_job.sign_on_assignment_jobs ~dir:(Filename.dirname plist));
    Ok ()
  with
  | Ok () -> 0
  | Error e -> exit_err ("signer install: " ^ e)

(* signer adopt, run by signer install as the pinned copy: the key and the token, each the value
   handed over on stdin or the one already in the Keychain, written back as items this binary
   created, so their access lists trust it alone, then read back silently. *)
let signer_adopt () =
  let ( let* ) = Result.bind in
  let self =
    try Unix.realpath Sys.executable_name
    with Unix.Unix_error _ -> Sys.executable_name
  in
  match
    let* () =
      if Filename.dirname self = Signing_job.signer_dir () then Ok ()
      else Error "signer adopt is run by signer install, as the pinned copy"
    in
    let* h = Signing_job.handover_of_string (In_channel.input_all stdin) in
    let account = Option.value (Sys.getenv_opt "USER") ~default:"digestif" in
    let* pub = Signing_job.adopt ~signers:(signers_now ()) ~account h in
    Printf.printf
      "The Keychain's %s and %s items now trust %s alone (key %s).\n"
      Keychain.release_key_service Keychain.signer_token_service self pub;
    Ok ()
  with
  | Ok () -> 0
  | Error e -> exit_err ("signer adopt: " ^ e)

let signer_cmd =
  let install =
    Cmd.v
      (Cmd.info "install"
         ~doc:
           "Pin this digestif-update as the signing job, give it the release \
            key and the signer token in the Keychain, and install its launchd \
            agent (docs/releases.md, The signing job).")
      Term.(const signer_install $ const ())
  in
  let run =
    let api =
      Arg.(
        value
        & opt string Signing_job.default_api
        & info [ "api" ] ~docv:"URL" ~doc:"Where idempotent's API answers.")
    in
    let once =
      Arg.(
        value & flag
        & info [ "once" ]
            ~doc:"Read the open decisions once, act on them, and stop.")
    in
    Cmd.v
      (Cmd.info "run"
         ~doc:
           "The signing job: hold the decision stream open and sign exactly \
            what a decision approved, after the integrity check.")
      Term.(const (fun api once -> signer_run ~api ~once) $ api $ once)
  in
  let adopt =
    Cmd.v
      (Cmd.info "adopt" ~doc:"Run by signer install as the pinned copy.")
      Term.(const signer_adopt $ const ())
  in
  Cmd.group
    (Cmd.info "signer" ~doc:"The signing job on a signer's Mac.")
    [ install; run; adopt ]

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
             revoke_cmd;
             verify_cmd;
             hash_cmd;
             bundle_cmd;
             manifest_cmd;
             relay_manifest_cmd;
             relay_publish_cmd;
             stage_test_cmd;
             circle_body_cmd;
             circle_receive_cmd;
             approve_cmd;
             remove_cmd;
             signers_cmd;
             signer_cmd;
           ])
    with Sys_error e -> exit_err e
