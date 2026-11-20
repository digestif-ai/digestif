(* Deleting the releases a node no longer needs (docs/releases.md, Releases on disk). Each release
   carries its own Node.js runtime, so a node that keeps every one grows without bound. After a
   switch is kept (Supervisor.promote) the node keeps:

   - the release current names and the one good names;
   - the release the switch came from, the one a recall or a crash moves back to (Move_back);
   - the release the running supervisor's own binary lives in, which can be older still when the
     supervisor kept running across several switches;
   - every complete release newer than the one just kept: one an update pass staged while this ran,
     on its way to a trial of its own;
   - anything that is not a complete release: a directory being staged or self-tested (its name
     starts with a dot), or one without its marker, which this code did not make.

   Every other complete release is deleted. DIG-216 *)

(* The release directory name [path] lies in, when it lies under this node's releases/. *)
let release_of ~dir path =
  let releases =
    try Unix.realpath (Layout.releases_dir dir)
    with Unix.Unix_error _ -> Layout.releases_dir dir
  in
  let prefix = releases ^ "/" in
  let n = String.length prefix in
  match Unix.realpath path with
  | exception Unix.Unix_error _ -> None
  | real when String.length real > n && String.sub real 0 n = prefix -> (
      let rest = String.sub real n (String.length real - n) in
      match String.index_opt rest '/' with
      | Some i -> Some (String.sub rest 0 i)
      | None -> Some rest)
  | _ -> None

(* The release the running program's own binary lives in, if any. *)
let running ~dir = release_of ~dir Sys.executable_name

(* The complete releases to delete once [kept] is current and good, having come from [previous].
   [also] names further releases to keep. *)
let candidates ?(also = []) ~dir ~kept ~previous () =
  let keep =
    List.filter_map Fun.id [ Layout.current dir; Layout.good dir ]
    @ (kept :: previous :: also)
  in
  let floor = Layout.version_of dir kept in
  Move_back.on_disk dir
  |> List.filter (fun (name, version) ->
      (not (List.mem name keep))
      &&
      match floor with
      | Some f -> Version.compare version f < 0
      | None -> false)
  |> List.map fst

let doomed_prefix = ".pruning-"

(* A release being deleted is first renamed out of the set Move_back reads, so a deletion cut short
   never leaves a release that looks complete and lacks its binary. One cut short earlier is
   finished here. *)
let finish_earlier ~dir =
  match Sys.readdir (Layout.releases_dir dir) with
  | exception Sys_error _ -> ()
  | names ->
      Array.iter
        (fun n ->
          if String.starts_with ~prefix:doomed_prefix n then
            try Stage.remove_tree (Layout.release_dir dir n)
            with Unix.Unix_error _ | Sys_error _ -> ())
        names

(* Delete them; returns the names deleted. *)
let run ?also ~dir ~kept ~previous () =
  finish_earlier ~dir;
  candidates ?also ~dir ~kept ~previous ()
  |> List.filter (fun name ->
      let doomed = Layout.release_dir dir (doomed_prefix ^ name) in
      match Unix.rename (Layout.release_dir dir name) doomed with
      | exception Unix.Unix_error _ -> false
      | () ->
          (* Out of Move_back's sight now; what stays is finished next time. *)
          (try Stage.remove_tree doomed
           with Unix.Unix_error _ | Sys_error _ -> ());
          true)
