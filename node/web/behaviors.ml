(* Behaviors (design.md, The agent is spawned, not embedded; docs/behaviors.md). The node holds no
   intelligence: the nightly note and the read loop are executables it spawns, the way a coding
   harness runs hooks. `digestif run` spawns the nightly behavior, the note's work run, on the
   first pass at or after the member's Note time, any time of day in their time zone, until a run
   handles that local date (a failed run is tried again on the next pass, up to three runs a date),
   so a laptop that was closed at Note time runs it when it next wakes, but never for a Note time
   that passed before the behavior was set up; and the read behavior after a pass whose sync
   stored something new. A behavior is handed a JSON context on stdin (the data directory, the local
   API address with a session for it, the chosen sources with where each starts, and the local
   date), writes its output to a
   log beside the node's, and hands its results back through the local API or `digestif note` and
   `digestif tick`. The session ends when the behavior exits, and a behavior that outlives its
   deadline, counted in time the machine is awake, is ended. *)

open Digestif_core

type hook = Nightly | Read

let hooks = [ (Nightly, "nightly"); (Read, "read") ]
let hook_name h = List.assoc h hooks

let hook_of_name n =
  List.find_map (fun (h, s) -> if s = n then Some h else None) hooks

(* The version of the context a behavior is handed; docs/behaviors.md says what each one holds. *)
let interface = 0
let k_exe h = "behavior_" ^ hook_name h
let k_last_date = "behavior_nightly_last_date"

(* How long a run may take before the node ends it, and how long after SIGTERM before SIGKILL. The
   run's time is awake time: the node adds up the time between reaps, and a gap longer than
   [sleep_gap] is the machine asleep (the run loop reaps every 5 seconds), a pause the run is not
   charged for. A wall clock would read a laptop shut mid-run as a run past its deadline. *)
let timeout = function Nightly -> 1800.0 | Read -> 900.0
let grace = 30.0
let sleep_gap = 60.0

(* A nightly run that does not exit 0 is tried again on the next pass, and the local date is over
   after this many failed runs. *)
let max_tries = 3
let k_failures = "behavior_nightly_failures"
let executable (log : Log.t) h = Log.get_config log (k_exe h)

let set_executable (log : Log.t) h path =
  Result.map
    (fun () -> Log.set_config log (k_exe h) (Sources.untilde path))
    (Sources.check_program [ path ])

let unset_executable (log : Log.t) h =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s (k_exe h) ]

(* The member's Note time as hours and minutes; the saved one, else Settings' default. *)
let note_time (log : Log.t) =
  match String.split_on_char ':' (Store.Settings.note_time log) with
  | [ h; m ] -> (int_of_string h, int_of_string m)
  | _ -> assert false

let local_date = Digestif_daily.Daily_digest.local_date
let last_date (log : Log.t) = Log.get_config log k_last_date

(* Today's slot: Note time on [now]'s local date, in the machine's zone. *)
let slot ~note_time:(hour, minute) ~now =
  let g = Unix.localtime now in
  fst (Unix.mktime { g with tm_hour = hour; tm_min = minute; tm_sec = 0 })

(* Due at or after today's slot on a local date it has not run on, when the nightly was armed (a
   behavior set and a source chosen) by the slot. A slot that passed before then is not owed: a
   member who sets the behavior up at 10 pm gets their first note at the next slot, not at once. A
   laptop that was closed at the slot runs it when it next wakes. *)
let nightly_due_at ~note_time ~last_date ~armed_since ~now =
  let at = slot ~note_time ~now in
  now >= at && armed_since <= at
  && match last_date with Some d -> d < local_date now | None -> true

let chosen_sources (log : Log.t) =
  List.filter (fun (s : Store.source) -> s.selected) (Store.sources log)

(* The record (DES-37265, The record and where each note starts). The git source reads the
   clones of every approved repository, and only the commit authors the member owns, once the
   Repositories page has a scan and a list of authors; before that, its own paths and every
   author. *)
type repository = {
  repo_id : string;
  repo_name : string;
  repo_paths : string list;
}

let repositories (log : Log.t) (s : Store.source) =
  let module R = Store.Repositories in
  if Store.config log R.k_scanned <> None then
    List.map
      (fun (r : R.repository) ->
        { repo_id = r.r_id; repo_name = r.r_name; repo_paths = r.r_paths })
      (R.repositories ~status:"approved" ~limit:max_int ~offset:0 log)
  else
    List.map
      (fun p ->
        let p = Sources.untilde p in
        { repo_id = p; repo_name = Filename.basename p; repo_paths = [ p ] })
      s.paths

