(* THE BUILD THAT MADE A RELEASE'S FILES (docs/releases.md, What ties a version to its build): the
   Release workflow (release.yml) and the Relay release workflow (relay-release.yml) attest every
   file they leave on a draft with a GitHub artifact attestation, a Sigstore certificate GitHub
   issues to that workflow's run, naming the workflow, the ref it ran on, the commit it built and
   the run. `sign --next` downloads each file a draft's manifest names, and the manifest itself,
   checks each against the manifest's sha256, and asks `gh attestation verify` whether that
   workflow, run on the tag at the commit the signer is shown, on a GitHub-hosted runner, attested
   those exact bytes. A file anyone with write access replaced on the draft has no such
   attestation, so the version is not offered for signing. gh checks the certificate's identity;
   the certificate it answers is read back here and checked again, so a gh that ignored a flag
   still offers nothing it should not. *)

let ( let* ) = Result.bind

(* What gh is asked for one file at [path]: an attestation by [workflow] of [repo], on the tag, of
   [commit], made on a GitHub-hosted runner, as JSON. *)
let verify_args ~repo ~workflow ~tag ~commit path =
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

(* The run urls of every verified attestation in gh's JSON answer whose certificate is [workflow]
   of [repo] on the tag, at [commit], on a GitHub-hosted runner, and whose statement names
   [sha256]. *)
let runs_of_json ~repo ~workflow ~tag ~commit ~sha256 bytes =
  let* json = Release.parse_json "gh attestation verify's answer" bytes in
  let ref_ = "refs/tags/" ^ tag in
  let signer =
    String.lowercase_ascii
      (Printf.sprintf "https://github.com/%s/.github/workflows/%s@%s" repo
         workflow ref_)
  in
  let same a b = String.lowercase_ascii a = String.lowercase_ascii b in
  let names_digest result =
    match path result [ "verificationResult"; "statement"; "subject" ] with
    | Some (`List subjects) ->
        List.exists
          (fun s -> str s [ "digest"; "sha256" ] = Some (hex sha256))
          subjects
    | _ -> false
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
                    && r = ref_ && same d commit && names_digest result ->
                 Some run
             | _ -> None)
           results)
  | _ -> Error "gh attestation verify's answer is not a list"

(* The runs that attest the file at [path], whose sha256 is [sha256]; an error says why none
   does. *)
let runs ~gh ~repo ~workflow ~tag ~commit ~sha256 path =
  match gh (verify_args ~repo ~workflow ~tag ~commit path) with
  | Error e ->
      Error
        (Printf.sprintf
           "no attestation by %s on %s at %s (%s; a gh whose attestation \
            verify lacks --source-digest is too old)"
           workflow tag commit e)
  | Ok out -> (
      match runs_of_json ~repo ~workflow ~tag ~commit ~sha256 out with
      | Ok [] ->
          Error
            (Printf.sprintf
               "no attestation by %s on %s at %s on a GitHub-hosted runner"
               workflow tag commit)
      | r -> r)

(* A file to check: its name on the draft, the sha256 the manifest gives it, and how to read its
   bytes. *)
type file = {
  name : string;
  sha256 : string;
  fetch : unit -> (string, string) result;
}

type checked = {
  run_url : string option;
      (** The run that attests every file, when one does and nothing failed. *)
  problems : string list;  (** Why a file is not the one the build made. *)
}

(* Read each of [files] into [dir], check its bytes against the manifest's sha256 and its
   attestation, all at once, and name the one run that attests them all. *)
let check ~gh ~repo ~workflow ~tag ~commit ~dir files =
  let rec mkdir_p d =
    if not (Sys.file_exists d) then (
      mkdir_p (Filename.dirname d);
      try Sys.mkdir d 0o700 with Sys_error _ when Sys.file_exists d -> ())
  in
  mkdir_p dir;
  let one f =
    Result.map_error
      (fun e -> f.name ^ ": " ^ e)
      (let* bytes =
         Result.map_error (fun e -> "could not be downloaded: " ^ e) (f.fetch ())
       in
       let got = Keys.hash_of_bytes bytes in
       if got <> f.sha256 then
         Error
           (Printf.sprintf "downloaded, it is %s, not the manifest's %s" got
              f.sha256)
       else
         let path = Filename.concat dir (Filename.basename f.name) in
         Out_channel.with_open_bin path (fun oc ->
             Out_channel.output_string oc bytes);
         runs ~gh ~repo ~workflow ~tag ~commit ~sha256:f.sha256 path)
  in
  let results = Parallel.map one files in
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
