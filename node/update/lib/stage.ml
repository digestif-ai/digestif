(* Staging a release before the node switches to it (docs/releases.md, Staging). The archive is
   verified against the signed manifest by the caller; here it is unpacked into a directory beside
   the releases, checked, tested, and only then renamed to releases/<version>, so a release
   directory exists only when everything in it passed. Nothing here touches current.

   A failure is one of two kinds. [Retry]: something about this machine or this attempt (a write
   failed, Node.js is missing) that a later pass may not meet; the node keeps what it runs and tries
   again after a backoff. [Refuse]: the release itself is wrong (no binary, a self-test that fails or
   hangs); the node will not take that version again. *)

type failure = Retry of string | Refuse of string

let ( let* ) = Result.bind

(* Seconds the staged binary's self-test may take. *)
let self_test_bound = 120.

let run_quiet argv =
  match Proc.run ~timeout:60. argv with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "%s exited %d: %s" argv.(0) code (String.trim stderr))
  | Error e -> Error e

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> ()
  | { st_kind = S_DIR; _ } ->
      Array.iter
        (fun c -> remove_tree (Filename.concat path c))
        (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let rec copy_tree src dst =
  match Unix.lstat src with
  | { st_kind = S_DIR; st_perm; _ } ->
      Unix.mkdir dst st_perm;
      Array.iter
        (fun c -> copy_tree (Filename.concat src c) (Filename.concat dst c))
        (Sys.readdir src)
  | { st_kind = S_REG; st_perm; _ } ->
      let bytes = State.read_file src in
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_binary ] st_perm dst
        (fun oc -> Out_channel.output_string oc bytes)
  | _ -> ()

(* The major version of the `node` on PATH, if there is one. *)
let node_major () =
  match Proc.run ~timeout:20. [| "node"; "--version" |] with
  | Ok { code = 0; stdout; _ } -> (
      let s = String.trim stdout in
      let s =
        if String.length s > 0 && s.[0] = 'v' then
          String.sub s 1 (String.length s - 1)
        else s
      in
      match String.split_on_char '.' s with
      | major :: _ -> int_of_string_opt major
      | [] -> None)
  | _ -> None

(* The Node.js major the behaviors declare, from "engines": { "node": ">=N" } in their
   package.json, or None when the release carries no behaviors. *)
