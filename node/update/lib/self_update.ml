(* `sign --next` KEEPS A HELD BINARY CURRENT (docs/releases.md, Signing a release). A signer signs
   with the digestif-update on PATH, a link to their node's good release that the node's updater
   moves (Cli_links); a digestif-update-<platform> held outside any node is the one file this
   module replaces. When the newest node release that is not a draft is newer than the running
   binary, that release's digestif-update is fetched, checked against the signatures both signers put on its manifest (the signer set the
   running binary trusts, as a node checks a release), written over the running file, and run again
   with the same arguments. The draft being judged never supplies the binary that judges it: only a
   release that is no longer a draft is ever taken.

   The binary comes out of the release's archive for the platform, whose sha256 the signed manifest
   names; the draft's digestif-update-<platform> asset is the same file (ci/release-artifact.sh) but
   no signature covers it on its own.

   The release channel a node reads (Feed) decides which published versions count: a version a
   signer recalled is never taken, and a revocation applies to the signer set the manifest is
   checked against, as both do on a node. An update that fails for any reason (GitHub, the channel,
   a refused release, the disk) changes nothing and the run goes on with the running binary, which
   is still the one the signer trusted a moment ago: an update is never a reason not to sign. *)

let ( let* ) = Result.bind

(* Set on the run this one execs into, naming the version it replaced, so the new binary says what
   happened and never updates a second time in one command. *)
let updated_env = "DIGESTIF_SIGN_UPDATED_FROM"

