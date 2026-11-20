(* THE BUILD THAT MADE A RELEASE'S FILES (docs/releases.md, What ties a version to its build): the
   Release workflow (release.yml) and the Relay release workflow (relay-release.yml) attest every
   file they leave on a draft, the manifest among them, in one GitHub artifact attestation: a
   Sigstore certificate GitHub issues to that workflow's run, naming the workflow, the ref it ran
   on, the commit it built and the run, over a statement listing every file's sha256. `sign --next`
   asks `gh attestation verify`, of the manifest's own bytes, whether that workflow, run on the tag
   at the commit the signer is shown, on a GitHub-hosted runner, attested them; the statement gh
   verified then names the sha256 of every other file the manifest names, so no archive is
   downloaded to be checked (DIG-305). A file anyone with write access replaced on the draft has
   another sha256, which GitHub's digest of the draft's file shows and no attestation names, so the
   version is not offered for signing. gh checks the certificate's identity; the certificate it
   answers is read back here and checked again, so a gh that ignored a flag still offers nothing it
   should not.

   The Sigstore trusted root gh verifies against is fetched once per run ([trusted_root]) rather
   than by every verify, and what verified is remembered ({!cache}): a later run that reads the
   same manifest of the same tag at the same commit takes the answer it already checked. *)

let ( let* ) = Result.bind

(* What gh is asked for the file at [path]: an attestation by [workflow] of [repo], on the tag, of
   [commit], made on a GitHub-hosted runner, as JSON, checked against [trusted_root] when the run
   fetched one. *)
let verify_args ?trusted_root ~repo ~workflow ~tag ~commit path =
  [
    "attestation";
    "verify";
    path;
    "--repo";
    repo;
    "--signer-workflow";
    Printf.sprintf "%s/.github/workflows/%s" repo workflow;
    "--source-ref";
    "refs/tags/" ^ tag;
    "--source-digest";
    commit;
    "--deny-self-hosted-runners";
    "--format";
    "json";
  ]
  @
  match trusted_root with
  | Some p -> [ "--custom-trusted-root"; p ]
  | None -> []

(* What gh is asked for the Sigstore trusted root, once per run. *)
let trusted_root_args = [ "attestation"; "trusted-root" ]

let rec path json = function
  | [] -> Some json
  | k :: rest -> (
      match Release.field k json with Some j -> path j rest | None -> None)

