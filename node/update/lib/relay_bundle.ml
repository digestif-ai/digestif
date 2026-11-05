(* A relay release's bundle, digestif-relay-<version>.tar.gz (docs/releases.md, Relay releases):
   worker/, app/, migrations/*.sql and bundle.json. Here only what its manifest needs is read from
   it: its sha256 and size, and every migration it carries, so the manifest the signers sign
   describes exactly the bytes in the bundle rather than a checkout beside it. *)

let ( let* ) = Result.bind

let unpack ~archive ~dir =
  match Proc.run ~timeout:300. [| "tar"; "-xzf"; archive; "-C"; dir |] with
  | Ok { code = 0; _ } -> Ok ()
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "%s did not unpack (tar exited %d): %s" archive code
           (String.trim stderr))
  | Error e -> Error (archive ^ " did not unpack: " ^ e)

let read path = In_channel.with_open_bin path In_channel.input_all

(* Every migrations/*.sql in an unpacked bundle at [dir], in the order they apply. A file there
   whose name is not a migration name is refused, since nothing would apply it. *)
let migrations ~dir =
  let mdir = Filename.concat dir "migrations" in
  if not (Sys.file_exists mdir && Sys.is_directory mdir) then
    Error "the bundle holds no migrations/ directory"
  else
    let names =
      Sys.readdir mdir |> Array.to_list
      |> List.filter (fun n -> n <> "" && n.[0] <> '.')
      |> List.sort String.compare
    in
    match List.find_opt (fun n -> not (Release.is_migration_name n)) names with
    | Some bad ->
        Error
          (Printf.sprintf
             "migrations/%s is not a migration name (NNNN_<lowercase \
              words>.sql)"
             bad)
    | None when names = [] -> Error "the bundle's migrations/ is empty"
    | None ->
        Ok
          (List.map
             (fun n ->
               {
                 Release.migration = n;
                 migration_sha256 =
                   Keys.hash_of_bytes (read (Filename.concat mdir n));
               })
             names)

(* The manifest for the bundle at [archive], to be published as [url_base]/<its file name>. *)
let manifest ~version ~notes ~url_base ~compatible_with ~published_at ~archive :
    (Release.relay_manifest, string) result =
  let* relay_version = Version.of_string version in
  let* compatible_with = Version.of_string compatible_with in
  let* () =
    if Version.compare compatible_with relay_version > 0 then
      Error
        (Printf.sprintf "--compatible-with %s is newer than the version %s"
           (Version.to_string compatible_with)
           version)
    else Ok ()
  in
  let bytes = read archive in
  let dir = Filename.temp_dir "digestif-relay-bundle" "" in
  Fun.protect
    ~finally:(fun () -> try Stage.remove_tree dir with _ -> ())
    (fun () ->
      let* () = unpack ~archive ~dir in
      let* migrations = migrations ~dir in
      let base =
        if String.ends_with ~suffix:"/" url_base then url_base
        else url_base ^ "/"
      in
      Ok
        {
          Release.relay_version;
          relay_published_at = published_at;
          relay_notes = notes;
          bundle =
            {
              bundle_url = base ^ Filename.basename archive;
              bundle_sha256 = Keys.hash_of_bytes bytes;
              bundle_size = String.length bytes;
            };
          migrations;
          compatible_with;
        })