(* The owned authors' emails, or None while the list was never proposed: every author. *)
let authors (log : Log.t) =
  let module R = Store.Repositories in
  if R.authors_proposed log then
    Some (List.map (fun (a : R.author) -> a.email) (R.authors log))
  else None

(* Every record key the chosen sources stand for. *)
let record_keys (log : Log.t) sources =
  List.concat_map
    (fun (s : Store.source) ->
      if s.kind = "git" then
        List.map
          (fun r -> Store.Record.repository_key r.repo_id)
          (repositories log s)
        @ List.map Store.Record.author_key
            (Option.value (authors log) ~default:[])
      else [ Store.Record.source_key s.id ])
    sources

(* A source's start in the context: [start] (null for the first note's reach), and for a
   recorded point [recorded] true with a repository's [sha]. *)
let start_fields (log : Log.t) ~now key : (string * Yojson.Safe.t) list =
  let st = Store.Record.start log ~now_ms:(int_of_float (now *. 1000.)) key in
  [
    ( "start",
      match st.start_ms with
      | Some ms -> `String (Time_fmt.of_unix (float_of_int ms /. 1000.))
      | None -> `Null );
    ("recorded", `Bool st.recorded);
  ]
  @ match st.start_sha with Some sha -> [ ("sha", `String sha) ] | None -> []

let source_record_fields (log : Log.t) ~now (s : Store.source) =
  let strings l = `List (List.map (fun s -> `String s) l) in
  if s.kind = "git" then
    let repos = repositories log s in
    [
      ("paths", strings (List.concat_map (fun r -> r.repo_paths) repos));
      ( "repositories",
        `List
          (List.map
             (fun r ->
               `Assoc
                 ([
                    ("id", `String r.repo_id);
                    ("name", `String r.repo_name);
                    ("paths", strings r.repo_paths);
                  ]
                 @ start_fields log ~now (Store.Record.repository_key r.repo_id)
                 ))
             repos) );
      ( "authors",
        match authors log with
        | None -> `Null
        | Some emails ->
            `List
              (List.map
                 (fun e ->
                   `Assoc
                     (("email", `String e)
                     :: start_fields log ~now (Store.Record.author_key e)))
                 emails) );
    ]
  else
    ("paths", strings (List.map Sources.untilde s.paths))
    :: start_fields log ~now (Store.Record.source_key s.id)

let k_armed_since = "behavior_nightly_armed_since"

(* Dates every chosen source the record has not seen approved yet: once a pass. *)
let observe_record (log : Log.t) ~now =
  Store.Record.observe log
    ~now_ms:(int_of_float (now *. 1000.))
    (record_keys log (chosen_sources log))

(* When the nightly was first seen armed, recorded the first time the schedule is asked while it
   is, and forgotten when it is not: a member who chose no sources reads and answers only, so
   there is no note to write. *)
let armed_since (log : Log.t) ~now =
  if executable log Nightly <> None && chosen_sources log <> [] then (
    match
      Option.bind (Log.get_config log k_armed_since) float_of_string_opt
    with
    | Some t -> Some t
    | None ->
        Log.set_config log k_armed_since (Printf.sprintf "%.0f" now);
        Some now)
  else begin
    Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_armed_since ];
    None
  end

let nightly_due (log : Log.t) ~now =
  match armed_since log ~now with
  | None -> false
  | Some armed_since ->
      observe_record log ~now;
      nightly_due_at ~note_time:(note_time log) ~last_date:(last_date log)
        ~armed_since ~now

type api = { url : string; session : string }