let str json keys =
  match path json keys with Some (`String s) -> Some s | _ -> None

let hex sha256 =
  let p = Keys.sha256_prefix in
  if String.starts_with ~prefix:p sha256 then
    String.sub sha256 (String.length p) (String.length sha256 - String.length p)
  else sha256

(* One attestation gh verified whose certificate is the workflow's: the run that made it and the
   sha256 (hex) of every file its statement names. *)
type attested = { run : string; subjects : string list }

(* Every verified attestation in gh's JSON answer whose certificate is [workflow] of [repo] on the
   tag, at [commit], on a GitHub-hosted runner. *)
let attested_of_json ~repo ~workflow ~tag ~commit bytes =
  let* json = Release.parse_json "gh attestation verify's answer" bytes in
  let ref_ = "refs/tags/" ^ tag in
  let signer =
    String.lowercase_ascii
      (Printf.sprintf "https://github.com/%s/.github/workflows/%s@%s" repo
         workflow ref_)
  in
  let same a b = String.lowercase_ascii a = String.lowercase_ascii b in
  let subjects result =
    match path result [ "verificationResult"; "statement"; "subject" ] with
    | Some (`List subjects) ->
        List.filter_map (fun s -> str s [ "digest"; "sha256" ]) subjects
    | _ -> []
  in
  match json with
  | `List results ->
      Ok
        (List.filter_map
           (fun result ->
             let cert k =
               str result
                 [ "verificationResult"; "signature"; "certificate"; k ]
             in
             match
               ( cert "buildSignerURI",
                 cert "sourceRepositoryRef",
                 cert "sourceRepositoryDigest",
                 cert "runnerEnvironment",
                 cert "runInvocationURI" )
             with
             | Some s, Some r, Some d, Some "github-hosted", Some run
               when String.lowercase_ascii s = signer
                    && r = ref_ && same d commit ->
                 Some { run; subjects = subjects result }
             | _ -> None)
           results)
  | _ -> Error "gh attestation verify's answer is not a list"

(* The runs of [attested] whose statement names [sha256]. *)
let runs_naming ~sha256 attested =
  List.filter_map
    (fun a -> if List.mem (hex sha256) a.subjects then Some a.run else None)
    attested

(* The run urls of every verified attestation in gh's JSON answer whose certificate is [workflow]
   of [repo] on the tag, at [commit], on a GitHub-hosted runner, and whose statement names
   [sha256]. *)
let runs_of_json ~repo ~workflow ~tag ~commit ~sha256 bytes =
  let* attested = attested_of_json ~repo ~workflow ~tag ~commit bytes in
  Ok (runs_naming ~sha256 attested)

(* WHAT ALREADY VERIFIED (DIG-305): per manifest, the tag, its sha256, the workflow and commit it
   was verified for, and the attestations that passed. [find] answers what was remembered of the
   tag's manifest with that sha256, [knows] whether anything is remembered of the tag, and [add]
   remembers a verify that found attestations. *)
type key = {
  tag : string;
  manifest : string;
  workflow : string;
  commit : string;
}

type cache = {
  find : tag:string -> manifest:string -> (key * attested list) option;
  knows : tag:string -> bool;
  add : key -> attested list -> unit;
}

let no_cache =
  {
    find = (fun ~tag:_ ~manifest:_ -> None);
    knows = (fun ~tag:_ -> false);
    add = (fun _ _ -> ());
  }

(* The cache as a JSON file at [path], the newest [keep] manifests kept. A file that cannot be read
   is an empty cache, and one that cannot be written is skipped: either costs only a verify. *)
let entry_to_json (k, l) =
  `Assoc
    [
      ("tag", `String k.tag);
      ("manifest", `String k.manifest);
      ("workflow", `String k.workflow);
      ("commit", `String k.commit);
      ( "attested",
        `List
          (List.map
             (fun a ->
               `Assoc
                 [
                   ("run", `String a.run);
                   ("subjects", `List (List.map (fun s -> `String s) a.subjects));
                 ])
             l) );
    ]

let entry_of_json json =
  let s k = str json [ k ] in
  match
    (s "tag", s "manifest", s "workflow", s "commit", path json [ "attested" ])
  with
  | Some tag, Some manifest, Some workflow, Some commit, Some (`List l) ->
      let attested =
        List.filter_map
          (fun a ->
            match (str a [ "run" ], path a [ "subjects" ]) with
            | Some run, Some (`List subjects) ->
                Some
                  {
                    run;
                    subjects =
                      List.filter_map
                        (function `String s -> Some s | _ -> None)
                        subjects;
                  }
            | _ -> None)
          l
      in
      Some ({ tag; manifest; workflow; commit }, attested)
  | _ -> None

let file_cache ?(keep = 200) path =
  let lock = Mutex.create () in
  let read () =
    match In_channel.with_open_bin path In_channel.input_all with
    | exception Sys_error _ -> []
    | bytes -> (
        match Yojson.Safe.from_string bytes with
        | `List l -> List.filter_map entry_of_json l
        | _ | (exception Yojson.Json_error _) -> [])
  in
  let write entries =
    let tmp = path ^ ".tmp" in
    try
      Out_channel.with_open_bin tmp (fun oc ->
          Out_channel.output_string oc
            (Yojson.Safe.to_string (`List (List.map entry_to_json entries))));
      Sys.rename tmp path
    with Sys_error _ -> ()
  in
  {
    find =
      (fun ~tag ~manifest ->
        Mutex.protect lock (fun () ->
            List.find_opt
              (fun (k, _) -> k.tag = tag && k.manifest = manifest)
              (read ())));
    knows =
      (fun ~tag ->
        Mutex.protect lock (fun () ->
            List.exists (fun (k, _) -> k.tag = tag) (read ())));
    add =
      (fun k l ->
        Mutex.protect lock (fun () ->
            let others = List.filter (fun (o, _) -> o <> k) (read ()) in
            write (List.filteri (fun i _ -> i < keep) ((k, l) :: others))));
  }

(* A file the manifest names: its name on the draft and the sha256 the manifest gives it. *)
type file = { name : string; sha256 : string }

type checked = {
  run_url : string option;
      (** The run that attests every file, when one does and nothing failed. *)
  problems : string list;  (** Why a file is not the one the build made. *)
}

(* The attestations of the manifest whose bytes are [manifest], as [cache] remembers them for this
   workflow and commit, or as gh verifies them now (the manifest written into [dir]). *)
let manifest_attested ~gh ?trusted_root ~cache ~repo ~workflow ~tag ~commit ~dir
    manifest =
  let sha256 = Keys.hash_of_bytes manifest in
  let key = { tag; manifest = sha256; workflow; commit } in
  match cache.find ~tag ~manifest:sha256 with
  | Some (k, l) when k = key && l <> [] -> Ok l
  | _ -> (
      let rec mkdir_p d =
        if not (Sys.file_exists d) then (
          mkdir_p (Filename.dirname d);
          try Sys.mkdir d 0o700 with Sys_error _ when Sys.file_exists d -> ())
      in
      mkdir_p dir;
      let file = Filename.concat dir "manifest.json" in
      Out_channel.with_open_bin file (fun oc ->
          Out_channel.output_string oc manifest);
      match
        gh (verify_args ?trusted_root ~repo ~workflow ~tag ~commit file)
      with
      | Error e ->
          Error
            (Printf.sprintf
               "%s; a gh whose attestation verify lacks --source-digest is too \
                old"
               e)
      | Ok out ->
          let* l = attested_of_json ~repo ~workflow ~tag ~commit out in
          if l <> [] then cache.add key l;
          Ok l)

(* Check the manifest whose bytes are [manifest] and every one of [files] against the attestation
   gh verifies of the manifest: each must be named by an attestation of [workflow] on the tag at
   [commit], and one run must attest them all. *)
let check ~gh ?trusted_root ?(cache = no_cache) ~repo ~workflow ~tag ~commit
    ~dir ~manifest files =
  let attested, why =
    match
      manifest_attested ~gh ?trusted_root ~cache ~repo ~workflow ~tag ~commit
        ~dir manifest
    with
    | Ok l -> (l, "")
    | Error e -> ([], " (" ^ e ^ ")")
  in
  let all =
    { name = "manifest.json"; sha256 = Keys.hash_of_bytes manifest } :: files
  in
  let results =
    List.map
      (fun f ->
        match runs_naming ~sha256:f.sha256 attested with
        | [] ->
            Error
              (Printf.sprintf
                 "%s: no attestation by %s on %s at %s, made on a \
                  GitHub-hosted runner, names it%s"
                 f.name workflow tag commit
                 (if f.name = "manifest.json" then why else ""))
        | runs -> Ok runs)
      all
  in
  let problems =
    List.filter_map (function Error e -> Some e | Ok _ -> None) results
  in
  let attested = List.filter_map Result.to_option results in
  match attested with
  | [] -> { run_url = None; problems }
  | first :: rest -> (
      let common =
        List.filter
          (fun run -> List.for_all (fun runs -> List.mem run runs) rest)
          (List.sort_uniq compare first)
      in
      match common with
      | run :: _ -> { run_url = Some run; problems }
      | [] ->
          {
            run_url = None;
            problems =
              problems
              @ [
                  Printf.sprintf "no one run of %s attests every file" workflow;
                ];
          })
