(* `digestif supervise`: what the launchd agent or systemd unit runs. It is the binary of the last
   release that reported healthy (Layout.good), and it runs the node, `current/bin/digestif run`, as
   its child. Outside a switch it only passes the child's exit on to the service manager, which
   restarts it. During a switch's trial it watches the child: once the new release writes
   health.json the switch is kept (good moves, update.json records the version); if the child
   exits first, or stays unhealthy for [health_bound] seconds of awake time, current moves back to
   good and the version is refused from then on. The recovery lives here, not in `digestif run`,
   because a release that crashes on start cannot run code to fix itself. *)

(* Seconds of awake time a new release has to report healthy (Awake). *)
let health_bound = 600.

(* Supervisor starts a trial gets before it is rolled back, for a machine that restarts mid-trial. *)
let max_starts = 3

(* How often the supervisor looks at its child. *)
let step = 1.

type exit_status = Exited of int | Signaled of int

let describe = function
  | Exited n -> Printf.sprintf "exited with status %d" n
  | Signaled s -> Printf.sprintf "was killed by signal %d" s

(* What the supervisor does to the world, replaced in tests. *)
type ops = {
  spawn : string -> int;  (** Start `<binary> run` and return its pid. *)
  poll : int -> exit_status option;
      (** The child's status once it has exited. *)
  terminate : int -> unit;  (** Stop the child and wait for it. *)
  sleep : float -> unit;
  wall : unit -> float;
  stopping : unit -> bool;  (** The service manager asked us to stop. *)
}

type outcome =
  | Healthy of Version.t
  | Rolled_back of Version.t * string
  | Interrupted of Version.t
      (** The service manager stopped the supervisor mid-trial; the next start
          resumes it. *)

let report dir lines = Report.note (Schedule.report_path dir) lines

let promote dir (t : Trial.t) =
  Layout.point_good dir t.release;
  let path = Schedule.state_path dir in
  (match State.load path with
  | Ok s ->
      let pending =
        match s.pending with
        | Some p when Version.compare p.pending_version t.version <= 0 -> None
        | p -> p
      in
      State.save path { s with installed = t.version; pending }
  | Error _ -> ());
  Trial.clear dir;
  report dir [ "Updated Digestif to " ^ Version.to_string t.version ^ "." ];
  Healthy t.version

let roll_back dir (t : Trial.t) why =
  Layout.point_current dir t.previous;
  let path = Schedule.state_path dir in
  (match State.load path with
  | Ok s -> State.save path (State.refuse s t.version why)
  | Error _ -> ());
  Trial.clear dir;
  let back =
    match Layout.version_of dir t.previous with
    | Some v -> Version.to_string v
    | None -> t.previous
  in
  report dir
    [
      Printf.sprintf "Release %s was rolled back to %s: %s."
        (Version.to_string t.version)
        back why;
    ];
  Rolled_back (t.version, why)

let binary dir = Layout.binary_in (Layout.current_link dir)

(* Run a trial to its end: the child stays running when the release is kept. *)
let trial ops dir (t : Trial.t) =
  if t.starts >= max_starts then
    ( None,
      roll_back dir t
        (Printf.sprintf "it did not report healthy in %d starts" max_starts) )
  else begin
    Trial.save dir { t with starts = t.starts + 1 };
    let pid = ops.spawn (binary dir) in
    let healthy () =
      match Health.read dir with
      | Some h -> h.pid = pid && h.version = Version.to_string t.version
      | None -> false
    in
    let rec watch awake =
      if healthy () then (Some pid, promote dir t)
      else
        match ops.poll pid with
        | Some st ->
            (None, roll_back dir t (describe st ^ " before it reported healthy"))
        | None ->
            if ops.stopping () then begin
              (* Not the release's fault: the next supervisor start tries again. *)
              ops.terminate pid;
              (None, Interrupted t.version)
            end
            else if awake.Awake.elapsed >= health_bound then begin
              ops.terminate pid;
              ( None,
                roll_back dir t
                  (Printf.sprintf
                     "it did not report healthy within %.0f minutes of awake \
                      time"
                     (health_bound /. 60.)) )
            end
            else
              let before = ops.wall () in
              ops.sleep step;
              watch
                (Awake.step awake ~nominal:step
                   ~wall_delta:(ops.wall () -. before))
    in
    watch Awake.zero
  end

(* Wait for a running child; its exit ends the supervisor unless the child started a switch. *)
let rec wait ops pid =
  match ops.poll pid with
  | Some st -> st
  | None ->
      if ops.stopping () then begin
        ops.terminate pid;
        Exited 0
      end
      else begin
        ops.sleep step;
        wait ops pid
      end

(* The supervisor's life: returns the status to exit with. Every trial it ends is passed to
   [on_trial], for the log. *)
let rec run ?(on_trial = fun _ -> ()) ops dir =
  match Trial.load dir with
  | Some t -> (
      let child, outcome = trial ops dir t in
      on_trial outcome;
      if ops.stopping () then Exited 0
      else
        match child with
        | Some pid -> after_child ~on_trial ops dir (wait ops pid)
        | None -> run ~on_trial ops dir)
  | None ->
      let pid = ops.spawn (binary dir) in
      after_child ~on_trial ops dir (wait ops pid)

and after_child ~on_trial ops dir status =
  (* A child that exits after starting a switch hands over to the trial. *)
  if (not (ops.stopping ())) && Trial.load dir <> None then
    run ~on_trial ops dir
  else status

(* The real world. *)

let stop_requested = ref false

let real_ops ~dir =
  {
    spawn =
      (fun exe ->
        Unix.create_process exe
          [| exe; "run"; "--data-dir"; dir |]
          Unix.stdin Unix.stdout Unix.stderr);
    poll =
      (fun pid ->
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ -> None
        | _, Unix.WEXITED n -> Some (Exited n)
        | _, (Unix.WSIGNALED s | Unix.WSTOPPED s) -> Some (Signaled s)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> None
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Exited 0));
    terminate =
      (fun pid ->
        (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
        let rec reap n =
          match Unix.waitpid [ Unix.WNOHANG ] pid with
          | 0, _ when n > 0 ->
              (try Unix.sleepf 0.2
               with Unix.Unix_error (Unix.EINTR, _, _) -> ());
              reap (n - 1)
          | 0, _ -> (
              (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
              try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ())
          | _ -> ()
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap n
          | exception Unix.Unix_error _ -> ()
        in
        (* The node gives running behaviors 30 seconds; this waits a little longer. *)
        reap 200);
    sleep =
      (fun s ->
        try Unix.sleepf s with Unix.Unix_error (Unix.EINTR, _, _) -> ());
    wall = Unix.gettimeofday;
    stopping = (fun () -> !stop_requested);
  }
