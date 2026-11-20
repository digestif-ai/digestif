(* `digestif-update sign --next` (docs/releases.md, Signing a release and Signing a relay release):
   sign the versions waiting for signatures, draft GitHub releases the Release workflow (the node
   line, v<version>) or the Relay release workflow (the relay line, relay-v<version>) left, the
   node line first: on each line the newest draft, and every older one the signer's signature
   would complete ({!offered}). Everything it reads and writes on GitHub goes through the signer's
   own `gh` login, passed in as [gh] so the flow is tested without the network. Whatever git holds
   (a tag's commit, commit titles, a file at a tag) is read from the tool's own clone of the
   repository through [git] ({!sync_clone}); GitHub is asked only for what git does not hold: the
   release listing, each draft's manifest.json and the signatures beside it, and those downloads
   are made at once ({!Parallel}), as is every version's show ({!shows_at_once}). The key is read only once the signer answers s, from the command
   they named in ~/.config/digestif/signer.json or at a hidden prompt, into memory only; a key that
   cannot be read ends the run there, nothing signed ({!check_key}), and a d or a leave never reads
   it. It uploads the signature as one asset of the draft, named for the key, so two signers never
   write one file. Every step's duration goes to the run's timing log ({!Timing}).

   `ci/release.sh signatures` reads those assets back and checks them with `digestif-update verify`. *)

let ( let* ) = Result.bind

(* ~/.config/digestif/signer.json *)

type config = {
  key_command : string;
      (** A shell command printing the signer's secret, e.g. `op read op://...`.
      *)
  repo : string;  (** owner/name of the repository the drafts are on. *)
  public_key : Keys.public_key option;
      (** The signer's own public key, the ed25519:... `keygen` prints: with it,
          `sign --next` leaves out every draft that already carries this key's
          signature before it shows anything ({!offered}). *)
}

let default_repo = "digestif-ai/digestif"

let config_path () =
  let base =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (Sys.getenv "HOME") ".config"
  in
  Filename.concat base "digestif/signer.json"

let config_example =
  {|{ "key_command": "op read 'op://Private/Digestif release key/password'" }|}

let config_of_string bytes =
  let* json = Release.parse_json "signer.json" bytes in
  let* key_command = Release.string_field "key_command" json in
  let* repo =
    match Release.field "repo" json with
    | None | Some `Null -> Ok default_repo
    | Some (`String r) when String.contains r '/' -> Ok r
    | Some _ -> Error "field \"repo\" must be owner/name"
  in
  let* public_key =
    match Release.field "public_key" json with
    | None | Some `Null -> Ok None
    | Some (`String k) ->
        Result.map_error
          (fun e -> "field \"public_key\": " ^ e)
          (Result.map Option.some (Keys.parse_ed25519 (String.trim k)))
    | Some _ -> Error "field \"public_key\" must be your ed25519:... public key"
  in
  if String.trim key_command = "" then
    Error "field \"key_command\" must name the command that prints your key"
  else Ok { key_command; repo; public_key }

let load_config path =
  if not (Sys.file_exists path) then
    Error
      (Printf.sprintf
         "%s does not exist; write the command that prints your release key \
          there once, e.g. %s"
         path config_example)
  else
    Result.map_error
      (fun e -> path ^ ": " ^ e)
      (config_of_string (In_channel.with_open_bin path In_channel.input_all))

(* The signer's secret, as the key command in [config] prints it: run under /bin/sh -c, read into
   memory, written nowhere. `sign --next` and `recall` both read the key this way. *)
let read_key (config : config) () =
  match Proc.run ~timeout:300. [| "/bin/sh"; "-c"; config.key_command |] with
  | Ok { code = 0; stdout; _ } when String.trim stdout <> "" -> Ok stdout
  | Ok { code = 0; _ } -> Error "the key command printed nothing"
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "the key command exited %d: %s" code
           (String.trim stderr))
  | Error e -> Error ("the key command: " ^ e)

(* THE KEY PASTED AT A HIDDEN PROMPT, for a signer with no signer.json: read from the terminal with
   its echo off, into memory, written nowhere. The prompt goes to stderr, so nothing of it mixes
   with what the command prints. A terminal that cannot turn its echo off is refused rather than
   shown the key. *)
let read_hidden ?(prompt = "Paste your release key (it is not shown): ") () =
  let fd = Unix.stdin in
  match Unix.tcgetattr fd with
  | exception Unix.Unix_error (e, _, _) ->
      Error ("the key prompt needs a terminal: " ^ Unix.error_message e)
  | saved -> (
      prerr_string prompt;
      flush stderr;
      Unix.tcsetattr fd Unix.TCSANOW { saved with c_echo = false };
      let line =
        Fun.protect
          ~finally:(fun () ->
            Unix.tcsetattr fd Unix.TCSANOW saved;
            prerr_newline ())
          (fun () -> In_channel.input_line stdin)
      in
      match line with
      | Some l when String.trim l <> "" -> Ok l
      | _ -> Error "no key was pasted")

(* What a key read at the prompt carries for the rest of the flow: the default repository, and no
   command. *)
let pasted = { key_command = ""; repo = default_repo; public_key = None }

(* WHERE `sign --next` READS THE KEY (docs/releases.md, Where the key comes from): the command [path] names
   when signer.json exists, else [prompt] (a hidden prompt, offered only on a terminal). With
   neither, the error says what to write in signer.json. *)
let key_reader ~path ~prompt =
  if Sys.file_exists path then
    let* config = load_config path in
    Ok (config, read_key config)
  else
    match prompt with
    | Some read -> Ok (pasted, read)
    | None ->
        let* config = load_config path in
        Ok (config, read_key config)

(* THE KEY, CHECKED ONCE THE SIGNER ANSWERS s (docs/releases.md, Where the key comes from): a key
   command that fails, prints nothing or prints no key ends the run in one line saying where the key
   goes, nothing signed, so the signer fetches it and runs the same command again. A key command
   that is `cat FILE` (the key downloaded from 1Password) names FILE. *)
let key_file (config : config) =
  match
    List.filter (( <> ) "")
      (String.split_on_char ' ' (String.trim config.key_command))
  with
  | [ "cat"; file ] -> Some file
  | _ -> None

let key_unread (config : config) why =
  match key_file config with
  | Some file ->
      Printf.sprintf
        "no release key at %s (%s). Download the release key from 1Password to \
         %s, then run the same command again; nothing was signed."
        file why file
  | None ->
      Printf.sprintf
        "the release key could not be read (%s). Make signer.json's \
         key_command print your release key, then run the same command again; \
         nothing was signed."
        why

let check_key (config : config) read_key =
  match
    let* printed = read_key () in
    Result.map_error
      (fun e -> "the key command's output: " ^ e)
      (Keys.decode_secret printed)
  with
  | Ok _ -> Ok ()
  | Error e -> Error (key_unread config e)

(* The secret the key command in [config] prints, decoded. *)
let secret (config : config) =
  let* printed = read_key config () in
  Result.map_error
    (fun e -> "the key command's output: " ^ e)
    (Keys.decode_secret printed)

