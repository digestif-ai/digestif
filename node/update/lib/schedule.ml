(* The node's self-update, as its service loop runs it: once a day, when the machine wakes, and when
   a failed stage's backoff has passed, one Updater pass against the release channel, its findings
   folded into the report the next digest reads. After a switch the caller exits and the supervisor
   runs the new release on trial. Every file lives in the node's own data directory. *)

let state_path dir = Filename.concat dir "update.json"
let report_path dir = Filename.concat dir "update-report.json"
let day = 86_400.

(* A wake checks at most this often, so a laptop that naps through a meeting does not read the
   channel at every lid open. *)
let wake_gap = 3_600.

(* Whether a pass is due at [now]. A clock that moved backwards past the last pass makes one due, so
   a wrong clock cannot postpone updates for as long as it is wrong. *)
let due ?pending_due ~now ~woke (r : Report.t) =
  match r.last_checked_at with
  | None -> true
  | Some last -> (
      now < last
      || now -. last >= day
      || (woke && now -. last >= wake_gap)
      || match pending_due with Some at -> now >= at | None -> false)

type config = {
  dir : string;
  base : string;  (** The release channel. *)
  fetch : Feed.fetch;
  platform : unit -> (string, string) result;
  node_major : (unit -> int option) option;
}

let config ?(base = Feed.default_url) ?(fetch = Feed.default_fetch)
    ?(platform = Platform.current) ?node_major ~dir () =
  { dir; base; fetch; platform; node_major }

type result = Switched of Version.t | Not_switched

let skipped_line (s : Policy.skipped) =
  Printf.sprintf "Release %s was not installed: %s."
    (Version.to_string s.skipped_version)
    s.reason

let problem_line p = "A release channel entry could not be read: " ^ p ^ "."
let failed_line e = "The update check failed: " ^ e ^ "."

let clock_line at =
  let t = Unix.localtime at in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d" (t.tm_year + 1900) (t.tm_mon + 1)
    t.tm_mday t.tm_hour t.tm_min

(* What a pass's step says to the person. A switch says nothing yet: the supervisor reports it once
   the release is healthy or rolled back. *)
let step_lines = function
  | Updater.Nothing | Switched _ | Waiting _ -> []
  | Staged (v, path) ->
      [
        Printf.sprintf
          "Release %s is downloaded but not running: run %s service \
           install            once so the node can switch to it."
          (Version.to_string v) (Layout.binary_in path);
      ]
  | Stage_failed (v, why, due_at) ->
      [
        Printf.sprintf
          "Release %s could not be staged: %s. The node keeps running what \
           it            runs and tries again after %s."
          (Version.to_string v) why (clock_line due_at);
      ]
  | Refused (v, why) ->
      [
        Printf.sprintf "Release %s was refused and will not be installed: %s."
          (Version.to_string v) why;
      ]

let lines = function
  | Ok (o : Updater.outcome) ->
      step_lines o.step
      @ List.map skipped_line o.plan.skipped
      @ List.map problem_line o.problems
  | Error e -> [ failed_line e ]

(* One pass. Nothing raised here stops the node: a broken build constant or a failed uname is a
   failed pass, reported like any other. *)
let pass cfg ~now =
  let outcome =
    try
      match cfg.platform () with
      | Error e -> Error e
      | Ok platform ->
          Updater.run ?node_major:cfg.node_major ~fetch:cfg.fetch ~base:cfg.base
            ~platform ~dir:cfg.dir ~now ()
    with
    | Failure e | Sys_error e -> Error e
    | Unix.Unix_error (e, f, p) ->
        Error (Printf.sprintf "%s %s: %s" f p (Unix.error_message e))
  in
  let found = lines outcome in
  let path = report_path cfg.dir in
  Report.save path (Report.record (Report.load path) ~now found);
  ( (match outcome with
    | Ok { step = Switched v; _ } -> Switched v
    | Ok _ | Error _ -> Not_switched),
    found )

(* A pass when one is due, otherwise nothing. No pass runs while a switch is on trial: the
   supervisor is deciding whether the release this process runs stays. *)
let tick cfg ~now ~woke =
  let pending_due =
    match State.load (state_path cfg.dir) with
    | Ok { pending = Some p; _ } -> Some p.due_at
    | _ -> None
  in
  if Trial.load cfg.dir <> None then None
  else if due ?pending_due ~now ~woke (Report.load (report_path cfg.dir)) then
    Some (pass cfg ~now)
  else None
