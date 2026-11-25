(* The macOS service's fixed-path launcher, <data dir>/launcher/Digestif (docs/releases.md,
   The launcher). It spawns its arguments, forwards SIGTERM, SIGINT and SIGHUP to them, waits, and
   exits with the child's status.

   macOS records a privacy decision against the process it holds responsible for an access: the
   program a launchd job starts. For a bare executable that subject is its resolved path, and the
   supervisor's path names its release, so every release was a program macOS had never been asked
   about. This program sits at one path and its bytes change only when this directory does
   (Launcher.ensure), so a decision a person makes once holds across every release beneath it.
   DIG-492

   It spawns and never execs: an exec would replace this program with the supervisor, which is
   how the supervisor's versioned path became the subject. Staying alive as the parent is the whole
   of what it is for.

   It reads no configuration and knows nothing about Digestif: the command is its arguments, run
   with this process's environment and file descriptors. Anything it interpreted would be a rule
   living in bytes that are replaced only when this directory changes. It links the standard
   library and unix alone, for the same reason. *)

let usage = "usage: Digestif COMMAND [ARG...]"

(* sysexits' EX_USAGE, and the shell's two statuses for a command that could not be started. *)
let exit_usage = 64
let exit_not_found = 127
let exit_not_executable = 126

(* SIGTERM is how launchd stops the job, SIGINT a person's ^C in a terminal. *)
let forwarded = [ Sys.sigterm; Sys.sigint; Sys.sighup ]

(* The POSIX number of a signal, for the 128 + N status a shell reports; OCaml numbers signals
   with negative constants of its own. *)
let posix_number signal =
  List.assoc_opt signal
    [
      (Sys.sighup, 1);
      (Sys.sigint, 2);
      (Sys.sigquit, 3);
      (Sys.sigill, 4);
      (Sys.sigabrt, 6);
      (Sys.sigfpe, 8);
      (Sys.sigkill, 9);
      (Sys.sigsegv, 11);
      (Sys.sigpipe, 13);
      (Sys.sigalrm, 14);
      (Sys.sigterm, 15);
    ]

(* The child once it exists, and the signals that arrived before it did: the handlers are set
   before the spawn, so a SIGTERM in between is held and delivered. *)
let child = ref None
let pending = ref []
let deliver pid signal = try Unix.kill pid signal with Unix.Unix_error _ -> ()

let forward signal =
  match !child with
  | Some pid -> deliver pid signal
  | None -> pending := signal :: !pending

(* Die of [signal], so launchd reads the death the child had. *)
let die_of signal =
  (try
     Sys.set_signal signal Sys.Signal_default;
     Unix.kill (Unix.getpid ()) signal
   with Invalid_argument _ | Sys_error _ | Unix.Unix_error _ -> ());
  exit (128 + Option.value (posix_number signal) ~default:0)

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let run argv =
  List.iter (fun s -> Sys.set_signal s (Sys.Signal_handle forward)) forwarded;
  let prog = argv.(0) in
  match Unix.create_process prog argv Unix.stdin Unix.stdout Unix.stderr with
  | exception Unix.Unix_error (err, _, _) ->
      prerr_endline
        (Printf.sprintf "Digestif: cannot run %s: %s" prog
           (Unix.error_message err));
      exit (if err = Unix.ENOENT then exit_not_found else exit_not_executable)
  | pid -> (
      child := Some pid;
      List.iter (deliver pid) (List.rev !pending);
      pending := [];
      match wait pid with
      | Unix.WEXITED code -> exit code
      | Unix.WSIGNALED signal -> die_of signal
      | Unix.WSTOPPED _ -> exit 1)

let () =
  match Array.to_list Sys.argv with
  | [] | [ _ ] ->
      prerr_endline usage;
      exit exit_usage
  | _ :: command -> run (Array.of_list command)
