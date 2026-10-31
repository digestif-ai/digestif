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

(* [timeout] seconds after the start the program is killed and the run is an error. *)
let run ?(stdin = "") ?timeout argv =
  let deadline = Option.map (fun t -> Unix.gettimeofday () +. t) timeout in
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err_r, err_w = Unix.pipe ~cloexec:true () in
  match Unix.create_process argv.(0) argv in_r out_w err_w with
  | exception Unix.Unix_error (e, _, _) ->
      List.iter Unix.close [ in_r; in_w; out_r; out_w; err_r; err_w ];
      Error (Printf.sprintf "%s: %s" argv.(0) (Unix.error_message e))
  | pid ->
      List.iter Unix.close [ in_r; out_w; err_w ];
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
         try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
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
