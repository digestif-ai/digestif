(* `digestif-update sign --next` (docs/releases.md, Signing a release and Signing a relay release):
   sign every version waiting for signatures, a draft GitHub release the Release workflow (the node
   line, v<version>) or the Relay release workflow (the relay line, relay-v<version>) left, the
   node line first. Everything it reads and writes on
   GitHub goes through the signer's own `gh` login, passed in as [gh] so the flow is tested without
   the network. It shows what the version holds before it reads the key, reads the key from the
   command the signer named in ~/.config/digestif/signer.json into memory only, and uploads the
   signature as one asset of the draft, named for the key, so two signers never write one file.

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

(* The version waiting for signatures: the newest draft that somebody has signed, since a signed
   version waits for the other signer however many newer ones were cut, else the newest draft. *)
let waiting releases =
  let drafts = List.filter (fun r -> r.draft) releases in
  let signed =
    List.filter
      (fun r -> List.exists (fun a -> is_signature_asset a.name) r.assets)
      drafts
  in
  match newest signed with Some r -> Some r | None -> newest drafts

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
}

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
  (match s.already with
  | [] -> line "Nobody has signed it yet."
  | l ->
      line "Already signed by: %s"
        (String.concat ", " (List.map (fun (x : Release.signer) -> x.name) l)));
  Buffer.contents b

type answer = Sign | Drop | Leave

let answer_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "s" -> Sign
  | "d" -> Drop
  | _ -> Leave

let question =
  "s signs, d drops this version, anything else leaves it waiting: "

(* The flow. [gh] runs `gh` with the arguments and answers its stdout; [read_key] runs the signer's
   key command and answers what it printed; [ask] shows the question and answers the reply; [say]
   prints a line; [tmp] is a directory the signature is written into before it is uploaded. *)

let api_lines gh args =
  let* out = gh args in
  Ok (List.filter (fun l -> l <> "") (String.split_on_char '\n' out))

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

let titles ~gh ~repo ~since tag =
  let jq = ".[] | .commit.message | split(\"\\n\")[0]" in
  match since with
  | Some last ->
      let* l =
        api_lines gh
          [
            "api";
            Printf.sprintf "repos/%s/compare/%s...%s" repo last tag;
            "--jq";
            ".commits" ^ jq;
          ]
      in
      Ok
        (l, Printf.sprintf "https://github.com/%s/compare/%s...%s" repo last tag)
  | None ->
      let* l =
        api_lines gh
          [
            "api";
            Printf.sprintf "repos/%s/commits?sha=%s&per_page=100" repo tag;
            "--jq";
            jq;
          ]
      in
      Ok
        ( List.map first_line l,
          Printf.sprintf "https://github.com/%s/commits/%s" repo tag )

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

let tag_commit ~gh ~repo tag =
  let* sha =
    gh [ "api"; Printf.sprintf "repos/%s/commits/%s" repo tag; "--jq"; ".sha" ]
  in
  Ok (String.trim sha)

let show ~gh ~signers ~repo ~releases (release : draft) =
  let* manifest_asset = manifest_asset release in
  let* bytes = download_asset ~gh ~repo manifest_asset in
  let* manifest =
    Result.map_error
      (fun e -> release.tag ^ "'s manifest.json: " ^ e)
      (Release.manifest_of_string bytes)
  in
  let* () =
    if Version.equal manifest.version release.version then Ok ()
    else
      Error
        (Printf.sprintf "%s's manifest names version %s; refusing to sign it"
           release.tag
           (Version.to_string manifest.version))
  in
  let* commit = tag_commit ~gh ~repo release.tag in
  let run_url = run_url ~gh ~repo ~workflow:"release.yml" release.tag in
  let since = Option.map (fun p -> p.tag) (last_published releases release) in
  let* titles, compare_url = titles ~gh ~repo ~since release.tag in
  let already =
    List.filter
      (fun (s : Release.signer) ->
        List.exists
          (fun a -> a.name = signature_asset_name s.key)
          release.assets)
      (required ~signers manifest)
  in
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

