(* `digestif-update sign --next` (docs/releases.md, Signing a release): sign the version waiting for
   signatures, a draft GitHub release the Release workflow left. Everything it reads and writes on
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

(* Every release whose tag is v<MAJOR.MINOR.PATCH>; any other tag is not a version. *)
let releases_of_string bytes =
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
            if String.starts_with ~prefix:"v" tag then
              Version.of_string (String.sub tag 1 (String.length tag - 1))
            else Error "not a version"
          with
          | Ok version -> Ok (Some { tag; version; draft; assets })
          | Error _ -> Ok None)
        l
      |> Result.map (List.filter_map Fun.id)
  | _ -> Error "the releases list is not a list"

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

let show ~gh ~signers ~repo =
  let* listed =
    gh [ "api"; Printf.sprintf "repos/%s/releases?per_page=50" repo ]
  in
  let* releases = releases_of_string listed in
  let* release =
    match waiting releases with
    | Some r -> Ok r
    | None ->
        Error (Printf.sprintf "no version is waiting for signatures on %s" repo)
  in
  let* manifest_asset =
    match List.find_opt (fun a -> a.name = "manifest.json") release.assets with
    | Some a -> Ok a
    | None -> Error (release.tag ^ "'s draft holds no manifest.json yet")
  in
  let* bytes =
    gh
      [
        "api";
        "-H";
        "Accept: application/octet-stream";
        Printf.sprintf "repos/%s/releases/assets/%d" repo manifest_asset.id;
      ]
  in
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
  let* commit =
    gh
      [
        "api";
        Printf.sprintf "repos/%s/commits/%s" repo release.tag;
        "--jq";
        ".sha";
      ]
  in
  let run_url =
    match
      gh
        [
          "api";
          Printf.sprintf
            "repos/%s/actions/workflows/release.yml/runs?event=push&branch=%s&per_page=1"
            repo release.tag;
          "--jq";
          ".workflow_runs[0].html_url // empty";
        ]
    with
    | Ok u when String.trim u <> "" -> Some (String.trim u)
    | _ -> None
  in
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
        commit = String.trim commit;
        run_url;
        since;
        titles;
        compare_url;
        manifest;
        already;
      },
      bytes )

(* Sign [bytes] with the key [read_key] prints, refusing a key the release does not need. *)
let signature_file ~signers ~read_key ~tmp (s : shown) bytes =
  let* printed = read_key () in
  let* secret =
    Result.map_error
      (fun e -> "the key command's output: " ^ e)
      (Keys.decode_secret printed)
  in
  let pub = Keys.public secret in
  let* me =
    match
      List.find_opt
        (fun (x : Release.signer) -> x.key = pub)
        (required ~signers s.manifest)
    with
    | Some me -> Ok me
    | None ->
        Error
          (Printf.sprintf
             "your key %s is not a release signer; nothing was signed" pub)
  in
  let sigs =
    Release.add_signature ~domain:Release.release_domain ~secret bytes []
  in
  let path = Filename.concat tmp (signature_asset_name pub) in
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc (Release.signatures_to_string sigs));
  Ok (me, path)

let run ~gh ~signers ~(config : config) ~read_key ~ask ~say ~tmp =
  let* s, bytes = show ~gh ~signers ~repo:config.repo in
  say (render s);
  match answer_of_string (ask question) with
  | Leave ->
      say (s.release.tag ^ " is left waiting; nothing was signed.");
      Ok ()
  | Drop ->
      let* _ =
        gh
          [ "release"; "delete"; s.release.tag; "--repo"; config.repo; "--yes" ]
      in
      say
        (Printf.sprintf
           "Dropped %s: its draft release and every signature on it are \
            deleted. The tag stays."
           s.release.tag);
      Ok ()
  | Sign ->
      let* me, path = signature_file ~signers ~read_key ~tmp s bytes in
      let* _ =
        gh
          [
            "release";
            "upload";
            s.release.tag;
            path;
            "--repo";
            config.repo;
            "--clobber";
          ]
      in
      say
        (Printf.sprintf
           "Signed %s as %s (%s) and uploaded %s to its draft release."
           s.release.tag me.name me.key (Filename.basename path));
      Ok ()
