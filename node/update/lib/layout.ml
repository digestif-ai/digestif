(* Where a node keeps the code it runs (docs/releases.md, Releases on disk). Every release is a
   directory under releases/ that nothing changes once it is there: the node binary in bin/, the
   behaviors and their prompts in behaviors/, and .release.json, written last, which names its
   version. Two symlinks in the data directory choose among them:

   - current: the release the service runs;
   - good: the last release that reported healthy, whose binary is the supervisor the service
     manager starts (Supervisor), so a release that crashes never has to recover itself.

   A switch moves current, a healthy report moves good, and a rollback moves current back to good.
   Older releases stay on disk. *)

let releases_dir dir = Filename.concat dir "releases"
let release_dir dir name = Filename.concat (releases_dir dir) name
let current_link dir = Filename.concat dir "current"
let good_link dir = Filename.concat dir "good"
let binary_in root = Filename.concat root "bin/digestif"
let behaviors_in root = Filename.concat root "behaviors"
let marker_in root = Filename.concat root ".release.json"
let trial_path dir = Filename.concat dir "update-trial.json"
let health_path dir = Filename.concat dir "health.json"

(* The release a link names, by its directory name, or None when the link is absent. *)
let target link =
  match Unix.readlink link with
  | t -> Some (Filename.basename t)
  | exception Unix.Unix_error _ -> None

let current dir = target (current_link dir)
let good dir = target (good_link dir)

(* A node runs under the supervisor once `digestif service install` has made the layout. Before
   that a release can be staged but not switched to. *)
let supervised dir = good dir <> None

(* Point [link] at releases/[name], atomically: a new symlink beside it renamed over it, so a
   reader sees the old target or the new one and never no link. *)
let point dir link name =
  let tmp = link ^ ".tmp" in
  (try Unix.unlink tmp with Unix.Unix_error _ -> ());
  Unix.symlink (Filename.concat "releases" name) tmp;
  Unix.rename tmp link;
  ignore dir

let point_current dir name = point dir (current_link dir) name
let point_good dir name = point dir (good_link dir) name

(* A release directory that holds its marker is complete: the marker is written last. *)
let staged dir name = Sys.file_exists (marker_in (release_dir dir name))

let marker_json ~version ~source =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String "digestif-release-dir-v0");
         ("version", `String (Version.to_string version));
         ("source", `String source);
       ])
  ^ "\n"

(* The version a release directory says it is. *)
let version_of dir name =
  match
    Release.parse_json "release marker"
      (State.read_file (marker_in (release_dir dir name)))
  with
  | exception Sys_error _ -> None
  | Error _ -> None
  | Ok json -> (
      match Release.string_field "version" json with
      | Ok v -> Result.to_option (Version.of_string v)
      | Error _ -> None)

(* A behavior path from a checkout, ".../behaviors/bin/nightly-hook", runs from the current release
   when that release carries the same file, so a member's existing absolute hook path follows
   every release instead of the checkout it was first set from. Any other path runs as set. *)
let hook_path ~dir path =
  let needle = "/behaviors/" in
  let rec last_at i =
    if i < 0 then None
    else if
      i + String.length needle <= String.length path
      && String.sub path i (String.length needle) = needle
    then Some i
    else last_at (i - 1)
  in
  match last_at (String.length path - String.length needle) with
  | None -> path
  | Some i ->
      let rel =
        String.sub path
          (i + String.length needle)
          (String.length path - i - String.length needle)
      in
      let candidate = Filename.concat (behaviors_in (current_link dir)) rel in
      if
        candidate <> path
        && current dir <> None
        && (try
              Unix.access candidate [ Unix.X_OK ];
              true
            with Unix.Unix_error _ -> false)
      then candidate
      else path
