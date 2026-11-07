(* `digestif-update sign --next` (docs/releases.md, Signing a release and Signing a relay release):
   sign the versions waiting for signatures, draft GitHub releases the Release workflow (the node
   line, v<version>) or the Relay release workflow (the relay line, relay-v<version>) left, the
   node line first: on each line the newest draft, and every older one the signer's signature
   would complete ({!offered}). Everything it reads and writes on GitHub goes through the signer's
   own `gh` login, passed in as [gh] so the flow is tested without the network; commit titles are
   read from the tool's own clone of the repository through [git] ({!sync_clone}). It shows what
   the version holds before it reads the key, reads the key from the command the signer named in
   ~/.config/digestif/signer.json into memory only, and uploads the signature as one asset of the
   draft, named for the key, so two signers never write one file.

   `ci/release.sh signatures` reads those assets back and checks them with `digestif-update verify`. *)

let ( let* ) = Result.bind

(* ~/.config/digestif/signer.json *)

type config = {
  key_command : string;
      (** A shell command printing the signer's secret, e.g. `op read op://...`.
      *)
  repo : string;  (** owner/name of the repository the drafts are on. *)
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
  if String.trim key_command = "" then
    Error "field \"key_command\" must name the command that prints your key"
  else Ok { key_command; repo }

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
let pasted = { key_command = ""; repo = default_repo }

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

   Who runs it is known only once the key is read, after the versions are shown, so "would
   complete" is "every required signer but one has signed". A draft only the signer running it
   has signed is offered too, and signing it again changes nothing. *)
let offered ~remaining = function
  | [] -> []
  | newest :: older -> newest :: List.filter (fun r -> remaining r = 1) older

(* The newest published version older than [r]: what its commit titles are counted from. *)
let last_published releases r =
  newest
    (List.filter
       (fun p -> (not p.draft) && Version.compare p.version r.version < 0)
       releases)

(* Every key a release needs: the signer set, plus the new set a manifest that replaces it names. *)

let required ~signers (m : Release.manifest) =
  let next = Option.value m.signers ~default:[] in
  List.fold_left
    (fun acc (s : Release.signer) ->
      if List.exists (fun (a : Release.signer) -> a.key = s.key) acc then acc
      else acc @ [ s ])
    [] (signers @ next)

(* The question. *)

type shown = {
  repo : string;
  release : draft;
  commit : string;
  run_url : string option;
  since : string option;  (** The last published tag, if any. *)
  titles : string list;
  compare_url : string;
  manifest : Release.manifest;
  already : Release.signer list;
      (** Signers whose signature asset is on the draft. *)
  remaining : int;  (** Required signatures not on the draft yet. *)
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
    | Some { digest = None; _ } -> ""
  in
  Printf.sprintf "  %-14s %s%s" a.platform a.sha256 check

let render s =
  let b = Buffer.create 1024 in
  let line fmt = Printf.kbprintf (fun b -> Buffer.add_char b '\n') b fmt in
  line "Digestif %s, waiting for signatures on %s"
    (Version.to_string s.release.version)
    s.repo;
  line "  commit  %s" s.commit;
  line "  built   %s"
    (Option.value s.run_url ~default:"(no Release run found for the tag)");
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
  (match s.manifest.signers with
  | None -> ()
  | Some next ->
      line "";
      line "This version REPLACES the signer set with:";
      List.iter (fun (x : Release.signer) -> line "  %s %s" x.name x.key) next);
  line "";
  List.iter (line "%s") (signed_lines ~remaining:s.remaining s.already);
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

(* The flow. [gh] runs `gh` with the arguments and answers its stdout; [git] runs `git` the same
   way; [clone] is the tool's own clone of the repository ({!clone_path}); [read_key] runs the
   signer's key command and answers what it printed; [ask] shows the question and answers the reply;
   [say] prints a line; [tmp] is a directory the signature is written into before it is uploaded. *)

let api_lines gh args =
  let* out = gh args in
  Ok (List.filter (fun l -> l <> "") (String.split_on_char '\n' out))

(* THE TOOL'S OWN CLONE (ISS-52997): a bare clone without file contents (--filter=blob:none) of the
   repository the drafts are on, at ~/.digestif/update/<owner>-<name>.git, made on the first run and
   fetched every run after. Commit titles and the relay's paths are read from it, so a version's
   commits cost one fetch, not a GitHub request each. It is never a checkout anyone works in. *)
let clone_path repo =
  Filename.concat
    (Filename.concat (Filename.concat (Sys.getenv "HOME") ".digestif") "update")
    (String.map (fun c -> if c = '/' then '-' else c) repo ^ ".git")

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ())

