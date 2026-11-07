(* What the node's own update passes have to tell its person, kept until the next digest takes it.
   A refused release, halted updates, an unreadable channel entry or a failed pass is reported once:
   a line goes to [pending] the first pass it appears and stays out while later passes keep finding
   it, so a release both signers never sign is in one digest, not every one. A line that stops
   appearing and comes back is reported again.

   A pass that fails outright (the channel unreachable: no network yet after a wake, a DNS or TLS
   failure) is not news until passes have failed for [Schedule.failure_grace]: [failing_since]
   holds when the current run of failed passes began, and a pass that succeeds clears it. *)

type t = {
  last_checked_at : float option;  (** Unix time of the last update pass. *)
  seen : string list;  (** Every line the last pass found. *)
  pending : string list;  (** Lines the next digest has not taken yet. *)
  failing_since : float option;
      (** Unix time of the first failed pass since the last one that succeeded.
      *)
}

let empty =
  { last_checked_at = None; seen = []; pending = []; failing_since = None }

let format = "digestif-update-report-v0"
let ( let* ) = Result.bind

let strings name json =
  let* l = Release.list_field name json in
  Release.all
    (function
      | `String s -> Ok s | _ -> Error (Printf.sprintf "%s holds strings" name))
    l

let of_string bytes =
  let* json = Release.parse_json "update report" bytes in
  let* () = Release.expect_format format json in
  let* last_checked_at =
    match Release.field "last_checked_at" json with
    | None | Some `Null -> Ok None
    | Some (`Float f) -> Ok (Some f)
    | Some (`Int i) -> Ok (Some (float_of_int i))
    | Some _ -> Error "field \"last_checked_at\" must be a number"
  in
  let* seen = strings "seen" json in
  let* pending = strings "pending" json in
  (* Absent in a report an older release wrote. *)
  let* failing_since =
    match Release.field "failing_since" json with
    | None | Some `Null -> Ok None
    | Some (`Float f) -> Ok (Some f)
    | Some (`Int i) -> Ok (Some (float_of_int i))
    | Some _ -> Error "field \"failing_since\" must be a number"
  in
  Ok { last_checked_at; seen; pending; failing_since }

let to_string t =
  let list l = `List (List.map (fun s -> `String s) l) in
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String format);
         ( "last_checked_at",
           match t.last_checked_at with None -> `Null | Some f -> `Float f );
         ("seen", list t.seen);
         ("pending", list t.pending);
         ( "failing_since",
           match t.failing_since with None -> `Null | Some f -> `Float f );
       ])
  ^ "\n"

(* The report at [path]; a missing file is an empty report, and so is one that does not parse,
   since losing a report costs one digest line while refusing to start would stop every update. *)
let load path =
  if Sys.file_exists path then
    match of_string (State.read_file path) with Ok t -> t | Error _ -> empty
  else empty

let save path t =
  State.mkdir_p (Filename.dirname path);
  State.write_atomic path (to_string t)

let dedup l =
  List.rev
    (List.fold_left
       (fun acc s -> if List.mem s acc then acc else s :: acc)
       [] l)

(* Fold one pass's findings, taken at [now], into the report. *)
let record t ~now lines =
  let lines = dedup lines in
  let fresh =
    List.filter
      (fun l -> (not (List.mem l t.seen)) && not (List.mem l t.pending))
      lines
  in
  {
    t with
    last_checked_at = Some now;
    seen = lines;
    pending = t.pending @ fresh;
  }

(* The digest section, when there is anything to say. *)
let digest_section t =
  match t.pending with [] -> None | lines -> Some ("Updates", lines)

(* Take the pending lines for a digest that is about to go out, leaving the report empty of them. *)
let take path =
  let t = load path in
  if t.pending <> [] then save path { t with pending = [] };
  t.pending

(* Drop [lines] from the pending lines once a digest carrying them is appended. A line a pass added
   after the digest read the report stays for the next one. *)
let drop path lines =
  let t = load path in
  let pending = List.filter (fun l -> not (List.mem l lines)) t.pending in
  if pending <> t.pending then save path { t with pending }

(* Lines for one event, not a pass's findings: a switch that became healthy or was rolled back. Each
   goes to the next digest whatever the last pass saw. *)
let note path lines =
  let t = load path in
  let fresh = List.filter (fun l -> not (List.mem l t.pending)) lines in
  if fresh <> [] then save path { t with pending = t.pending @ fresh }