let context ?log ~hook ~dir ~digestif ~api ~sources ~now ~deadline () :
    Yojson.Safe.t =
  let strings l = `List (List.map (fun s -> `String s) l) in
  let record_fields (s : Store.source) =
    match log with
    | Some log -> source_record_fields log ~now s
    | None -> [ ("paths", strings (List.map Sources.untilde s.paths)) ]
  in
  `Assoc
    [
      ("interface", `Int interface);
      ("hook", `String (hook_name hook));
      ("local_date", `String (local_date now));
      ("data_dir", `String dir);
      ("digestif", `String digestif);
      ( "api",
        match api with
        | None -> `Null
        | Some a ->
            `Assoc
              [
                ("url", `String a.url);
                ( "headers",
                  `Assoc
                    [
                      ("Cookie", `String (Server.cookie_name ^ "=" ^ a.session));
                      ("Digestif-Local", `String "1");
                    ] );
              ] );
      ( "sources",
        `List
          (List.map
             (fun (s : Store.source) ->
               `Assoc
                 ([
                    ("id", `String s.id);
                    ("kind", `String s.kind);
                    ("label", `String s.label);
                  ]
                 @ record_fields s
                 @ [ ("yields", strings s.yields) ]))
             sources) );
      ( "first_note",
        `Bool
          (match log with
          | Some log -> Store.Record.first_note log
          | None -> true) );
      ("deadline", `String (Time_fmt.of_unix deadline));
    ]

type running = {
  hook : hook;
  pid : int;
  started : float;
  date : string;  (** the local date it was handed *)
  session : string option;
  mutable awake : float;  (** seconds run while the machine was awake *)
  mutable seen : float;  (** when it was last reaped *)
  mutable terminated : float option;
}

type t = {
  node : Node.t;
  digestif : string;
  api_url : string option;
  mutable running : running list;
}

let create ~digestif ?api_url node = { node; digestif; api_url; running = [] }
let is_running t h = List.exists (fun r -> r.hook = h) t.running
let dir t = Filename.concat t.node.dir "behaviors"
let log_path t h = Filename.concat (dir t) (hook_name h ^ ".log")

let environment t h =
  let ours = [ "DIGESTIF_HOME"; "DIGESTIF_HOOK" ] in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun kv ->
        match String.index_opt kv '=' with
        | Some i -> not (List.mem (String.sub kv 0 i) ours)
        | None -> true)
  in
  Array.of_list
    (inherited
    @ [ "DIGESTIF_HOME=" ^ t.node.dir; "DIGESTIF_HOOK=" ^ hook_name h ])

let say t h fmt =
  Printf.ksprintf
    (fun line ->
      Out_channel.with_open_gen [ Open_append; Open_creat; Open_wronly ]
        0o600 (log_path t h) (fun oc ->
          Printf.fprintf oc "%s digestif: %s\n" (Time_fmt.now ()) line))
    fmt

(* Spawn [h]: its context on stdin through a file unlinked once the child holds it, stdout and stderr
   appended to behaviors/<hook>.log. *)
let spawn ?(now = Unix.gettimeofday ()) t h =
  match executable t.node.log h with
  | None -> Error (hook_name h ^ ": no behavior is set")
  | Some _ when is_running t h -> Error (hook_name h ^ ": already running")
  | Some exe -> (
      (* A checkout's behaviors/ path runs from the current release (docs/releases.md). *)
      let exe = Digestif_update.Layout.hook_path ~dir:t.node.dir exe in
      Node.mkdir_p (dir t);
      let deadline = now +. timeout h in
      let session =
        Option.map (fun _ -> Store.new_session t.node.log) t.api_url
      in
      let api =
        match (t.api_url, session) with
        | Some url, Some session -> Some { url; session }
        | _ -> None
      in
      let ctx =
        context ~log:t.node.log ~hook:h ~dir:t.node.dir ~digestif:t.digestif
          ~api
          ~sources:(chosen_sources t.node.log)
          ~now ~deadline ()
      in
      let ctx_path = Filename.concat (dir t) (hook_name h ^ ".context.json") in
      let end_session () = Option.iter (Store.end_session t.node.log) session in
      try
        Out_channel.with_open_gen [ Open_trunc; Open_creat; Open_wronly ]
          0o600 ctx_path (fun oc -> Yojson.Safe.to_channel oc ctx);
        let stdin = Unix.openfile ctx_path [ O_RDONLY; O_CLOEXEC ] 0 in
        Sys.remove ctx_path;
        let out =
          Unix.openfile (log_path t h)
            [ O_WRONLY; O_APPEND; O_CREAT; O_CLOEXEC ]
            0o600
        in
        say t h "spawn %s" exe;
        let pid =
          Fun.protect
            ~finally:(fun () -> List.iter Unix.close [ stdin; out ])
            (fun () ->
              Unix.create_process_env exe [| exe |] (environment t h) stdin out
                out)
        in
        t.running <-
          {
            hook = h;
            pid;
            started = now;
            date = local_date now;
            session;
            awake = 0.;
            seen = now;
            terminated = None;
          }
          :: t.running;
        Ok pid
      with
      | Unix.Unix_error (e, _, _) ->
          end_session ();
          (try Sys.remove ctx_path with Sys_error _ -> ());
          Error (Printf.sprintf "%s: %s" exe (Unix.error_message e))
      | Sys_error e ->
          end_session ();
          Error e)

type finished = { f_hook : hook; status : string; seconds : float }

(* OCaml's signal numbers are its own negative constants, so the two the node sends are named. *)
let signal_name s =
  if s = Sys.sigterm then "SIGTERM"
  else if s = Sys.sigkill then "SIGKILL"
  else Printf.sprintf "signal %d" s

let status_of = function
  | Unix.WEXITED c -> Printf.sprintf "exited %d" c
  | WSIGNALED s -> "killed by " ^ signal_name s
  | WSTOPPED s -> "stopped by " ^ signal_name s

(* The nightly's local date is over once a run exits 0 (it posted, had nothing to say, or spent its
   own tries) or after [max_tries] runs that did not; until then each pass tries again. The node
   records a run that never said why as a failed tick, which the Approvals page shows. *)
let failures (log : Log.t) ~date =
  match
    Option.map (String.split_on_char ' ') (Log.get_config log k_failures)
  with
  | Some [ d; n ] when d = date -> Option.value (int_of_string_opt n) ~default:0
  | _ -> 0

let date_handled (log : Log.t) date =
  match last_date log with Some d -> d >= date | None -> false

let handle_date (log : Log.t) date =
  if not (date_handled log date) then Log.set_config log k_last_date date;
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_failures ]

let settle_nightly ~say (log : Log.t) r status =
  if status = "exited 0" then handle_date log r.date
  else if not (date_handled log r.date) then begin
    let n = failures log ~date:r.date + 1 in
    if n >= max_tries then begin
      handle_date log r.date;
      ignore
        (Store.add_silence_note log ~outcome:Store.Failed
           (Printf.sprintf "The nightly note failed %d times; the last run %s."
              n status));
      say (Printf.sprintf "%d runs failed; %s is over" n r.date)
    end
    else begin
      Log.set_config log k_failures (Printf.sprintf "%s %d" r.date n);
      say
        (Printf.sprintf "run %d of %d failed; the next pass tries again" n
           max_tries)
    end
  end

(* Add the time since the last reap to a run's awake time, unless the gap says the machine slept. *)
let count_awake r ~now =
  let gap = now -. r.seen in
  if gap > 0. && gap <= sleep_gap then r.awake <- r.awake +. gap;
  r.seen <- Float.max r.seen now

(* Collect every behavior that exited, end its session, and end every one past its deadline. *)
let reap ?(now = Unix.gettimeofday ()) t =
  let finished, running =
    List.partition_map
      (fun r ->
        match Unix.waitpid [ WNOHANG ] r.pid with
        | 0, _ ->
            count_awake r ~now;
            (match r.terminated with
            | None when r.awake >= timeout r.hook ->
                say t r.hook "past its deadline; ending it";
                (try Unix.kill r.pid Sys.sigterm with Unix.Unix_error _ -> ());
                r.terminated <- Some now
            | Some at when now -. at >= grace -> (
                try Unix.kill r.pid Sys.sigkill with Unix.Unix_error _ -> ())
            | _ -> ());
            Right r
        | _, st -> Left (r, status_of st)
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Left (r, "gone")
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> Right r)
      t.running
  in
  t.running <- running;
  List.map
    (fun (r, status) ->
      Option.iter (Store.end_session t.node.log) r.session;
      say t r.hook "%s" status;
      if r.hook = Nightly then
        settle_nightly ~say:(say t Nightly "%s") t.node.log r status;
      { f_hook = r.hook; status; seconds = now -. r.started })
    finished

(* Wait for every running behavior, ending any past its deadline: for `digestif behavior run`. *)
let wait_all ?(clock = Unix.gettimeofday) t =
  let rec go acc =
    if t.running = [] then List.rev acc
    else begin
      let f = reap ~now:(clock ()) t in
      (if t.running <> [] then
         try Unix.sleepf 0.2 with Unix.Unix_error (Unix.EINTR, _, _) -> ());
      go (List.rev_append f acc)
    end
  in
  go []

(* What a pass of `digestif run` spawns: the nightly behavior when it is due or the member asked
   for a note now, the read behavior when the sync stored something new. Each runs at most once at a time. *)
let after_pass ?(now = Unix.gettimeofday ()) t ~stored =
  let run_now = Store.nightly_run_requested t.node.log in
  if run_now then Store.clear_nightly_run t.node.log;
  let want =
    (if
       (run_now || nightly_due t.node.log ~now)
       && executable t.node.log Nightly <> None
       && not (is_running t Nightly)
     then [ Nightly ]
     else [])
    @
    if
      stored > 0
      && executable t.node.log Read <> None
      && not (is_running t Read)
    then [ Read ]
    else []
  in
  List.map (fun h -> (h, spawn ~now t h)) want

(* The node is stopping: end every running behavior and its session. *)
let stop_all t =
  List.iter
    (fun r ->
      (try Unix.kill r.pid Sys.sigterm with Unix.Unix_error _ -> ());
      Option.iter (Store.end_session t.node.log) r.session;
      say t r.hook "the node is stopping; ended it")
    t.running;
  t.running <- []

let busy t = t.running <> []