(* Clone [repo] into [clone] when it is not there yet, then fetch every tag. *)
let sync_clone ~git ~say ~repo ~clone =
  let* () =
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
            "--filter=blob:none";
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

let tag_commit ~gh ~repo tag =
  let* sha =
    gh [ "api"; Printf.sprintf "repos/%s/commits/%s" repo tag; "--jq"; ".sha" ]
  in
  Ok (String.trim sha)

(* The commit [tag] names in the clone, refused unless it is the one GitHub reports ([commit]): the
   clone is trusted for nothing GitHub's own answer does not vouch for. *)
let check_tag ~git ~clone ~tag commit =
  let* local =
    git [ "-C"; clone; "rev-parse"; "--verify"; tag ^ "^{commit}" ]
  in
  let local = String.trim local in
  if local = commit then Ok ()
  else
    Error
      (Printf.sprintf
         "%s is commit %s in %s but %s on GitHub; refusing to read its commits \
          from that clone"
         tag local clone commit)

(* Every tag a range reads checked against GitHub: [tag] at [commit], and [since] at what GitHub
   reports for it. *)
let check_range ~gh ~git ~repo ~clone ~since ~tag commit =
  let* () = check_tag ~git ~clone ~tag commit in
  match since with
  | None -> Ok ()
  | Some last ->
      let* c = tag_commit ~gh ~repo last in
      check_tag ~git ~clone ~tag:last c

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

(* The html_url of the newest run of [workflow] the tag's push started, if any. *)
let run_url ~gh ~repo ~workflow tag =
  match
    gh
      [
        "api";
        Printf.sprintf
          "repos/%s/actions/workflows/%s/runs?event=push&branch=%s&per_page=1"
          repo workflow tag;
        "--jq";
        ".workflow_runs[0].html_url // empty";
      ]
  with
  | Ok u when String.trim u <> "" -> Some (String.trim u)
  | _ -> None

(* A node draft's manifest.json, its bytes and what they say, refused unless it names the draft's
   version. *)
let node_manifest ~gh ~repo (release : draft) =
  let* manifest_asset = manifest_asset release in
  let* bytes = download_asset ~gh ~repo manifest_asset in
  let* manifest =
    Result.map_error
      (fun e -> release.tag ^ "'s manifest.json: " ^ e)
      (Release.manifest_of_string bytes)
  in
  if Version.equal manifest.version release.version then Ok (bytes, manifest)
  else
    Error
      (Printf.sprintf "%s's manifest names version %s; refusing to sign it"
         release.tag
         (Version.to_string manifest.version))

(* Of [required], the signers whose signature asset is on the draft. *)
let signed_on ~(required : Release.signer list) (release : draft) =
  List.filter
    (fun (s : Release.signer) ->
      List.exists (fun a -> a.name = signature_asset_name s.key) release.assets)
    required

let show ~gh ~git ~clone ~signers ~repo ~releases (release : draft)
    (bytes, (manifest : Release.manifest)) =
  let* commit = tag_commit ~gh ~repo release.tag in
  let run_url = run_url ~gh ~repo ~workflow:"release.yml" release.tag in
  let since = Option.map (fun p -> p.tag) (last_published releases release) in
  let* () = check_range ~gh ~git ~repo ~clone ~since ~tag:release.tag commit in
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
      },
      bytes )

