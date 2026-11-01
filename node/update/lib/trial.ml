(* A switch on trial: current points at a new release and the supervisor has not yet seen it report
   healthy. The record says what to move back to. [starts] counts the supervisor runs that tried
   the release, so a machine that reboots mid-trial does not try a broken release forever. *)

type t = {
  release : string;  (** The directory name under releases/ current points at. *)
  version : Version.t;
  previous : string;  (** The release to move back to: the one good named. *)
  starts : int;
}

let ( let* ) = Result.bind

let to_string t =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String "digestif-update-trial-v0");
         ("release", `String t.release);
         ("version", `String (Version.to_string t.version));
         ("previous", `String t.previous);
         ("starts", `Int t.starts);
       ])
  ^ "\n"

let of_string bytes =
  let* json = Release.parse_json "update trial" bytes in
  let* () = Release.expect_format "digestif-update-trial-v0" json in
  let* release = Release.string_field "release" json in
  let* version = Release.string_field "version" json in
  let* version = Version.of_string version in
  let* previous = Release.string_field "previous" json in
  let* starts = Release.int_field "starts" json in
  Ok { release; version; previous; starts }

let load dir =
  match State.read_file (Layout.trial_path dir) with
  | exception Sys_error _ -> None
  | bytes -> Result.to_option (of_string bytes)

let save dir t = State.write_atomic (Layout.trial_path dir) (to_string t)

let clear dir =
  try Sys.remove (Layout.trial_path dir) with Sys_error _ -> ()

(* Switch to a staged release: record the trial first, then move current, so a crash between the
   two leaves a trial whose current is still the previous release, which the supervisor ends as a
   rollback to where it already is. *)
let begin_ dir ~release ~version =
  match Layout.good dir with
  | None -> Error "the node is not running under its supervisor"
  | Some previous ->
      Health.clear dir;
      save dir { release; version; previous; starts = 0 };
      Layout.point_current dir release;
      Ok ()