let required_node root =
  let pkg = Filename.concat (Layout.behaviors_in root) "package.json" in
  if not (Sys.file_exists pkg) then None
  else
    match Yojson.Safe.from_string (State.read_file pkg) with
    | exception _ -> Some 24
    | json -> (
        match Release.field "engines" json with
        | Some engines -> (
            match Release.field "node" engines with
            | Some (`String spec) ->
                let digits =
                  String.to_seq spec
                  |> Seq.drop_while (fun c -> not (c >= '0' && c <= '9'))
                  |> Seq.take_while (fun c -> c >= '0' && c <= '9')
                  |> String.of_seq
                in
                Some (Option.value (int_of_string_opt digits) ~default:24)
            | _ -> Some 24)
        | None -> Some 24)

let check_runtime ~node_major root =
  match required_node root with
  | None -> Ok ()
  | Some want -> (
      match node_major () with
      | Some have when have >= want -> Ok ()
      | Some have ->
          Error
            (Retry
               (Printf.sprintf
                  "its behaviors need Node.js %d or later and the node finds \
                   Node.js %d on its PATH"
                  want have))
      | None ->
          Error
            (Retry
               (Printf.sprintf
                  "its behaviors need Node.js %d or later and the node finds \
                   no node on its PATH"
                  want)))

(* A copy of the node's data for the self-test: the store through SQLite's VACUUM INTO, which is
   consistent while the running node writes, and no secrets, since the keystore is scoped to the
   data directory's path. *)
let copy_data ~dir ~into =
  Node.mkdir_p into;
  let store = Filename.concat dir "log.sqlite3" in
  if Sys.file_exists store then begin
    let log = Log.open_ store in
    Fun.protect
      ~finally:(fun () -> Log.close log)
      (fun () ->
        Log.exec log "VACUUM INTO ?"
          [ Log.s (Filename.concat into "log.sqlite3") ])
  end

(* Run the staged binary against a copy of the node's data: it must say it is [version], open the
   store, and read its config, within [self_test_bound] seconds. *)
let self_test ~dir ~version root =
  let scratch = Filename.concat (Layout.releases_dir dir) ".self-test" in
  remove_tree scratch;
  Fun.protect
    ~finally:(fun () -> try remove_tree scratch with _ -> ())
    (fun () ->
      match copy_data ~dir ~into:scratch with
      | exception e ->
          Error
            (Retry
               ("the node's data could not be copied: " ^ Printexc.to_string e))
      | () -> (
          let exe = Layout.binary_in root in
          let v = Version.to_string version in
          match
            Proc.run ~timeout:self_test_bound
              [|
                exe; "self-test"; "--data-dir"; scratch; "--expect-version"; v;
              |]
          with
          | Ok { code = 0; _ } -> Ok ()
          | Ok { code; stdout; stderr } ->
              let said = String.trim (stderr ^ " " ^ stdout) in
              Error
                (Refuse
                   (Printf.sprintf "its self-test exited %d%s" code
                      (if said = "" then "" else ": " ^ said)))
          | Error e -> Error (Refuse ("its self-test failed: " ^ e))))

let check_layout root =
  let exe = Layout.binary_in root in
  match Unix.access exe [ Unix.X_OK ] with
  | () -> Ok ()
  | exception Unix.Unix_error _ ->
      Error (Refuse "the release archive holds no bin/digestif")

let io f =
  try f () with
  | Unix.Unix_error (e, fn, p) ->
      Error (Retry (Printf.sprintf "%s %s: %s" fn p (Unix.error_message e)))
  | Sys_error e -> Error (Retry e)

(* Finish a release directory unpacked at [staging]: check it, test it, mark it, move it into place
   as releases/[name]. *)
let finish ?(node_major = node_major) ~dir ~name ~version ~source staging =
  let* () = check_layout staging in
  let* () = check_runtime ~node_major staging in
  let* () = self_test ~dir ~version staging in
  io (fun () ->
      Out_channel.with_open_bin (Layout.marker_in staging) (fun oc ->
          Out_channel.output_string oc (Layout.marker_json ~version ~source));
      let final = Layout.release_dir dir name in
      remove_tree final;
      Unix.rename staging final;
      Ok ())

let staging_dir dir name =
  Filename.concat (Layout.releases_dir dir) (".staging-" ^ name)

(* Stage a release from its verified archive (a gzipped tar of bin/ and behaviors/). A release
   already staged is not unpacked again. *)
let from_archive ?node_major ~dir ~version bytes =
  let name = Version.to_string version in
  if Layout.staged dir name then Ok name
  else
    let staging = staging_dir dir name in
    let archive = staging ^ ".tar.gz" in
    let* () =
      io (fun () ->
          Node.mkdir_p (Layout.releases_dir dir);
          remove_tree staging;
          Unix.mkdir staging 0o755;
          Out_channel.with_open_bin archive (fun oc ->
              Out_channel.output_string oc bytes);
          Ok ())
    in
    let result =
      let* () =
        match run_quiet [| "tar"; "-xzf"; archive; "-C"; staging |] with
        | Ok () -> Ok ()
        | Error e -> Error (Refuse ("the release archive did not unpack: " ^ e))
      in
      finish ?node_major ~dir ~name ~version ~source:"channel" staging
    in
    (try Sys.remove archive with Sys_error _ -> ());
    (match result with
    | Error _ -> ( try remove_tree staging with _ -> ())
    | Ok () -> ());
    Result.map (fun () -> name) result

(* Stage the running binary and a behaviors directory as a local release, for `digestif service
   install` from a source build. Named for the binary's hash, so the same build is staged once. *)
let local ?node_major ~dir ~version ~binary ~behaviors () =
  let hash = Keys.hash_of_bytes (State.read_file binary) in
  let hex = String.sub hash (String.length Keys.sha256_prefix) 12 in
  let name = "local-" ^ hex in
  if Layout.staged dir name then Ok name
  else
    let staging = staging_dir dir name in
    let result =
      let* () =
        io (fun () ->
            Node.mkdir_p (Layout.releases_dir dir);
            remove_tree staging;
            Unix.mkdir staging 0o755;
            Unix.mkdir (Filename.concat staging "bin") 0o755;
            copy_tree binary (Layout.binary_in staging);
            Unix.chmod (Layout.binary_in staging) 0o755;
            Option.iter
              (fun b ->
                let target = Layout.behaviors_in staging in
                Unix.mkdir target 0o755;
                List.iter
                  (fun part ->
                    let src = Filename.concat b part in
                    if Sys.file_exists src then
                      copy_tree src (Filename.concat target part))
                  Bundle.behavior_parts)
              behaviors;
            Ok ())
      in
      finish ?node_major ~dir ~name ~version ~source:"local" staging
    in
    (match result with
    | Error _ -> ( try remove_tree staging with _ -> ())
    | Ok () -> ());
    Result.map (fun () -> name) result
