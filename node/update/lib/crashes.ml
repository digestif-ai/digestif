(* The count a supervisor keeps of its child's exits outside a trial (docs/releases.md, A version
   that keeps crashing). A child's exit ends the supervisor, so the count lives on disk, in
   update-crashes.json beside update.json, and the next supervisor the service manager starts
   carries it on.

   Time here is awake time (Awake) the release's child has run, summed over every supervisor that
   ran it: [awake] is that sum, and each exit is stamped with the sum at the moment it happened. An
   exit counts toward the limit while it is less than [window] awake seconds old. The record names
   the release it counts, so a different release starts from nothing. *)

type t = {
  release : string;  (** The directory name under releases/ the child ran. *)
  awake : float;  (** Awake seconds the release's child has run in total. *)
  exits : float list;
      (** The [awake] sum at each exit still in the window, newest first. *)
}

(* Exits that move a node back, and the awake time they have to fall in. *)
let limit = 3
let window = 600.
let ( let* ) = Result.bind
let format = "digestif-update-crashes-v0"

let to_string t =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String format);
         ("release", `String t.release);
         ("awake", `Float t.awake);
         ("exits", `List (List.map (fun e -> `Float e) t.exits));
       ])
  ^ "\n"

let number name = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error (Printf.sprintf "field %S holds numbers" name)

let of_string bytes =
  let* json = Release.parse_json "update crash count" bytes in
  let* () = Release.expect_format format json in
  let* release = Release.string_field "release" json in
  let* awake =
    match Release.field "awake" json with
    | Some n -> number "awake" n
    | None -> Error "field \"awake\" is missing"
  in
  let* exits = Release.list_field "exits" json in
  let* exits = Release.all (number "exits") exits in
  Ok { release; awake; exits }

(* The count for [release]. A missing file, one that does not parse, or one counting another
   release is a count of nothing: losing a count costs three more exits, never an update. *)
let load dir ~release =
  let fresh = { release; awake = 0.; exits = [] } in
  match State.read_file (Layout.crashes_path dir) with
  | exception Sys_error _ -> fresh
  | bytes -> (
      match of_string bytes with
      | Ok t when t.release = release -> t
      | _ -> fresh)

let save dir t = State.write_atomic (Layout.crashes_path dir) (to_string t)

let clear dir =
  try Sys.remove (Layout.crashes_path dir) with Sys_error _ -> ()

(* One more exit, after the child ran [awake] seconds of awake time: the count with it, and the
   exits older than the window dropped. *)
let exit_after t ~awake =
  let awake = t.awake +. Float.max 0. awake in
  {
    t with
    awake;
    exits = awake :: List.filter (fun e -> awake -. e < window) t.exits;
  }

let over_limit t = List.length t.exits >= limit