(* ci/relay-release-paths, in ci/release-paths's format: one git pathspec per line. Only the
   magic this repository's path files use is read: a plain path names itself and everything under
   it, :(glob) a pattern where ** crosses directories and * and ? do not, and :(exclude) or :!
   takes a match back out. *)
type pathspec = { exclude : bool; glob : bool; pattern : string }

let pathspec_of_line line =
  let line = String.trim line in
  if line = "" || line.[0] = '#' then None
  else if String.starts_with ~prefix:":(" line then
    match String.index_opt line ')' with
    | None -> Some { exclude = false; glob = false; pattern = line }
    | Some close ->
        let magic =
          String.split_on_char ',' (String.sub line 2 (close - 2))
          |> List.map String.trim
        in
        Some
          {
            exclude = List.mem "exclude" magic;
            glob = List.mem "glob" magic;
            pattern =
              String.sub line (close + 1) (String.length line - close - 1);
          }
  else if
    String.starts_with ~prefix:":!" line || String.starts_with ~prefix:":^" line
  then
    Some
      {
        exclude = true;
        glob = false;
        pattern = String.sub line 2 (String.length line - 2);
      }
  else Some { exclude = false; glob = false; pattern = line }

let pathspecs_of_string s =
  List.filter_map pathspec_of_line (String.split_on_char '\n' s)

