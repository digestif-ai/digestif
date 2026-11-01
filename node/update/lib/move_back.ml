(* Moving a node back from a version to the newest older release on its own disk (docs/releases.md,
   A recall): find it, self-test it against a copy of the store, save it as installed, and point
   current and good at it. Nothing is fetched, so no signature is involved: every release under
   releases/ was verified when it was staged. The caller exits afterwards, so the service manager
   starts the older release's supervisor. *)

type refusal =
  | Not_supervised
      (** No good link: the node is not running under its supervisor. *)
  | Nothing_older  (** No release on disk older than [from] may be taken. *)
  | Below_floor of Version.t
      (** Older releases exist, but every one is below this floor. *)
  | Self_test_failed of Version.t * string

(* Every complete release directory on disk with the version its marker names, newest first. A
   directory still being staged starts with a dot and holds no marker. *)
let on_disk dir =
  match Sys.readdir (Layout.releases_dir dir) with
  | exception Sys_error _ -> []
  | names ->
      Array.to_list names
      |> List.filter (fun n -> n <> "" && n.[0] <> '.')
      |> List.filter_map (fun n ->
          if Layout.staged dir n then
            Option.map (fun v -> (n, v)) (Layout.version_of dir n)
          else None)
      |> List.stable_sort (fun (_, a) (_, b) -> Version.compare b a)

let self_test ~dir ~version root =
  match Stage.self_test ~dir ~version root with
  | Ok () -> Ok ()
  | Error (Stage.Retry e | Stage.Refuse e) -> Error e

(* Move back from [from]: the newest release on disk older than it, not refused, not [excluded],
   and not below [floor]. Returns the state it saved. update.json is saved with it as installed before the links move, so a
   crash between the two leaves a node that runs [from] and moves again on its next pass. *)
let run ?(self_test = self_test) ?floor ~excluded ~dir ~from (state : State.t) :
    (State.t * Version.t, refusal) result =
  if not (Layout.supervised dir) then Error Not_supervised
  else
    let older =
      List.filter
        (fun (_, v) ->
          Version.compare v from < 0
          && (not (State.is_refused state v))
          && not (excluded v))
        (on_disk dir)
    in
    let allowed =
      match floor with
      | None -> older
      | Some f -> List.filter (fun (_, v) -> Version.compare v f >= 0) older
    in
    match (allowed, floor) with
    | [], Some f when older <> [] -> Error (Below_floor f)
    | [], _ -> Error Nothing_older
    | (name, version) :: _, _ -> (
        match self_test ~dir ~version (Layout.release_dir dir name) with
        | Error why -> Error (Self_test_failed (version, why))
        | Ok () ->
            let state =
              {
                (State.note_install state version ~now:(Unix.gettimeofday ())) with
                installed = version;
                pending = None;
              }
            in
            State.save (Filename.concat dir "update.json") state;
            Trial.clear dir;
            Layout.point_good dir name;
            Layout.point_current dir name;
            Ok (state, version))
