(* THE TIMING LOG OF A RUN (docs/releases.md, What it shows, and the question): how long each step
   of a `digestif-update sign --next` took, appended to a file under the tool's state directory, one
   line per step, so a later run can be optimized from data rather than from a guess. A line is

     <run id> TAB <step> TAB <seconds>

   the run id being the run's start in UTC and the process id, so the lines of one run read
   together and two runs never share one. Nothing of it is printed: the terminal shows what it
   showed before. A log that cannot be written is skipped, never a failure of the run. Steps may
   run concurrently ({!Parallel}), so a line is written under a lock. *)

type t = {
  run : string;
  path : string option;  (** None: nothing is recorded. *)
  started : float;
  lock : Mutex.t;
}

let run_id now =
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ-%d" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec (Unix.getpid ())

let create ?path () =
  let started = Unix.gettimeofday () in
  { run = run_id started; path; started; lock = Mutex.create () }

(* A run that records nothing: tests, and every caller without a state directory. *)
let none = create ()

let line t ~step seconds = Printf.sprintf "%s\t%s\t%.3f\n" t.run step seconds

let record t ~step seconds =
  match t.path with
  | None -> ()
  | Some path ->
      Mutex.protect t.lock (fun () ->
          try
            Out_channel.with_open_gen
              [ Open_append; Open_creat; Open_wronly; Open_binary ]
              0o644 path
              (fun oc -> Out_channel.output_string oc (line t ~step seconds))
          with Sys_error _ -> ())

(* Run [f] as the step [step] and record how long it took, whether it answered or raised. *)
let time t step f =
  let t0 = Unix.gettimeofday () in
  Fun.protect
    ~finally:(fun () -> record t ~step (Unix.gettimeofday () -. t0))
    f

(* Record, as [step], the time since the run started: "until-question" and "total". *)
let mark t step = record t ~step (Unix.gettimeofday () -. t.started)