let glob_matches pattern path =
  let pn = String.length pattern and sn = String.length path in
  let rec go i j =
    if i = pn then j = sn
    else if i + 1 < pn && pattern.[i] = '*' && pattern.[i + 1] = '*' then
      let slash = i + 2 < pn && pattern.[i + 2] = '/' in
      let i' = if slash then i + 3 else i + 2 in
      let rec from k =
        k <= sn
        && ((((not slash) || k = j || path.[k - 1] = '/') && go i' k)
           || from (k + 1))
      in
      from j
    else if pattern.[i] = '*' then
      let rec from k =
        k <= sn && (go (i + 1) k || (k < sn && path.[k] <> '/' && from (k + 1)))
      in
      from j
    else if pattern.[i] = '?' then
      j < sn && path.[j] <> '/' && go (i + 1) (j + 1)
    else j < sn && pattern.[i] = path.[j] && go (i + 1) (j + 1)
  in
  go 0 0

let spec_matches spec path =
  if spec.glob then glob_matches spec.pattern path
  else
    let p =
      if String.ends_with ~suffix:"/" spec.pattern then
        String.sub spec.pattern 0 (String.length spec.pattern - 1)
      else spec.pattern
    in
    path = p || String.starts_with ~prefix:(p ^ "/") path

(* Whether [path] is a relay release path: named by a pathspec and taken out by none. *)
let in_paths specs path =
  List.exists (fun s -> (not s.exclude) && spec_matches s path) specs
  && not (List.exists (fun s -> s.exclude && spec_matches s path) specs)

let relay_paths_file = "ci/relay-release-paths"

let raw_content ~gh ~repo ~ref_ path =
  gh
    [
      "api";
      "-H";
      "Accept: application/vnd.github.raw";
      Printf.sprintf "repos/%s/contents/%s?ref=%s" repo path ref_;
    ]

let is_not_found e =
  let has sub =
    let n = String.length sub and m = String.length e in
    let rec at i = i + n <= m && (String.sub e i n = sub || at (i + 1)) in
    at 0
  in
  has "404" || has "Not Found"

(* The relay release paths at [tag], or None when the tag carries no ci/relay-release-paths. *)
let relay_paths ~gh ~repo tag =
  match raw_content ~gh ~repo ~ref_:tag relay_paths_file with
  | Ok s -> Ok (Some (pathspecs_of_string s))
  | Error e when is_not_found e -> Ok None
  | Error e -> Error (relay_paths_file ^ " at " ^ tag ^ ": " ^ e)

(* The commits between the last published relay version and [tag] (the newest 100 before the
   first), as sha and title, each kept only when a file it changed is a relay release path. A tag
   without the paths file shows every commit and says so. *)
let relay_titles ~gh ~repo ~say ~since tag =
  let jq = "[.sha, (.commit.message | split(\"\\n\")[0])] | @tsv" in
  let* lines, compare_url =
    match since with
    | Some last ->
        let* l =
          api_lines gh
            [
              "api";
              Printf.sprintf "repos/%s/compare/%s...%s" repo last tag;
              "--jq";
              ".commits[] | " ^ jq;
            ]
        in
        Ok
          ( l,
            Printf.sprintf "https://github.com/%s/compare/%s...%s" repo last tag
          )
    | None ->
        let* l =
          api_lines gh
            [
              "api";
              Printf.sprintf "repos/%s/commits?sha=%s&per_page=100" repo tag;
              "--jq";
              ".[] | " ^ jq;
            ]
        in
        Ok (l, Printf.sprintf "https://github.com/%s/commits/%s" repo tag)
  in
  let commits =
    List.map
      (fun l ->
        match String.index_opt l '\t' with
        | Some i ->
            (String.sub l 0 i, String.sub l (i + 1) (String.length l - i - 1))
        | None -> (l, l))
      lines
  in
  let* specs = relay_paths ~gh ~repo tag in
  match specs with
  | None ->
      Ok
        ( List.map snd commits,
          compare_url,
          Some
            (Printf.sprintf
               "%s is not at %s, so every commit is shown, not only those \
                touching the relay"
               relay_paths_file tag) )
  | Some specs ->
      (* One request per commit, which on the first relay version is the whole history: say so
         before the first, and every 25 after, so a long read never looks hung. *)
      let n = List.length commits in
      if n > 0 then
        say
          (Printf.sprintf
             "Reading which of the %d commit(s) since %s touch the relay, one \
              GitHub request each..."
             n
             (Option.value since ~default:"the first commit"));
      let* kept =
        Release.all
          (fun (i, (sha, title)) ->
            if i > 0 && i mod 25 = 0 then say (Printf.sprintf "  %d of %d" i n);
            let* files =
              api_lines gh
                [
                  "api";
                  Printf.sprintf "repos/%s/commits/%s" repo sha;
                  "--jq";
                  ".files[].filename";
                ]
            in
            Ok (if List.exists (in_paths specs) files then Some title else None))
          (List.mapi (fun i c -> (i, c)) commits)
      in
      Ok (List.filter_map Fun.id kept, compare_url, None)

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

let show_relay ~gh ~signers ~repo ~say ~relays ~releases (release : draft) =
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
  let* titles, compare_url, note =
    relay_titles ~gh ~repo ~say ~since release.tag
  in
  let* before =
    match last with
    | None -> Ok None
    | Some p ->
        let* _, m = relay_manifest_of ~gh ~repo p in
        Ok (Some m)
  in
  let added = added_migrations ~gh ~repo ~tag:release.tag ~before manifest in
  let already =
    List.filter
      (fun (s : Release.signer) ->
        List.exists
          (fun a -> a.name = signature_asset_name s.key)
          release.assets)
      signers
  in
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
  (match s.relay_already with
  | [] -> line "Nobody has signed it yet."
  | l ->
      line "Already signed by: %s"
        (String.concat ", " (List.map (fun (x : Release.signer) -> x.name) l)));
  Buffer.contents b

(* What the relay line needs beyond gh: every relay's version as this machine's node reads it
   (None when no node runs here), and the three steps of relay-publish (Relay_publish.run), run when
   the signature just uploaded completes the signer set. *)
type relay = {
  relay_versions : unit -> relay_read list option;
  publish : Version.t -> (unit, string) result;
}

let no_relay = { relay_versions = (fun () -> None); publish = (fun _ -> Ok ()) }

let relay_line ~gh ~signers ~(config : config) ~read_key ~ask ~say ~tmp
    ~(relay : relay) ~releases release =
  let* s, bytes =
    show_relay ~gh ~signers ~repo:config.repo ~say ~relays:relay.relay_versions
      ~releases release
  in
  let tag = s.relay_release.tag in
  say (render_relay ~repo:config.repo s);
  match answer_of_string (ask question) with
  | Leave ->
      say (tag ^ " is left waiting; nothing was signed.");
      Ok ()
  | Drop -> drop ~gh ~repo:config.repo ~tag ~say
  | Sign -> (
      let* me, path =
        sign_to_file ~domain:Release.relay_release_domain ~required:signers
          ~read_key ~tmp bytes
      in
      let* () = upload ~gh ~repo:config.repo ~tag path in
      say
        (Printf.sprintf
           "Signed %s as %s (%s) and uploaded %s to its draft release." tag
           me.name me.key (Filename.basename path));
      let signed_by = me :: s.relay_already in
      match
        List.filter
          (fun (x : Release.signer) ->
            not
              (List.exists
                 (fun (y : Release.signer) -> y.key = x.key)
                 signed_by))
          signers
      with
      | [] -> (
          say
            (Printf.sprintf
               "Your signature completes the signer set, so %s is published \
                now:"
               tag);
          match relay.publish s.relay_release.version with
          | Ok () -> Ok ()
          | Error e ->
              Error
                (Printf.sprintf
                   "%s is signed by every signer but was not published: %s. \
                    Run ci/release.sh relay-publish --version %s to publish \
                    it."
                   tag e
                   (Version.to_string s.relay_release.version)))
      | waiting ->
          say
            (Printf.sprintf "%s waits for %s." tag
               (String.concat ", "
                  (List.map (fun (x : Release.signer) -> x.name) waiting)));
          Ok ())

let node_line ~gh ~signers ~(config : config) ~read_key ~ask ~say ~tmp ~releases
    release =
  let* s, bytes = show ~gh ~signers ~repo:config.repo ~releases release in
  say (render s);
  match answer_of_string (ask question) with
  | Leave ->
      say (s.release.tag ^ " is left waiting; nothing was signed.");
      Ok ()
  | Drop -> drop ~gh ~repo:config.repo ~tag:s.release.tag ~say
  | Sign ->
      let* me, path = signature_file ~signers ~read_key ~tmp s bytes in
      let* () = upload ~gh ~repo:config.repo ~tag:s.release.tag path in
      say
        (Printf.sprintf
           "Signed %s as %s (%s) and uploaded %s to its draft release."
           s.release.tag me.name me.key (Filename.basename path));
      Ok ()

let releases_path repo = Printf.sprintf "repos/%s/releases?per_page=50" repo

(* Every version waiting for signatures, of either line, asked about in turn: the node line first,
   then the relay line. Both are read from one listing of the releases. *)
let run ~gh ~signers ~(config : config) ~read_key ~ask ~say ~tmp ~relay =
  let* listed = gh [ "api"; releases_path config.repo ] in
  let* node_releases = releases_of_string listed in
  let* relay_releases = relay_releases_of_string listed in
  let* unread = unread_drafts listed in
  match (waiting node_releases, waiting relay_releases) with
  | None, None when unread <> [] -> Error (unread_line unread)
  | None, None ->
      Error
        (Printf.sprintf "no version is waiting for signatures on %s" config.repo)
  | node, relay_release ->
      let* () =
        match node with
        | None ->
            say "No node version is waiting for signatures.";
            Ok ()
        | Some r ->
            node_line ~gh ~signers ~config ~read_key ~ask ~say ~tmp
              ~releases:node_releases r
      in
      Option.fold ~none:(Ok ())
        ~some:(fun r ->
          say "";
          relay_line ~gh ~signers ~config ~read_key ~ask ~say ~tmp ~relay
            ~releases:relay_releases r)
        relay_release
      |> Result.map (fun () ->
          if unread <> [] then (
            say "";
            say (unread_line unread)))
