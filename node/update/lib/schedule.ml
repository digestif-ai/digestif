(* The node's self-update, as its service loop runs it: once a day and when the machine wakes, one
   Updater pass against the release channel, its findings folded into the report the next digest
   reads. After an install the caller exits, and launchd's KeepAlive or systemd's Restart starts the
   new binary. Every file lives in the node's own data directory. *)

let state_path dir = Filename.concat dir "update.json"
let report_path dir = Filename.concat dir "update-report.json"
let day = 86_400.

(* A wake checks at most this often, so a laptop that naps through a meeting does not read the
   channel at every lid open. *)
let wake_gap = 3_600.

(* Whether a pass is due at [now]. A clock that moved backwards past the last pass makes one due, so
   a wrong clock cannot postpone updates for as long as it is wrong. *)
let due ~now ~woke (r : Report.t) =
  match r.last_checked_at with
  | None -> true
  | Some last ->
      now < last || now -. last >= day || (woke && now -. last >= wake_gap)

type config = {
  dir : string;
  binary : string;
      (** The running node binary, the file an install replaces. *)
  base : string;  (** The release channel. *)
  fetch : Feed.fetch;
  platform : unit -> (string, string) result;
}

let config ?(base = Feed.default_url) ?(fetch = Feed.default_fetch)
    ?(platform = Platform.current) ~dir ~binary () =
  { dir; binary; base; fetch; platform }

type result = Installed of Version.t | Not_installed

let skipped_line (s : Policy.skipped) =
  Printf.sprintf "Release %s was not installed: %s."
    (Version.to_string s.skipped_version)
    s.reason

let problem_line p = "A release channel entry could not be read: " ^ p ^ "."
let failed_line e = "The update check failed: " ^ e ^ "."

(* The lines a pass leaves for the digest. An install is reported too: it is something the node did
   in its person's name. *)
let lines = function
  | Ok (o : Updater.outcome) ->
      Option.to_list
        (Option.map
           (fun v -> "Updated Digestif to " ^ Version.to_string v ^ ".")
           o.installed)
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
          Updater.run ~fetch:cfg.fetch ~base:cfg.base ~platform
            ~state_path:(state_path cfg.dir) ~binary:cfg.binary
    with
    | Failure e | Sys_error e -> Error e
    | Unix.Unix_error (e, f, p) ->
        Error (Printf.sprintf "%s %s: %s" f p (Unix.error_message e))
  in
  let found = lines outcome in
  let path = report_path cfg.dir in
  Report.save path (Report.record (Report.load path) ~now found);
  ( (match outcome with
    | Ok { installed = Some v; _ } -> Installed v
    | Ok _ | Error _ -> Not_installed),
    found )

(* A pass when one is due, otherwise nothing. *)
let tick cfg ~now ~woke =
  if due ~now ~woke (Report.load (report_path cfg.dir)) then
    Some (pass cfg ~now)
  else None