(* The file name a held binary has: the release asset's, digestif-update-<platform>. Only a file of
   that name is replaced; a node's own <data dir>/good/bin/digestif-update sits in a release
   directory nothing changes, and the node's updater moves it. *)
let held_name platform = "digestif-update-" ^ platform

type decision =
  | Current  (** Nothing published is newer than the running binary. *)
  | Untagged
      (** The running binary is a build of no tag (0.0.0), a developer's own: it
          is never replaced. *)
  | Not_held of Sign_next.draft
      (** A newer release exists but the running file is not a held binary. *)
  | Newer of Sign_next.draft
      (** Replace the running binary with this release's. *)

let untagged = { Version.major = 0; minor = 0; patch = 0 }

(* The recall of [r] that counts under [trust], as a node reads it (Policy.recall_of). *)
let recall_of ~trust ~recalls (r : Sign_next.draft) =
  Policy.recall_of trust recalls r.version

(* What to do, from the node releases GitHub lists, the running binary's version, and the running
   file's name: the newest release that is not a draft and that no counting recall names. *)
let decide ~trust ~recalls ~running ~self ~platform
    (releases : Sign_next.draft list) =
  match
    Sign_next.newest
      (List.filter
         (fun (r : Sign_next.draft) ->
           (not r.draft) && recall_of ~trust ~recalls r = None)
         releases)
  with
  | None -> Current
  | Some p when Version.compare p.version running <= 0 -> Current
  | Some _ when Version.equal running untagged -> Untagged
  | Some p when Filename.basename self <> held_name platform -> Not_held p
  | Some p -> Newer p

let asset_named (r : Sign_next.draft) name =
  match List.find_opt (fun (a : Sign_next.asset) -> a.name = name) r.assets with
  | Some a -> Ok a
  | None -> Error (Printf.sprintf "%s holds no %s" r.tag name)

(* The release's manifest with every signature asset beside it, checked as a node checks one:
   every signer in [trust] signed it and none of them is revoked (Policy.check). *)
let verified_manifest ~gh ~repo ~trust (r : Sign_next.draft) =
  let* bytes, manifest = Sign_next.node_manifest ~gh ~repo r in
  let* signatures =
    Release.all
      (fun (a : Sign_next.asset) ->
        let* b = Sign_next.download_asset ~gh ~repo a in
        Result.map_error
          (fun e -> Printf.sprintf "%s's %s: %s" r.tag a.name e)
          (Release.signatures_of_string b))
      (List.filter
         (fun (a : Sign_next.asset) -> Sign_next.is_signature_asset a.name)
         r.assets)
  in
  match
    Policy.check trust
      { Release.bytes; doc = manifest; signatures = List.concat signatures }
  with
  | Ok _ -> Ok manifest
  | Error refusal ->
      Error
        (Printf.sprintf "%s's manifest is refused: %s" r.tag
           (Policy.refusal_to_string refusal))

(* The release's archive for [platform], refused unless its bytes are the sha256 and size the
   verified manifest names. *)
let verified_archive ~gh ~repo ~platform (r : Sign_next.draft)
    (manifest : Release.manifest) =
  let* artifact =
    match
      List.find_opt
        (fun (a : Release.artifact) -> a.platform = platform)
        manifest.artifacts
    with
    | Some a -> Ok a
    | None -> Error (Printf.sprintf "%s ships nothing for %s" r.tag platform)
  in
  let* asset = asset_named r (Filename.basename artifact.url) in
  let* bytes = Sign_next.download_asset ~gh ~repo asset in
  if Keys.hash_of_bytes bytes <> artifact.sha256 then
    Error
      (Printf.sprintf "%s's %s is %s, not the %s its signed manifest names"
         r.tag asset.name (Keys.hash_of_bytes bytes) artifact.sha256)
  else if String.length bytes <> artifact.size then
    Error
      (Printf.sprintf
         "%s's %s is %d bytes, not the %d its signed manifest names" r.tag
         asset.name (String.length bytes) artifact.size)
  else Ok bytes

let run_ok argv =
  match Proc.run ~timeout:120. argv with
  | Ok { code = 0; stdout; _ } -> Ok stdout
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "%s exited %d: %s" argv.(0) code (String.trim stderr))
  | Error e -> Error (argv.(0) ^ ": " ^ e)

(* bin/digestif-update out of the archive, unpacked under [tmp]. *)
let extract ~tmp archive =
  let file = Filename.concat tmp "digestif.tar.gz" in
  let dir = Filename.concat tmp "unpacked" in
  Sign_next.mkdir_p dir;
  Out_channel.with_open_bin file (fun oc ->
      Out_channel.output_string oc archive);
  let* _ = run_ok [| "tar"; "-xzf"; file; "-C"; dir; "bin/digestif-update" |] in
  let bin = Filename.concat dir "bin/digestif-update" in
  if Sys.file_exists bin then Ok bin
  else Error "the archive holds no bin/digestif-update"

(* The binary [r] ships for [platform], from its archive, every byte vouched for by both signers. *)
let fetch ~gh ~repo ~trust ~platform ~tmp (r : Sign_next.draft) =
  let* manifest = verified_manifest ~gh ~repo ~trust r in
  let* archive = verified_archive ~gh ~repo ~platform r manifest in
  extract ~tmp archive

(* Write [fresh] over [self]: copied beside it, made executable, cleared of macOS's quarantine,
   refused unless it reports [version], then renamed over [self] in one step, so an interrupted
   update leaves the old binary in place. *)
let install ~self ~fresh ~version =
  let next =
    Filename.concat (Filename.dirname self)
      ("." ^ Filename.basename self ^ ".next")
  in
  let* () =
    try
      let bytes = In_channel.with_open_bin fresh In_channel.input_all in
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o755 next
        (fun oc -> Out_channel.output_string oc bytes);
      Unix.chmod next 0o755;
      Ok ()
    with Sys_error e | Unix.Unix_error (_, _, e) ->
      Error ("could not write " ^ next ^ ": " ^ e)
  in
  if Sys.file_exists "/usr/bin/xattr" then
    ignore
      (Proc.run ~timeout:30.
         [| "/usr/bin/xattr"; "-d"; "com.apple.quarantine"; next |]);
  let want = Version.to_string version in
  let discard e =
    (try Sys.remove next with Sys_error _ -> ());
    Error e
  in
  match run_ok [| next; "--version" |] with
  | Error e -> discard ("the new digestif-update does not run: " ^ e)
  | Ok out when String.trim out <> want ->
      discard
        (Printf.sprintf "the new digestif-update reports %S, not %s"
           (String.trim out) want)
  | Ok _ -> (
      try
        Unix.rename next self;
        Ok ()
      with Unix.Unix_error (e, _, _) ->
        discard
          (Printf.sprintf "could not replace %s: %s" self (Unix.error_message e))
      )

(* The running file, every symlink and relative step resolved, so a binary started by a bare name
   or through a link writes its .next file beside the real file and renames over that, never in the
   current directory. *)
let resolve_self name = try Unix.realpath name with Unix.Unix_error _ -> name

(* Every newer published version a counting recall names, said so the signer knows why it is not
   taken. *)
let say_recalled ~trust ~recalls ~running ~say releases =
  List.iter
    (fun (r : Sign_next.draft) ->
      if (not r.draft) && Version.compare r.version running > 0 then
        match recall_of ~trust ~recalls r with
        | Some recall -> say (Policy.recalled_line recall ^ " It is not taken.")
        | None -> ())
    releases

(* The update itself: [Ok None] when nothing is to be done, [Ok (Some version)] once [self] holds
   [version]. Every error leaves [self] as it was. *)
let attempt ~gh ~repo ~signers ~channel ~platform ~running ~self ~tmp ~say =
  let* listed = gh [ "api"; Sign_next.releases_path repo ] in
  let* releases = Sign_next.releases_of_string listed in
  let* (feed : Feed.t) =
    Result.map_error (fun e -> "the release channel: " ^ e) (channel ())
  in
  let trust =
    Policy.apply_revocations { Policy.signers; revoked = [] } feed.revocations
  in
  let recalls = feed.recalls in
  say_recalled ~trust ~recalls ~running ~say releases;
  match decide ~trust ~recalls ~running ~self ~platform releases with
  | Current -> Ok None
  | Untagged ->
      say
        "This digestif-update is a build of no release tag (0.0.0), so it is \
         not updated.";
      Ok None
  | Not_held p ->
      say
        (Printf.sprintf
           "%s is published and this digestif-update is %s; only a held %s \
            updates itself (docs/releases.md, Signing a release)."
           p.tag
           (Version.to_string running)
           (held_name platform));
      Ok None
  | Newer p ->
      say
        (Printf.sprintf
           "This digestif-update is %s and %s is published; updating %s to it \
            first."
           (Version.to_string running)
           p.tag self);
      let* fresh = fetch ~gh ~repo ~trust ~platform ~tmp p in
      let* () = install ~self ~fresh ~version:p.version in
      Ok (Some p.version)

(* The line an update that failed leaves: what failed, and that the run goes on unchanged. *)
let kept_line ~running e =
  Printf.sprintf
    "The update was refused, nothing changed: %s. Going on with this \
     digestif-update, %s."
    e
    (Version.to_string running)

(* What `sign --next` does before anything else: [None] to go on with the running binary, [Some
   version] once [self] holds [version] and the caller is to run it again. It never stops the run:
   an update that fails says why and goes on with the running binary. [updated] is the version a
   previous run of this command replaced, if it was one. [channel] reads the release channel nodes
   read (Feed.read). The scratch directory it downloads into is made under [tmp_root] (the system's
   temporary directory by default) and removed before it returns. *)
let run ?tmp_root ~gh ~repo ~signers ~channel ~platform ~running ~self ~updated
    ~say () =
  match updated with
  | Some from ->
      say
        (Printf.sprintf "Updated %s from %s to %s." self from
           (Version.to_string running));
      None
  | None -> (
      let outcome =
        match
          Filename.temp_dir ?temp_dir:tmp_root "digestif-self-update" ""
        with
        | exception Sys_error e -> Error ("no scratch directory: " ^ e)
        | tmp ->
            Fun.protect
              ~finally:(fun () -> try Stage.remove_tree tmp with _ -> ())
              (fun () ->
                try
                  attempt ~gh ~repo ~signers ~channel ~platform ~running ~self
                    ~tmp ~say
                with Sys_error e | Unix.Unix_error (_, _, e) | Failure e ->
                  Error e)
      in
      match outcome with
      | Ok v -> v
      | Error e ->
          say (kept_line ~running e);
          None)
