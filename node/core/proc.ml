(* Run a program with an argv (no shell), feed it stdin, collect stdout and stderr. *)

let read_all fd =
  let buf = Buffer.create 4096 and chunk = Bytes.create 65536 in
  let rec go () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        go ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ();
  Buffer.contents buf

type result = { code : int; stdout : string; stderr : string }

let run ?(stdin = "") argv =
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
      let stdout = read_all out_r in
      let stderr = read_all err_r in
      Unix.close out_r;
      Unix.close err_r;
      let rec wait () =
        try snd (Unix.waitpid [] pid)
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      in
      let code =
        match wait () with
        | Unix.WEXITED c -> c
        | WSIGNALED s | WSTOPPED s -> 128 + abs s
      in
      Ok { code; stdout; stderr }
