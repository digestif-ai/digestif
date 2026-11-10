(* Run a program with an argv (no shell), feed it stdin, collect stdout and stderr. *)

type result = { code : int; stdout : string; stderr : string }

(* Reads both pipes to their ends together, so a program filling one never blocks on the other. With
   a deadline, returns false the moment it passes, leaving the pipes unread. *)
let read_both ?deadline out_fd err_fd =
  let out = Buffer.create 4096 and err = Buffer.create 256 in
  let chunk = Bytes.create 65536 in
  let rec go fds =
    if fds = [] then true
    else
      let wait =
        match deadline with
        | None -> -1.0
        | Some d -> Float.max 0.0 (d -. Unix.gettimeofday ())
      in
      if wait = 0.0 then false
      else
        match Unix.select fds [] [] wait with
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> go fds
        | [], _, _ -> go fds
        | ready, _, _ ->
            go
              (List.filter
                 (fun fd ->
                   if not (List.memq fd ready) then true
                   else
                     match Unix.read fd chunk 0 (Bytes.length chunk) with
                     | 0 -> false
                     | n ->
                         Buffer.add_subbytes
                           (if fd == out_fd then out else err)
                           chunk 0 n;
                         true
                     | exception Unix.Unix_error (Unix.EINTR, _, _) -> true)
                 fds)
  in
  let finished = go [ out_fd; err_fd ] in
  (finished, Buffer.contents out, Buffer.contents err)

(* Kill a run started with [~group:true]: its whole process group, so what it spawned goes too, and
   the program itself should the group not exist. *)
let kill_group pid =
  (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
  try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

(* Kill the process group [pgid] only, never a process of that number: for a group recorded by an
   earlier process, whose leader may be gone and its number reused. Only the number is known then
   (OCaml's Unix has no getpgid), so a group that has since been reused by another leader is a
   window this cannot close; a group that no longer exists is a no-op. *)
let kill_pgid pgid =
  (* Never this process's own group, nor its parent's: a reused number can be the group the new node
     leads (a node started by launchd leads its own), and killing it would kill the node. *)
  if pgid > 1 && pgid <> Unix.getpid () && pgid <> Unix.getppid () then
    try Unix.kill (-pgid) Sys.sigkill with Unix.Unix_error _ -> ()

(* [timeout] seconds after the start the program is killed and the run is an error. [env] is added
   to the environment the program inherits, each "NAME=value" replacing an inherited NAME. With
   [group] the program leads a process group of its own (setsid in the forked child before exec), and
   the deadline kills the group, so what the program spawned does not outlive it; a program that
   cannot be started then reads as exit 127, not as an error. [on_spawn] is told the pid once the
   program runs, so a caller can kill it (kill_group) before the deadline. *)
let run ?(stdin = "") ?timeout ?(env = []) ?(group = false) ?on_spawn argv =
  let deadline = Option.map (fun t -> Unix.gettimeofday () +. t) timeout in
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err_r, err_w = Unix.pipe ~cloexec:true () in
  let environment () =
    let name kv =
      match String.index_opt kv '=' with
      | Some i -> String.sub kv 0 i
      | None -> kv
    in
    let names = List.map name env in
    let inherited =
      List.filter
        (fun kv -> not (List.mem (name kv) names))
        (Array.to_list (Unix.environment ()))
    in
    Array.of_list (inherited @ env)
  in
  let spawn () =
    if group then (
      let envp = environment () in
      match Unix.fork () with
      | 0 ->
          (try
             ignore (Unix.setsid ());
             Unix.dup2 in_r Unix.stdin;
             Unix.dup2 out_w Unix.stdout;
             Unix.dup2 err_w Unix.stderr;
             Unix.execvpe argv.(0) argv envp
           with _ -> ());
          Unix._exit 127
      | pid -> pid)
    else if env = [] then Unix.create_process argv.(0) argv in_r out_w err_w
    else
      Unix.create_process_env argv.(0) argv (environment ()) in_r out_w err_w
  in
  match spawn () with
  | exception Unix.Unix_error (e, _, _) ->
      List.iter Unix.close [ in_r; in_w; out_r; out_w; err_r; err_w ];
      Error (Printf.sprintf "%s: %s" argv.(0) (Unix.error_message e))
  | pid ->
      List.iter Unix.close [ in_r; out_w; err_w ];
      Option.iter (fun f -> f pid) on_spawn;
      (* Write stdin from a thread of control that cannot block the reads: the input is small (a key,
         an envelope under the relay's size cap), so write it whole before reading. *)
      let sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
      (try
         let b = Bytes.of_string stdin in
         let rec write off =
           if off < Bytes.length b then
             write (off + Unix.write in_w b off (Bytes.length b - off))
         in
         write 0
       with Unix.Unix_error _ -> ());
      Unix.close in_w;
      Sys.set_signal Sys.sigpipe sigpipe;
      let finished, stdout, stderr = read_both ?deadline out_r err_r in
      (if not finished then
         if group then kill_group pid
         else try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      Unix.close out_r;
      Unix.close err_r;
      let rec wait () =
        try snd (Unix.waitpid [] pid)
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      in
      let status = wait () in
      if not finished then
        Error
          (Printf.sprintf "%s: still running after %.0f seconds" argv.(0)
             (Option.value timeout ~default:0.0))
      else
        let code =
          match status with
          | Unix.WEXITED c -> c
          | WSIGNALED s | WSTOPPED s -> 128 + abs s
        in
        Ok { code; stdout; stderr }