(* The releases as GitHub's REST list answers them; a draft is listed only to people with write
   access. *)

type asset = { id : int; name : string; digest : string option }

type draft = {
  tag : string;
  version : Version.t;
  draft : bool;
  assets : asset list;
}

let asset_of_json json =
  match
    ( Release.field "id" json,
      Release.field "name" json,
      Release.field "digest" json )
  with
  | Some (`Int id), Some (`String name), digest ->
      Ok
        {
          id;
          name;
          digest = (match digest with Some (`String d) -> Some d | _ -> None);
        }
  | _ -> Error "a release asset without an id or a name"

(* Every release whose tag is [prefix]<MAJOR.MINOR.PATCH>; any other tag is not a version of that
   line. A node version's tag is v<version> and a relay version's relay-v<version>, so neither line
   ever reads the other's tags. *)
let releases_with_prefix prefix bytes =
  let* json = Release.parse_json "the releases list" bytes in
  match json with
  | `List l ->
      Release.all
        (fun r ->
          let* tag = Release.string_field "tag_name" r in
          let draft =
            match Release.field "draft" r with
            | Some (`Bool b) -> b
            | _ -> false
          in
          let* assets =
            match Release.field "assets" r with
            | Some (`List a) -> Release.all asset_of_json a
            | _ -> Ok []
          in
          match
            if String.starts_with ~prefix tag then
              Version.of_string
                (String.sub tag (String.length prefix)
                   (String.length tag - String.length prefix))
            else Error "not a version"
          with
          | Ok version -> Ok (Some { tag; version; draft; assets })
          | Error _ -> Ok None)
        l
      |> Result.map (List.filter_map Fun.id)
  | _ -> Error "the releases list is not a list"

let releases_of_string = releases_with_prefix "v"
let relay_tag_prefix = "relay-v"
let relay_releases_of_string = releases_with_prefix relay_tag_prefix

(* THE DRAFTS THIS digestif-update CANNOT READ: every draft whose tag is a version of neither line it
   knows. A line added after this binary was built (the relay line was one) is invisible to it, so
   `sign --next` names those drafts rather than passing over them in silence: the signer is told to
   run a newer digestif-update, which knows the line (ISS-47279). *)
let unread_drafts bytes =
  let* json = Release.parse_json "the releases list" bytes in
  let* node = releases_of_string bytes in
  let* relay = relay_releases_of_string bytes in
  let known = List.map (fun r -> r.tag) (node @ relay) in
  match json with
  | `List l ->
      Ok
        (List.filter_map
           (fun r ->
             match (Release.field "tag_name" r, Release.field "draft" r) with
             | Some (`String tag), Some (`Bool true)
               when not (List.mem tag known) ->
                 Some tag
             | _ -> None)
           l)
  | _ -> Error "the releases list is not a list"

let unread_line tags =
  Printf.sprintf
    "Also waiting, on a line this digestif-update does not know, so it cannot \
     show or sign it: %s. Run sign --next from the digestif-update of the \
     newest node release that is not a draft (docs/releases.md, Signing a \
     release)."
    (String.concat ", " tags)

(* A signature comes back as manifest.<key>.sig.json, the key's base64url without its prefix, holding
   the one signature in the channel's signatures format. *)
let signature_asset_name (key : Keys.public_key) =
  let b =
    match String.index_opt key ':' with
    | Some i -> String.sub key (i + 1) (String.length key - i - 1)
    | None -> key
  in
  "manifest." ^ b ^ ".sig.json"

let is_signature_asset name =
  String.starts_with ~prefix:"manifest." name
  && String.ends_with ~suffix:".sig.json" name

let newest = function
  | [] -> None
  | l ->
      Some
        (List.fold_left
           (fun a b -> if Version.compare b.version a.version > 0 then b else a)
           (List.hd l) l)

(* EVERY VERSION WAITING FOR SIGNATURES, newest first: each draft newer than the line's newest
   published version. Several can wait at once, since a cut never drops a draft somebody may still
   sign. A draft older than a published version can never publish, so it is not asked about.
   `sign --next` does not offer every one of them: {!offered} picks which. *)
let waiting_all releases =
  let floor =
    newest (List.filter (fun r -> not r.draft) releases)
    |> Option.map (fun r -> r.version)
  in
  List.filter
    (fun r ->
      r.draft
      &&
      match floor with
      | Some v -> Version.compare r.version v > 0
      | None -> true)
    releases
  |> List.sort (fun a b -> Version.compare b.version a.version)

(* THE VERSIONS `sign --next` OFFERS, of one line's waiting drafts newest first: the newest, and
   every older one that one more signature completes ([remaining] answers how many signatures it
   still needs). The drafts in between are skipped: not shown, not signed and not dropped; once a
   newer version publishes, the settle step drops them. A signature is still never spent on a
   version the other signer has not seen (digestif#265): whatever another signer signed and
   nobody completed is offered for completion, so their signature is never stranded.

   Who runs it is known from the key only once it is read, after the versions are shown, so "would
   complete" is "every required signer but one has signed". [mine] answers whether a draft already
   carries the running signer's signature, as signer.json's public_key names them: every such draft
   is left out, the newest included, since signing it again changes nothing. Without a public_key
   nothing is [mine], and a draft only the running signer signed is offered; the signing step then
   uploads nothing for it ({!sign_to_file}). *)
let offered ?(mine = fun _ -> false) ~remaining = function
  | [] -> []
  | newest :: older ->
      List.filter
        (fun r -> not (mine r))
        (newest :: List.filter (fun r -> remaining r = 1) older)

(* Whether [release] carries the signature of [key], by its asset name. *)
let signed_with (key : Keys.public_key) (release : draft) =
  List.exists (fun a -> a.name = signature_asset_name key) release.assets

(* The drafts signer.json's public_key says the running signer signed: none without one. *)
let mine_of (config : config) release =
  match config.public_key with
  | None -> false
  | Some key -> signed_with key release

(* The newest published version older than [r]: what its commit titles are counted from. *)
let last_published releases r =
  newest
    (List.filter
       (fun p -> (not p.draft) && Version.compare p.version r.version < 0)
       releases)

(* Every key a release needs: the signer set. A release never changes it; a signer-set change is a
   digestif-signers-v0 of its own (Signers_channel). *)
let required ~signers (_ : Release.manifest) : Release.signer list = signers

(* The question. *)

type shown = {
  repo : string;
  release : draft;
  commit : string;
  run_url : string;
      (** The run that attests every file, or the workflow's runs on the tag
          when none does. *)
  since : string option;  (** The last published tag, if any. *)
  titles : string list;
  compare_url : string;
  manifest : Release.manifest;
  already : Release.signer list;
      (** Signers whose signature asset is on the draft. *)
  remaining : int;  (** Required signatures not on the draft yet. *)
  problems : string list;
      (** Why the draft's files are not the ones the tag's build made: any one
          makes the version unsignable ({!unsignable_lines}). *)
}

(* The lines naming who signed, and when one more signature is all that is missing, that it publishes the version:
   a version somebody signed waits for the next signer, so the second signer knows what anything
   but s costs (digestif#265). *)
let signed_lines ~remaining = function
  | [] -> [ "Nobody has signed it yet." ]
  | (l : Release.signer list) ->
      ("Already signed by: "
      ^ String.concat ", " (List.map (fun (x : Release.signer) -> x.name) l))
      :: (if remaining = 1 then [ "One more signature publishes it." ] else [])

let digest_line (r : draft) (a : Release.artifact) =
  let file = Filename.basename a.url in
  let check =
    match List.find_opt (fun x -> x.name = file) r.assets with
    | None -> "  NOT ON THE DRAFT"
    | Some { digest = Some d; _ } when d <> a.sha256 ->
        "  DIFFERS FROM THE DRAFT'S " ^ d
    | Some { digest = Some _; _ } -> "  (the draft's file matches)"
    | Some { digest = None; _ } ->
        "  GITHUB HOLDS NO DIGEST FOR THE DRAFT'S FILE"
  in
  Printf.sprintf "  %-14s %s%s" a.platform a.sha256 check

(* A VERSION NOTHING TIES TO ITS BUILD IS NEVER SIGNED (docs/releases.md, What ties a version to its
   build): its reasons, printed after who signed it. It is not counted in the question, so neither
   s nor --sign signs it, nor d drops it. *)
let unsignable_lines = function
  | [] -> []
  | problems ->
      ""
      :: "NOT OFFERED: nothing ties these files to the tag's build, so this \
          version cannot be signed:"
      :: List.map (fun p -> "  - " ^ p) problems
      @ [
          "Run the workflow again on the tag to replace the draft's files, or \
           drop the draft.";
        ]

let render s =
  let b = Buffer.create 1024 in
  let line fmt = Printf.kbprintf (fun b -> Buffer.add_char b '\n') b fmt in
  line "Digestif %s, waiting for signatures on %s"
    (Version.to_string s.release.version)
    s.repo;
  line "  commit  %s" s.commit;
  line "  built   %s" s.run_url;
  line "";
  (match s.since with
  | Some t ->
      line "%d commit(s) since %s, the last published version:"
        (List.length s.titles) t
  | None ->
      line "%d commit(s); no version has been published yet:"
        (List.length s.titles));
  List.iter (fun t -> line "  - %s" t) s.titles;
  line "  %s" s.compare_url;
  line "";
  line "Notes, as signed:";
  (match String.trim s.manifest.notes with
  | "" -> line "  (none)"
  | n -> List.iter (fun l -> line "  %s" l) (String.split_on_char '\n' n));
  line "";
  line "Archives:";
  List.iter (fun a -> line "%s" (digest_line s.release a)) s.manifest.artifacts;
  line "";
  List.iter (line "%s") (signed_lines ~remaining:s.remaining s.already);
  List.iter (line "%s") (unsignable_lines s.problems);
  Buffer.contents b

type answer = Sign | Drop | Leave

let answer_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "s" -> Sign
  | "d" -> Drop
  | _ -> Leave

(* ONE QUESTION FOR THE WHOLE RUN (digestif#265): every waiting version, of both lines, is signed or
   dropped by one answer. An older waiting version's commits are all in the newest one's, so the
   newest is shown in full and each older one in a line. *)
let question ~count =
  if count = 1 then
    "s signs, d drops this version, anything else leaves it waiting: "
  else
    Printf.sprintf
      "s signs all %d versions, d drops them all, anything else leaves them \
       waiting: "
      count

(* sign --next --sign: the question is answered s without reading the terminal. It is still
   printed, with its answer, so the run reads as one the signer answered by hand. *)
let answer_sign ~say q =
  say (q ^ "s");
  "s"

(* The flow. [gh] runs `gh` with the arguments and answers its stdout; [git] runs `git` the same
   way; [clone] is the tool's own clone of the repository ({!clone_path}); [read_key] runs the
   signer's key command and answers what it printed; [ask] shows the question and answers the reply;
   [say] prints a line; [tmp] is a directory the signature is written into before it is uploaded. *)

let api_lines gh args =
  let* out = gh args in
  Ok (List.filter (fun l -> l <> "") (String.split_on_char '\n' out))

(* THE TOOL'S STATE DIRECTORY, ~/.digestif/update: its clone and its timing log. *)
let state_dir () =
  Filename.concat (Filename.concat (Sys.getenv "HOME") ".digestif") "update"

(* THE TOOL'S OWN CLONE (ISS-52997): a full bare clone of the repository the drafts are on, at
   ~/.digestif/update/<owner>-<name>.git, made on the first run and fetched every run after. A
   tag's commit, commit titles, the relay's paths and the migrations a relay version adds are read
   from it, so none of them is a GitHub request, and it holds every file, so no read lazily fetches
   one. It is never a checkout anyone works in. *)
let clone_path repo =
  Filename.concat (state_dir ())
    (String.map (fun c -> if c = '/' then '-' else c) repo ^ ".git")

(* sign --next's timing log ({!Timing}). *)
let timing_path () = Filename.concat (state_dir ()) "sign-next-timings.log"

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ())

(* Whether [clone] is a partial clone, one made without file contents (--filter=blob:none), which
   fetches a file from GitHub the first time it is read. *)
let partial ~git ~clone =
  match
    git [ "-C"; clone; "config"; "--get"; "remote.origin.partialclonefilter" ]
  with
  | Ok f -> String.trim f <> ""
  | Error _ -> false

(* Clone [repo] into [clone] when it is not there yet, then fetch every tag. A partial clone an
   earlier digestif-update made is cloned again in full, once. *)
let sync_clone ~git ~say ~repo ~clone =
  let* () =
    if Sys.file_exists clone && partial ~git ~clone then (
      say
        (Printf.sprintf
           "%s holds no file contents; cloning %s again in full, once..." clone
           repo);
      Stage.remove_tree clone);
    if Sys.file_exists clone then Ok ()
    else (
      mkdir_p (Filename.dirname clone);
      say
        (Printf.sprintf
           "Cloning %s into %s, once; later runs only fetch its new tags..."
           repo clone);
      let* _ =
        git
          [
            "clone";
            "--bare";
            "--quiet";
            Printf.sprintf "https://github.com/%s.git" repo;
            clone;
          ]
      in
      Ok ())
  in
  let* _ =
    git [ "-C"; clone; "fetch"; "--quiet"; "--tags"; "--force"; "origin" ]
  in
  Ok ()

(* The commit [tag] names in the clone, which was fetched from GitHub moments before
   ({!sync_clone}). *)
let tag_commit ~git ~clone tag =
  let* sha = git [ "-C"; clone; "rev-parse"; "--verify"; tag ^ "^{commit}" ] in
  Ok (String.trim sha)

(* The first line of every commit after [since] up to [tag] (every commit [tag] holds when [since]
   is None), newest first, kept to [pathspecs] when there are any, and where GitHub shows them. *)
let log_titles ~git ~repo ~clone ~since ?(pathspecs = []) tag =
  let range = match since with Some last -> last ^ ".." ^ tag | None -> tag in
  let* out =
    git
      ([ "-C"; clone; "log"; "--format=%s"; range ]
      @ if pathspecs = [] then [] else "--" :: pathspecs)
  in
  let titles = List.filter (fun l -> l <> "") (String.split_on_char '\n' out) in
  let url =
    match since with
    | Some last ->
        Printf.sprintf "https://github.com/%s/compare/%s...%s" repo last tag
    | None -> Printf.sprintf "https://github.com/%s/commits/%s" repo tag
  in
  Ok (titles, url)

let download_asset ~gh ~repo (a : asset) =
  gh
    [
      "api";
      "-H";
      "Accept: application/octet-stream";
      Printf.sprintf "repos/%s/releases/assets/%d" repo a.id;
    ]

let manifest_asset (release : draft) =
  match List.find_opt (fun a -> a.name = "manifest.json") release.assets with
  | Some a -> Ok a
  | None -> Error (release.tag ^ "'s draft holds no manifest.json yet")

(* The runs of [workflow] on the tag, as a link composed rather than looked up: GitHub's workflow
   page filtered to the tag's branch lists the run its push started. Shown only when no run attests
   the version's files, which then cannot be signed. *)
let run_url ~repo ~workflow tag =
  Printf.sprintf "https://github.com/%s/actions/workflows/%s?query=branch%%3A%s"
    repo workflow tag

(* A release's manifest.json, its bytes as the draft holds them. *)
let fetch_manifest ~gh ~repo (release : draft) =
  let* a = manifest_asset release in
  download_asset ~gh ~repo a

(* A node draft's manifest.json, its bytes and what they say, refused unless it names the draft's
   version. *)
let node_manifest (release : draft) bytes =
  let* manifest =
    Result.map_error
      (fun e -> release.tag ^ "'s manifest.json: " ^ e)
      (Release.manifest_of_string bytes)
  in
  let* manifest =
    Release.canonical
      (release.tag ^ "'s manifest.json")
      ~render:Release.manifest_to_string bytes manifest
  in
  if Version.equal manifest.version release.version then Ok (bytes, manifest)
  else
    Error
      (Printf.sprintf "%s's manifest names version %s; refusing to sign it"
         release.tag
         (Version.to_string manifest.version))

(* Of [required], the signers whose signature asset is on the draft. *)
let signed_on ~(required : Release.signer list) (release : draft) =
  List.filter (fun (s : Release.signer) -> signed_with s.key release) required

(* A file the manifest names, as [release]'s draft holds it: why it is not the manifest's (not on
   the draft, no digest GitHub computed, a digest that differs), or how to download it. *)
let draft_file ~gh ~repo (release : draft) ~name ~sha256 =
  match List.find_opt (fun a -> a.name = name) release.assets with
  | None -> Error (name ^ " is not on the draft")
  | Some { digest = None; _ } ->
      Error ("GitHub holds no digest for the draft's " ^ name)
  | Some { digest = Some d; _ } when d <> sha256 ->
      Error
        (Printf.sprintf "the draft's %s is %s, not the manifest's %s" name d
           sha256)
  | Some a ->
      Ok
        {
          Attestation.name;
          sha256;
          fetch = (fun () -> download_asset ~gh ~repo a);
        }

(* WHAT TIES A VERSION TO ITS BUILD (docs/releases.md, What ties a version to its build): every
   file [files] names on [release]'s draft, and the manifest's own [bytes], attested by [workflow]
   run on the tag at [commit] ({!Attestation}). The run that attests them all, or the composed link
   to the workflow's runs, and every reason the version cannot be signed. *)
let provenance ~gh ~repo ~workflow ~tmp ~commit (release : draft) bytes files =
  let drafted =
    List.map
      (fun (name, sha256) -> draft_file ~gh ~repo release ~name ~sha256)
      files
  in
  let manifest =
    {
      Attestation.name = "manifest.json";
      sha256 = Keys.hash_of_bytes bytes;
      fetch = (fun () -> Ok bytes);
    }
  in
  let checked =
    Attestation.check ~gh ~repo ~workflow ~tag:release.tag ~commit
      ~dir:(Filename.concat tmp release.tag)
      (manifest :: List.filter_map Result.to_option drafted)
  in
  let missing =
    List.filter_map (function Error e -> Some e | Ok _ -> None) drafted
  in
  ( (match checked.run_url with
    | Some u -> u
    | None -> run_url ~repo ~workflow release.tag),
    missing @ checked.problems )

let show ~gh ~git ~clone ~tmp ~signers ~repo ~releases (release : draft)
    (bytes, (manifest : Release.manifest)) =
  let* commit = tag_commit ~git ~clone release.tag in
  let run_url, problems =
    provenance ~gh ~repo ~workflow:"release.yml" ~tmp ~commit release bytes
      (List.map
         (fun (a : Release.artifact) -> (Filename.basename a.url, a.sha256))
         manifest.artifacts)
  in
  let since = Option.map (fun p -> p.tag) (last_published releases release) in
  let* titles, compare_url = log_titles ~git ~repo ~clone ~since release.tag in
  let required = required ~signers manifest in
  let already = signed_on ~required release in
  let remaining = List.length required - List.length already in
  Ok
    ( {
        repo;
        release;
        commit;
        run_url;
        since;
        titles;
        compare_url;
        manifest;
        already;
        remaining;
        problems;
      },
      bytes )

(* Sign [bytes] over [domain] with the key [read_key] prints, refusing a key that is not among
   [required], and a key that is not the public_key signer.json names (that key chose what was
   shown); the signature is written into [tmp] under the asset name its key gives it. A [release]
   that already carries this key's signature is not signed again: None, and nothing to upload. *)
let sign_to_file ~(config : config) ~domain ~required ~read_key ~tmp
    (release : draft) bytes =
  let* printed = read_key () in
  let* secret =
    Result.map_error
      (fun e -> "the key command's output: " ^ e)
      (Keys.decode_secret printed)
  in
  let pub = Keys.public secret in
  let* me =
    match List.find_opt (fun (x : Release.signer) -> x.key = pub) required with
    | Some me -> Ok me
    | None ->
        Error
          (Printf.sprintf
             "your key %s is not a release signer; nothing was signed" pub)
  in
  let* () =
    match config.public_key with
    | Some named when named <> pub ->
        Error
          (Printf.sprintf
             "your key is %s but signer.json's public_key is %s; nothing was \
              signed. Write your key's public half there."
             pub named)
    | _ -> Ok ()
  in
  if signed_with pub release then Ok (me, None)
  else
    let sigs = Release.add_signature ~domain ~secret bytes [] in
    let path = Filename.concat tmp (signature_asset_name pub) in
    Out_channel.with_open_bin path (fun oc ->
        Out_channel.output_string oc (Release.signatures_to_string sigs));
    Ok (me, Some path)

(* Sign [bytes] with the key [read_key] prints, refusing a key the release does not need. *)
let signature_file ~config ~signers ~read_key ~tmp (s : shown) bytes =
  sign_to_file ~config ~domain:Release.release_domain
    ~required:(required ~signers s.manifest)
    ~read_key ~tmp s.release bytes

let upload ~gh ~repo ~tag path =
  let* _ = gh [ "release"; "upload"; tag; path; "--repo"; repo; "--clobber" ] in
  Ok ()

let drop ~gh ~repo ~tag ~say =
  let* _ = gh [ "release"; "delete"; tag; "--repo"; repo; "--yes" ] in
  say
    (Printf.sprintf
       "Dropped %s: its draft release and every signature on it are deleted. \
        The tag stays."
       tag);
  Ok ()

(* THE RELAY LINE (docs/releases.md, Signing a relay release). *)

let relay_paths_file = "ci/relay-release-paths"

(* The pathspecs of ci/relay-release-paths at [tag], one git pathspec per line with blank lines and
   # comments left out, as ci/release.sh reads them; None when the tag carries no such file. *)
let relay_paths ~git ~clone tag =
  let* listed =
    git [ "-C"; clone; "ls-tree"; "--name-only"; tag; relay_paths_file ]
  in
  if String.trim listed = "" then Ok None
  else
    let* text = git [ "-C"; clone; "show"; tag ^ ":" ^ relay_paths_file ] in
    let specs =
      List.filter_map
        (fun l ->
          let l = String.trim l in
          if l = "" || l.[0] = '#' then None else Some l)
        (String.split_on_char '\n' text)
    in
    if specs = [] then
      Error (Printf.sprintf "%s at %s names no path" relay_paths_file tag)
    else Ok (Some specs)

(* The titles of the commits between the last published relay version and [tag] (every commit the
   tag holds before the first) that change a relay release path, git doing the filtering. A tag
   without the paths file shows every commit and says so. *)
let relay_titles ~git ~repo ~clone ~since tag =
  let* specs = relay_paths ~git ~clone tag in
  match specs with
  | None ->
      let* titles, url = log_titles ~git ~repo ~clone ~since tag in
      Ok
        ( titles,
          url,
          Some
            (Printf.sprintf
               "%s is not at %s, so every commit is shown, not only those \
                touching the relay"
               relay_paths_file tag) )
  | Some pathspecs ->
      let* titles, url = log_titles ~git ~repo ~clone ~since ~pathspecs tag in
      Ok (titles, url, None)

(* A migration the version adds or changes over the last published relay version, with its full
   text as the tag holds it, checked against the manifest's sha256. *)
type migration_change =
  | Added  (** The last published version did not list it. *)
  | Changed of string
      (** The last published version listed it with this other sha256: an
          applied migration is never run again, so the edit reaches only a relay
          deployed fresh. Never signed. *)

type added = {
  migration_name : string;
  change : migration_change;
  text : (string, string) result;
  matches : bool;  (** The text's sha256 is the manifest's. *)
}

(* A relay as the signer's own node last read it: its url and the relay_version its GET /v0/circle
   answered at the node's last read of it, at most six hours old (the node's relay_versions table), None for a relay
   built before relay releases, or why there is none to show. *)
type relay_read = string * (string option, string) result

type relay_shown = {
  relay_release : draft;
  relay_commit : string;
  relay_run_url : string;
  relay_since : string option;
  relay_titles : string list;
  relay_titles_note : string option;
  relay_compare_url : string;
  relay_manifest : Release.relay_manifest;
  added : added list;
      (** Every migration whose sha256 the last published version lacks. *)
  removed : Release.relay_migration list;
      (** Every migration the last published version listed and this one does
          not. *)
  relays : relay_read list option;  (** None: no node runs on this machine. *)
  relay_already : Release.signer list;
  relay_remaining : int;  (** Required signatures not on the draft yet. *)
  relay_problems : string list;
      (** Why the version cannot be signed, as {!shown}'s problems, and every
          migration that is not the tag's file. *)
}

let relay_manifest_of (release : draft) bytes =
  let* m =
    Result.map_error
      (fun e -> release.tag ^ "'s manifest.json: " ^ e)
      (Release.relay_manifest_of_string bytes)
  in
  let* m =
    Release.canonical
      (release.tag ^ "'s manifest.json")
      ~render:Release.relay_manifest_to_string bytes m
  in
  Ok (bytes, m)

let previous_migrations (before : Release.relay_manifest option) =
  match before with None -> [] | Some b -> b.migrations

(* Every migration of [m] whose name or sha256 the last published version [before] lacks: one it
   adds, and one whose bytes changed under the same name. *)
let added_migrations ~git ~clone ~tag ~(before : Release.relay_manifest option)
    (m : Release.relay_manifest) =
  let had = previous_migrations before in
  List.filter_map
    (fun (g : Release.relay_migration) ->
      let change =
        match
          List.find_opt
            (fun (h : Release.relay_migration) -> h.migration = g.migration)
            had
        with
        | None -> Some Added
        | Some h when h.migration_sha256 <> g.migration_sha256 ->
            Some (Changed h.migration_sha256)
        | Some _ -> None
      in
      Option.map
        (fun change ->
          let text =
            git
              [ "-C"; clone; "show"; tag ^ ":relay/migrations/" ^ g.migration ]
          in
          let matches =
            match text with
            | Ok t -> Keys.hash_of_bytes t = g.migration_sha256
            | Error _ -> false
          in
          { migration_name = g.migration; change; text; matches })
        change)
    m.migrations

(* Every migration the last published version [before] listed that [m] does not. *)
let removed_migrations ~(before : Release.relay_manifest option)
    (m : Release.relay_manifest) =
  List.filter
    (fun (h : Release.relay_migration) ->
      not
        (List.exists
           (fun (g : Release.relay_migration) -> g.migration = h.migration)
           m.migrations))
    (previous_migrations before)

(* [downloaded] answers the manifest of a relay release, downloaded once for the whole run. *)
let show_relay ~gh ~git ~clone ~tmp ~signers ~repo ~relays ~releases ~downloaded
    (release : draft) =
  let* bytes, (manifest : Release.relay_manifest) = downloaded release in
  let* () =
    if Version.equal manifest.relay_version release.version then Ok ()
    else
      Error
        (Printf.sprintf "%s's manifest names version %s; refusing to sign it"
           release.tag
           (Version.to_string manifest.relay_version))
  in
  let* commit = tag_commit ~git ~clone release.tag in
  let run_url, problems =
    provenance ~gh ~repo ~workflow:"relay-release.yml" ~tmp ~commit release
      bytes
      [
        ( Filename.basename manifest.bundle.bundle_url,
          manifest.bundle.bundle_sha256 );
      ]
  in
  let last = last_published releases release in
  let since = Option.map (fun p -> p.tag) last in
  let* titles, compare_url, note =
    relay_titles ~git ~repo ~clone ~since release.tag
  in
  let* before =
    match last with
    | None -> Ok None
    | Some p ->
        let* _, m = downloaded p in
        Ok (Some m)
  in
  let added = added_migrations ~git ~clone ~tag:release.tag ~before manifest in
  let removed = removed_migrations ~before manifest in
  let migration_problems =
    List.filter_map
      (fun a ->
        match (a.change, a.text) with
        | Changed was, _ ->
            Some
              (Printf.sprintf
                 "migration %s was %s in %s and is %s here: a published \
                  migration is never edited, so a new one carries the change"
                 a.migration_name was
                 (Option.value since ~default:"the last published version")
                 (Option.value
                    (Option.map
                       (fun (g : Release.relay_migration) -> g.migration_sha256)
                       (List.find_opt
                          (fun (g : Release.relay_migration) ->
                            g.migration = a.migration_name)
                          manifest.migrations))
                    ~default:"another sha256"))
        | Added, Error _ ->
            Some
              (Printf.sprintf "migration %s could not be read at %s"
                 a.migration_name release.tag)
        | Added, Ok _ when not a.matches ->
            Some
              (Printf.sprintf "migration %s differs from the tag's file"
                 a.migration_name)
        | Added, Ok _ -> None)
      added
  in
  let already = signed_on ~required:signers release in
  let relay_remaining = List.length signers - List.length already in
  Ok
    ( {
        relay_release = release;
        relay_commit = commit;
        relay_run_url = run_url;
        relay_since = since;
        relay_titles = titles;
        relay_titles_note = note;
        relay_compare_url = compare_url;
        relay_manifest = manifest;
        added;
        removed;
        relays;
        relay_already = already;
        relay_remaining;
        relay_problems = problems @ migration_problems;
      },
      bytes )

let bundle_line (r : draft) (b : Release.relay_bundle) =
  let file = Filename.basename b.bundle_url in
  let check =
    match List.find_opt (fun x -> x.name = file) r.assets with
    | None -> "  NOT ON THE DRAFT"
    | Some { digest = Some d; _ } when d <> b.bundle_sha256 ->
        "  DIFFERS FROM THE DRAFT'S " ^ d
    | Some { digest = Some _; _ } -> "  (the draft's file matches)"
    | Some { digest = None; _ } ->
        "  GITHUB HOLDS NO DIGEST FOR THE DRAFT'S FILE"
  in
  Printf.sprintf "  %s %s, %d bytes%s" file b.bundle_sha256 b.bundle_size check

let render_relay ~repo s =
  let b = Buffer.create 2048 in
  let line fmt = Printf.kbprintf (fun b -> Buffer.add_char b '\n') b fmt in
  let m = s.relay_manifest in
  line "Digestif relay %s, waiting for signatures on %s"
    (Version.to_string s.relay_release.version)
    repo;
  line "  commit  %s" s.relay_commit;
  line "  built   %s" s.relay_run_url;
  line "";
  (match s.relay_since with
  | Some t ->
      line
        "%d commit(s) touching the relay since %s, the last published relay \
         version:"
        (List.length s.relay_titles)
        t
  | None ->
      line
        "%d commit(s) touching the relay; no relay version has been published \
         yet:"
        (List.length s.relay_titles));
  Option.iter (fun n -> line "  (%s)" n) s.relay_titles_note;
  List.iter (fun t -> line "  - %s" t) s.relay_titles;
  line "  %s" s.relay_compare_url;
  line "";
  line "Notes, as signed:";
  (match String.trim m.relay_notes with
  | "" -> line "  (none)"
  | n -> List.iter (fun l -> line "  %s" l) (String.split_on_char '\n' n));
  line "";
  (match s.added with
  | [] -> line "Migrations: this version adds or changes none."
  | l ->
      line
        "Migrations this version adds or changes, in full (a rollback replaces \
         the Worker and never undoes one):";
      List.iter
        (fun a ->
          let sha =
            match
              List.find_opt
                (fun (g : Release.relay_migration) ->
                  g.migration = a.migration_name)
                m.migrations
            with
            | Some g -> g.migration_sha256
            | None -> ""
          in
          line "";
          line "  %s %s%s%s" a.migration_name sha
            (match a.change with
            | Added -> ""
            | Changed was -> "  CHANGED, WAS " ^ was)
            (if a.matches then "  (the tag's file matches)"
             else "  DIFFERS FROM THE TAG'S FILE");
          match a.text with
          | Error e -> line "    COULD NOT BE READ: %s" e
          | Ok t ->
              let t =
                if String.ends_with ~suffix:"\n" t then
                  String.sub t 0 (String.length t - 1)
                else t
              in
              List.iter
                (fun l -> line "    | %s" l)
                (String.split_on_char '\n' t))
        l);
  (match s.removed with
  | [] -> ()
  | l ->
      line "";
      line
        "Migrations this version NO LONGER LISTS (a relay deployed fresh from \
         it never runs them):";
      List.iter
        (fun (g : Release.relay_migration) ->
          line "  %s %s  REMOVED" g.migration g.migration_sha256)
        l);
  line "";
  line "Bundle:";
  line "%s" (bundle_line s.relay_release m.bundle);
  line "";
  line "Compatible with relays from %s on."
    (Version.to_string m.compatible_with);
  (match s.relays with
  | None -> line "No node runs here, so no relay's version is shown."
  | Some [] -> line "This node syncs with no relay."
  | Some l ->
      line "Every relay, as this node last read it:";
      List.iter
        (fun (url, read) ->
          match read with
          | Error e -> line "  %s  could not be read: %s" url e
          | Ok None ->
              line "  %s  no relay_version (built before relay releases)" url
          | Ok (Some v) ->
              let older =
                match Version.of_string v with
                | Ok rv when Version.compare rv m.compatible_with < 0 ->
                    "  OLDER THAN compatible_with"
                | Ok _ -> ""
                | Error _ -> "  NOT A VERSION"
              in
              line "  %s  %s%s" url v older)
        l);
  line "";
  List.iter (line "%s")
    (signed_lines ~remaining:s.relay_remaining s.relay_already);
  List.iter (line "%s") (unsignable_lines s.relay_problems);
  Buffer.contents b

(* What the relay line needs beyond gh: every relay's version as this machine's node reads it
   (None when no node runs here), and the three steps of relay-publish (Relay_publish.run), run when
   the signature just uploaded completes the signer set, handed the manifest.json bytes this run
   already downloaded so it reads them again only when the draft's differ. *)
type relay = {
  relay_versions : unit -> relay_read list option;
  publish : manifest:string -> Version.t -> (unit, string) result;
}

let no_relay =
  { relay_versions = (fun () -> None); publish = (fun ~manifest:_ _ -> Ok ()) }

let signed_by_words = function
  | [] -> "nobody has signed it"
  | (l : Release.signer list) ->
      "signed by "
      ^ String.concat ", " (List.map (fun (x : Release.signer) -> x.name) l)

(* An older waiting version in one line: who signed it, and why it cannot be signed when it
   cannot. *)
let older_line ~tag ~already ~problems =
  Printf.sprintf "  also %s: %s%s" tag (signed_by_words already)
    (match problems with
    | [] -> ""
    | l ->
        "; NOT OFFERED, nothing ties its files to its build: "
        ^ String.concat "; " l)

type node_version = { node : shown; node_bytes : string }
type relay_version = { relay : relay_shown; relay_bytes : string }

let missing ~signers ~(signed_by : Release.signer list) =
  List.filter
    (fun (x : Release.signer) ->
      not (List.exists (fun (y : Release.signer) -> y.key = x.key) signed_by))
    signers

(* Upload the signature [sign_to_file] wrote to [tag]'s draft, or say the draft already holds it. *)
let upload_signed ~gh ~(config : config) ~say ~tag ((me : Release.signer), path)
    =
  match path with
  | None ->
      say
        (Printf.sprintf
           "%s already carries your signature as %s; nothing was uploaded." tag
           me.name);
      Ok me
  | Some path ->
      let* () = upload ~gh ~repo:config.repo ~tag path in
      say
        (Printf.sprintf
           "Signed %s as %s (%s) and uploaded %s to its draft release." tag
           me.name me.key (Filename.basename path));
      Ok me

(* Sign one node version and upload the signature. *)
let sign_node ~gh ~signers ~(config : config) ~read_key ~say ~tmp v =
  let s = v.node in
  let* signed = signature_file ~config ~signers ~read_key ~tmp s v.node_bytes in
  upload_signed ~gh ~config ~say ~tag:s.release.tag signed

let sign_relay ~gh ~signers ~(config : config) ~read_key ~say ~tmp v =
  let s = v.relay in
  let* signed =
    sign_to_file ~config ~domain:Release.relay_release_domain ~required:signers
      ~read_key ~tmp s.relay_release v.relay_bytes
  in
  upload_signed ~gh ~config ~say ~tag:s.relay_release.tag signed

let rec each f = function
  | [] -> Ok ()
  | x :: rest ->
      let* () = f x in
      each f rest

(* THE RELAY LINE AFTER SIGNING, newest first: the newest version every signer has now signed is
   published, and every older relay draft in [waiting], offered this run or skipped, which can then
   never publish, is dropped. None complete: each waits for whoever is missing. *)
let settle_relays ~gh ~signers ~(config : config) ~say ~(relay : relay) ~me
    ~(waiting : draft list) versions =
  let complete v =
    missing ~signers ~signed_by:(me @ v.relay.relay_already) = []
  in
  let rec split = function
    | [] -> None
    | v :: older -> if complete v then Some (v, older) else split older
  in
  match split versions with
  | None ->
      each
        (fun v ->
          say
            (Printf.sprintf "%s waits for %s." v.relay.relay_release.tag
               (String.concat ", "
                  (List.map
                     (fun (x : Release.signer) -> x.name)
                     (missing ~signers ~signed_by:(me @ v.relay.relay_already)))));
          Ok ())
        versions
  | Some (v, _) -> (
      let tag = v.relay.relay_release.tag in
      say
        (Printf.sprintf
           "Your signature completes the signer set, so %s is published now:"
           tag);
      match
        relay.publish ~manifest:v.relay_bytes v.relay.relay_release.version
      with
      | Error e ->
          Error
            (Printf.sprintf
               "%s is signed by every signer but was not published: %s. Run \
                ci/release.sh relay-publish --version %s to publish it."
               tag e
               (Version.to_string v.relay.relay_release.version))
      | Ok () ->
          each
            (fun (o : draft) ->
              say
                (Printf.sprintf
                   "%s is older than the relay version just published." o.tag);
              drop ~gh ~repo:config.repo ~tag:o.tag ~say)
            (List.filter
               (fun (o : draft) ->
                 Version.compare o.version v.relay.relay_release.version < 0)
               waiting))

let releases_path repo = Printf.sprintf "repos/%s/releases?per_page=50" repo

(* The key command run once per `sign --next`, however many versions it signs. *)
let once read_key =
  let kept = ref None in
  fun () ->
    match !kept with
    | Some k -> k
    | None ->
        let k = read_key () in
        (match k with Ok _ -> kept := Some k | Error _ -> ());
        k

(* How many versions of one line are shown at once: each node version holds its archives (about
   160 MB) in memory while their attestations are checked, so a long backlog is shown in waves of
   this many rather than all at once. *)
let shows_at_once = 6

let rec collect f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = collect f rest in
      Ok (y :: ys)

(* What the run shows: the newest version of each line in full, each older one in a line. A node
   version every signer has signed is named and left to the fleet's rollout. *)
let show_all ~say ~repo ~nodes ~relays ~skipped =
  (match nodes with
  | [] when skipped -> ()
  | [] -> say "No node version is waiting for signatures."
  | newest :: older ->
      say (render newest.node);
      List.iter
        (fun v ->
          say
            (older_line ~tag:v.node.release.tag ~already:v.node.already
               ~problems:v.node.problems))
        older);
  match relays with
  | [] -> ()
  | newest :: older ->
      say "";
      say (render_relay ~repo newest.relay);
      List.iter
        (fun v ->
          say
            (older_line ~tag:v.relay.relay_release.tag
               ~already:v.relay.relay_already ~problems:v.relay.relay_problems))
        older

(* THE STALE DRAFTS of a line: every draft older than the line's newest published version, which
   can never publish, each with that version's tag. Nothing offers them; {!drop_stale} deletes
   them, so they do not pile up. *)
let stale releases =
  match newest (List.filter (fun r -> not r.draft) releases) with
  | None -> []
  | Some p ->
      List.filter_map
        (fun r ->
          if r.draft && Version.compare r.version p.version < 0 then
            Some (r, p.tag)
          else None)
        releases

(* Delete every stale draft at once, saying each; one that could not be deleted is said, and the
   run goes on. *)
let drop_stale ~gh ~repo ~say drafts =
  let deleted =
    Parallel.map
      (fun ((r : draft), _) ->
        gh [ "release"; "delete"; r.tag; "--repo"; repo; "--yes" ])
      drafts
  in
  List.iter2
    (fun ((r : draft), floor) result ->
      match result with
      | Ok _ ->
          say
            (Printf.sprintf
               "Dropped %s, a draft older than %s, the newest published \
                version of its line, which can never publish."
               r.tag floor)
      | Error e -> say (Printf.sprintf "%s was not dropped: %s" r.tag e))
    drafts deleted

(* Every release whose manifest the run reads, each once: [drafts], and the last published version
   before each of [relays], whose migrations a relay version's are counted against. *)
let manifests_to_read ~relay_releases ~drafts ~relays =
  List.fold_left
    (fun acc (r : draft) ->
      if List.exists (fun (x : draft) -> x.tag = r.tag) acc then acc
      else acc @ [ r ])
    []
    (drafts @ List.filter_map (last_published relay_releases) relays)

(* THE VERSIONS OFFERED, of either line, signed or dropped by ONE answer: of each line's waiting
   drafts ({!waiting_all}), the newest and those one more signature completes ({!offered}), read
   from one listing of the releases ([listed], the bytes GitHub's list answered), every manifest
   downloaded at once while the tool's clone fetches ({!sync_clone}), their commits and files read
   from that clone, and the key read once ({!once}), only after an s. Each step is timed into
   [timer]. Once the question is answered, every stale draft goes ({!drop_stale}). *)
let run ~gh ~git ~clone ~signers ~(config : config) ~read_key ~ask ~say ~tmp
    ~relay ~timer ~listed =
  let time step f = Timing.time timer step f in
  let read_key = once read_key in
  let repo = config.repo in
  let* node_releases = releases_of_string listed in
  let* relay_releases = relay_releases_of_string listed in
  let* unread = unread_drafts listed in
  let sweep () =
    match stale node_releases @ stale relay_releases with
    | [] -> ()
    | l -> time "drop-stale" (fun () -> drop_stale ~gh ~repo ~say l)
  in
  match (waiting_all node_releases, waiting_all relay_releases) with
  | [], [] ->
      sweep ();
      if unread <> [] then Error (unread_line unread)
      else
        Error (Printf.sprintf "no version is waiting for signatures on %s" repo)
  | node_drafts, relay_drafts ->
      let mine = mine_of config in
      let relay_offered =
        offered ~mine
          ~remaining:(fun r ->
            List.length signers - List.length (signed_on ~required:signers r))
          relay_drafts
      in
      let to_read =
        manifests_to_read ~relay_releases
          ~drafts:(node_drafts @ relay_offered)
          ~relays:relay_offered
      in
      let synced, fetched =
        Parallel.both
          (fun () -> time "clone" (fun () -> sync_clone ~git ~say ~repo ~clone))
          (fun () ->
            time "manifests" (fun () ->
                Parallel.map
                  (fun (r : draft) ->
                    time ("manifest " ^ r.tag) (fun () ->
                        fetch_manifest ~gh ~repo r))
                  to_read))
      in
      let fetched =
        List.combine (List.map (fun (r : draft) -> r.tag) to_read) fetched
      in
      let bytes_of (r : draft) =
        match List.assoc_opt r.tag fetched with
        | Some b -> b
        | None -> Error (r.tag ^ "'s manifest.json was not downloaded")
      in
      let* node_drafts =
        collect
          (fun r ->
            let* b = bytes_of r in
            let* m = node_manifest r b in
            let required = required ~signers (snd m) in
            Ok (r, m, List.length required - List.length (signed_on ~required r)))
          node_drafts
      in
      let node_skipped =
        List.filter mine (List.map (fun (r, _, _) -> r) node_drafts)
      in
      let skipped = node_skipped @ List.filter mine relay_drafts in
      let node_drafts =
        offered
          ~mine:(fun (r, _, _) -> mine r)
          ~remaining:(fun (_, _, n) -> n)
          node_drafts
        |> List.map (fun (r, m, _) -> (r, m))
      in
      if skipped <> [] then
        say
          (Printf.sprintf
             "Already signed with your key (signer.json's public_key), so not \
              shown: %s."
             (String.concat ", " (List.map (fun (r : draft) -> r.tag) skipped)));
      let* () =
        if node_drafts = [] && relay_offered = [] then Ok () else synced
      in
      (* Every version is shown at once ({!shows_at_once}), both lines together, so the time to
         the question is the slowest show rather than their sum. *)
      let downloaded r =
        let* b = bytes_of r in
        relay_manifest_of r b
      in
      let node_shown, relay_shown =
        Parallel.both
          (fun () ->
            Parallel.map_limit ~limit:shows_at_once
              (fun ((r : draft), m) ->
                time ("show " ^ r.tag) (fun () ->
                    let* node, node_bytes =
                      show ~gh ~git ~clone ~tmp ~signers ~repo
                        ~releases:node_releases r m
                    in
                    Ok { node; node_bytes }))
              node_drafts)
          (fun () ->
            let relays_read =
              if relay_offered = [] then None
              else time "relay-versions" relay.relay_versions
            in
            Parallel.map_limit ~limit:shows_at_once
              (fun (r : draft) ->
                time ("show " ^ r.tag) (fun () ->
                    let* relay, relay_bytes =
                      show_relay ~gh ~git ~clone ~tmp ~signers ~repo
                        ~relays:relays_read ~releases:relay_releases ~downloaded
                        r
                    in
                    Ok { relay; relay_bytes }))
              relay_offered)
      in
      let* nodes = collect Fun.id node_shown in
      let done_, nodes = List.partition (fun v -> v.node.remaining = 0) nodes in
      List.iter
        (fun v ->
          say
            (Printf.sprintf
               "%s has every signature; the fleet's rollout publishes it."
               v.node.release.tag))
        done_;
      let* relays = collect Fun.id relay_shown in
      show_all ~say ~repo ~nodes ~relays ~skipped:(node_skipped <> []);
      (* Only a version whose files its build attested is signed or dropped by the answer. *)
      let nodes, node_refused =
        List.partition (fun v -> v.node.problems = []) nodes
      in
      let relays, relay_refused =
        List.partition (fun v -> v.relay.relay_problems = []) relays
      in
      let refused =
        List.map (fun v -> v.node.release.tag) node_refused
        @ List.map (fun v -> v.relay.relay_release.tag) relay_refused
      in
      let count = List.length nodes + List.length relays in
      let finish () =
        sweep ();
        if unread <> [] then (
          say "";
          say (unread_line unread));
        Ok ()
      in
      if refused <> [] then
        say
          (Printf.sprintf
             "Not offered, since nothing ties its files to its build: %s."
             (String.concat ", " refused));
      if count = 0 then (
        if skipped <> [] then
          say "Every version waiting for you already carries your signature.";
        let* () = finish () in
        if refused = [] then Ok ()
        else
          Error
            (Printf.sprintf
               "nothing was signed: %s cannot be signed until its files are \
                ones its build attested (above)"
               (String.concat ", " refused)))
      else (
        Timing.mark timer "until-question";
        match
          answer_of_string (time "answer" (fun () -> ask (question ~count)))
        with
        | Leave ->
            say "Left waiting; nothing was signed.";
            finish ()
        | Drop ->
            let* () =
              each
                (fun tag -> drop ~gh ~repo ~tag ~say)
                (List.map (fun v -> v.node.release.tag) nodes
                @ List.map (fun v -> v.relay.relay_release.tag) relays)
            in
            finish ()
        | Sign ->
            let* () =
              time "key" (fun () ->
                  if config.key_command = "" then
                    Result.map ignore (read_key ())
                  else check_key config read_key)
            in
            let* () =
              each
                (fun v ->
                  time ("sign " ^ v.node.release.tag) (fun () ->
                      let* _ =
                        sign_node ~gh ~signers ~config ~read_key ~say ~tmp v
                      in
                      Ok ()))
                nodes
            in
            let* me =
              match relays with
              | [] -> Ok []
              | _ ->
                  let* mes =
                    collect
                      (fun v ->
                        time ("sign " ^ v.relay.relay_release.tag) (fun () ->
                            sign_relay ~gh ~signers ~config ~read_key ~say ~tmp
                              v))
                      relays
                  in
                  Ok (match mes with m :: _ -> [ m ] | [] -> [])
            in
            let* () =
              if relays = [] then Ok ()
              else
                time "settle" (fun () ->
                    settle_relays ~gh ~signers ~config ~say ~relay ~me
                      ~waiting:relay_drafts relays)
            in
            finish ())