(* Sign [bytes] over [domain] with the key [read_key] prints, refusing a key that is not among
   [required]; the signature is written into [tmp] under the asset name its key gives it. *)
let sign_to_file ~domain ~required ~read_key ~tmp bytes =
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
  let sigs = Release.add_signature ~domain ~secret bytes [] in
  let path = Filename.concat tmp (signature_asset_name pub) in
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc (Release.signatures_to_string sigs));
  Ok (me, path)

(* Sign [bytes] with the key [read_key] prints, refusing a key the release does not need. *)
let signature_file ~signers ~read_key ~tmp (s : shown) bytes =
  sign_to_file ~domain:Release.release_domain
    ~required:(required ~signers s.manifest)
    ~read_key ~tmp bytes

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

let raw_content ~gh ~repo ~ref_ path =
  gh
    [
      "api";
      "-H";
      "Accept: application/vnd.github.raw";
      Printf.sprintf "repos/%s/contents/%s?ref=%s" repo path ref_;
    ]

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

(* A migration the version adds, with its full text as the tag holds it, checked against the
   manifest's sha256. *)
type added = {
  migration_name : string;
  text : (string, string) result;
  matches : bool;  (** The text's sha256 is the manifest's. *)
}

(* A relay as the signer's own node reads it: its url and the relay_version GET /v0/circle answers,
   None for a relay built before relay releases, or why it could not be read. *)
type relay_read = string * (string option, string) result

type relay_shown = {
  relay_release : draft;
  relay_commit : string;
  relay_run_url : string option;
  relay_since : string option;
  relay_titles : string list;
  relay_titles_note : string option;
  relay_compare_url : string;
  relay_manifest : Release.relay_manifest;
  added : added list;
  relays : relay_read list option;  (** None: no node runs on this machine. *)
  relay_already : Release.signer list;
  relay_remaining : int;  (** Required signatures not on the draft yet. *)
}

let relay_manifest_of ~gh ~repo (release : draft) =
  let* a = manifest_asset release in
  let* bytes = download_asset ~gh ~repo a in
  let* m =
    Result.map_error
      (fun e -> release.tag ^ "'s manifest.json: " ^ e)
      (Release.relay_manifest_of_string bytes)
  in
  Ok (bytes, m)

let added_migrations ~gh ~repo ~tag ~(before : Release.relay_manifest option)
    (m : Release.relay_manifest) =
  let had =
    match before with
    | None -> []
    | Some b ->
        List.map (fun (g : Release.relay_migration) -> g.migration) b.migrations
  in
  List.filter_map
    (fun (g : Release.relay_migration) ->
      if List.mem g.migration had then None
      else
        let text =
          raw_content ~gh ~repo ~ref_:tag ("relay/migrations/" ^ g.migration)
        in
        let matches =
          match text with
          | Ok t -> Keys.hash_of_bytes t = g.migration_sha256
          | Error _ -> false
        in
        Some { migration_name = g.migration; text; matches })
    m.migrations

let show_relay ~gh ~git ~clone ~signers ~repo ~relays ~releases
    (release : draft) =
  let* bytes, manifest = relay_manifest_of ~gh ~repo release in
  let* () =
    if Version.equal manifest.relay_version release.version then Ok ()
    else
      Error
        (Printf.sprintf "%s's manifest names version %s; refusing to sign it"
           release.tag
           (Version.to_string manifest.relay_version))
  in
  let* commit = tag_commit ~gh ~repo release.tag in
  let run_url = run_url ~gh ~repo ~workflow:"relay-release.yml" release.tag in
  let last = last_published releases release in
  let since = Option.map (fun p -> p.tag) last in
  let* () = check_range ~gh ~git ~repo ~clone ~since ~tag:release.tag commit in
  let* titles, compare_url, note =
    relay_titles ~git ~repo ~clone ~since release.tag
  in
  let* before =
    match last with
    | None -> Ok None
    | Some p ->
        let* _, m = relay_manifest_of ~gh ~repo p in
        Ok (Some m)
  in
  let added = added_migrations ~gh ~repo ~tag:release.tag ~before manifest in
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
        relays = relays ();
        relay_already = already;
        relay_remaining;
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
        "  (GitHub holds no digest for the draft's file)"
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
  line "  built   %s"
    (Option.value s.relay_run_url
       ~default:"(no Relay release run found for the tag)");
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
  | [] -> line "Migrations: this version adds none."
  | l ->
      line
        "Migrations this version adds, in full (a rollback replaces the Worker \
         and never undoes one):";
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
          line "  %s %s%s" a.migration_name sha
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
      line "Every relay, as this node reads it now:";
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
  Buffer.contents b

(* What the relay line needs beyond gh: every relay's version as this machine's node reads it
   (None when no node runs here), and the three steps of relay-publish (Relay_publish.run), run when
   the signature just uploaded completes the signer set. *)
type relay = {
  relay_versions : unit -> relay_read list option;
  publish : Version.t -> (unit, string) result;
}

let no_relay = { relay_versions = (fun () -> None); publish = (fun _ -> Ok ()) }

(* Whether a draft's files are not the ones its manifest names: an archive or bundle missing from
   the draft, or differing from it. An older version's line says so, as the newest's full summary
   does on its digest lines. *)
let flagged line =
  Layout.contains ~sub:"NOT ON THE DRAFT" line
  || Layout.contains ~sub:"DIFFERS FROM" line

let node_problem (s : shown) =
  List.exists (fun a -> flagged (digest_line s.release a)) s.manifest.artifacts

let relay_problem (s : relay_shown) =
  flagged (bundle_line s.relay_release s.relay_manifest.bundle)

let signed_by_words = function
  | [] -> "nobody has signed it"
  | (l : Release.signer list) ->
      "signed by "
      ^ String.concat ", " (List.map (fun (x : Release.signer) -> x.name) l)

(* An older waiting version in one line: who signed it, and whether its files match. *)
let older_line ~tag ~already ~problem =
  Printf.sprintf "  also %s: %s%s" tag (signed_by_words already)
    (if problem then "; ITS FILES DO NOT MATCH ITS MANIFEST" else "")

type node_version = { node : shown; node_bytes : string }
type relay_version = { relay : relay_shown; relay_bytes : string }

let missing ~signers ~(signed_by : Release.signer list) =
  List.filter
    (fun (x : Release.signer) ->
      not (List.exists (fun (y : Release.signer) -> y.key = x.key) signed_by))
    signers

(* Sign one node version and upload the signature. *)
let sign_node ~gh ~signers ~(config : config) ~read_key ~say ~tmp v =
  let s = v.node in
  let* me, path = signature_file ~signers ~read_key ~tmp s v.node_bytes in
  let* () = upload ~gh ~repo:config.repo ~tag:s.release.tag path in
  say
    (Printf.sprintf "Signed %s as %s (%s) and uploaded %s to its draft release."
       s.release.tag me.name me.key (Filename.basename path));
  Ok me

let sign_relay ~gh ~signers ~(config : config) ~read_key ~say ~tmp v =
  let s = v.relay in
  let* me, path =
    sign_to_file ~domain:Release.relay_release_domain ~required:signers
      ~read_key ~tmp v.relay_bytes
  in
  let* () = upload ~gh ~repo:config.repo ~tag:s.relay_release.tag path in
  say
    (Printf.sprintf "Signed %s as %s (%s) and uploaded %s to its draft release."
       s.relay_release.tag me.name me.key (Filename.basename path));
  Ok me

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
      match relay.publish v.relay.relay_release.version with
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

let rec collect f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = collect f rest in
      Ok (y :: ys)

(* What the run shows: the newest version of each line in full, each older one in a line. A node
   version every signer has signed is named and left to the fleet's rollout. *)
let show_all ~say ~repo ~nodes ~relays =
  (match nodes with
  | [] -> say "No node version is waiting for signatures."
  | newest :: older ->
      say (render newest.node);
      List.iter
        (fun v ->
          say
            (older_line ~tag:v.node.release.tag ~already:v.node.already
               ~problem:(node_problem v.node)))
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
               ~already:v.relay.relay_already ~problem:(relay_problem v.relay)))
        older

(* THE VERSIONS OFFERED, of either line, signed or dropped by ONE answer: of each line's waiting
   drafts ({!waiting_all}), the newest and those one more signature completes ({!offered}), read
   from one listing of the releases, their commit titles from the tool's clone ({!sync_clone}), the
   key read once ({!once}). *)
let run ~gh ~git ~clone ~signers ~(config : config) ~read_key ~ask ~say ~tmp
    ~relay =
  let read_key = once read_key in
  let* listed = gh [ "api"; releases_path config.repo ] in
  let* node_releases = releases_of_string listed in
  let* relay_releases = relay_releases_of_string listed in
  let* unread = unread_drafts listed in
  match (waiting_all node_releases, waiting_all relay_releases) with
  | [], [] when unread <> [] -> Error (unread_line unread)
  | [], [] ->
      Error
        (Printf.sprintf "no version is waiting for signatures on %s" config.repo)
  | node_drafts, relay_drafts -> (
      let* node_drafts =
        collect
          (fun r ->
            let* m = node_manifest ~gh ~repo:config.repo r in
            let required = required ~signers (snd m) in
            Ok (r, m, List.length required - List.length (signed_on ~required r)))
          node_drafts
      in
      let node_drafts =
        offered ~remaining:(fun (_, _, n) -> n) node_drafts
        |> List.map (fun (r, m, _) -> (r, m))
      in
      let relay_offered =
        offered
          ~remaining:(fun r ->
            List.length signers - List.length (signed_on ~required:signers r))
          relay_drafts
      in
      let* () =
        if node_drafts = [] && relay_offered = [] then Ok ()
        else sync_clone ~git ~say ~repo:config.repo ~clone
      in
      let* nodes =
        collect
          (fun (r, m) ->
            let* node, node_bytes =
              show ~gh ~git ~clone ~signers ~repo:config.repo
                ~releases:node_releases r m
            in
            Ok { node; node_bytes })
          node_drafts
      in
      let done_, nodes = List.partition (fun v -> v.node.remaining = 0) nodes in
      List.iter
        (fun v ->
          say
            (Printf.sprintf
               "%s has every signature; the fleet's rollout publishes it."
               v.node.release.tag))
        done_;
      let* relays =
        collect
          (fun r ->
            let* relay, relay_bytes =
              show_relay ~gh ~git ~clone ~signers ~repo:config.repo
                ~relays:relay.relay_versions ~releases:relay_releases r
            in
            Ok { relay; relay_bytes })
          relay_offered
      in
      show_all ~say ~repo:config.repo ~nodes ~relays;
      let count = List.length nodes + List.length relays in
      let finish () =
        if unread <> [] then (
          say "";
          say (unread_line unread));
        Ok ()
      in
      if count = 0 then finish ()
      else
        match answer_of_string (ask (question ~count)) with
        | Leave ->
            say "Left waiting; nothing was signed.";
            finish ()
        | Drop ->
            let* () =
              each
                (fun tag -> drop ~gh ~repo:config.repo ~tag ~say)
                (List.map (fun v -> v.node.release.tag) nodes
                @ List.map (fun v -> v.relay.relay_release.tag) relays)
            in
            finish ()
        | Sign ->
            let* () =
              each
                (fun v ->
                  let* _ =
                    sign_node ~gh ~signers ~config ~read_key ~say ~tmp v
                  in
                  Ok ())
                nodes
            in
            let* me =
              match relays with
              | [] -> Ok []
              | _ ->
                  let* mes =
                    collect
                      (fun v ->
                        sign_relay ~gh ~signers ~config ~read_key ~say ~tmp v)
                      relays
                  in
                  Ok (match mes with m :: _ -> [ m ] | [] -> [])
            in
            let* () =
              if relays = [] then Ok ()
              else
                settle_relays ~gh ~signers ~config ~say ~relay ~me
                  ~waiting:relay_drafts relays
            in
            finish ())
