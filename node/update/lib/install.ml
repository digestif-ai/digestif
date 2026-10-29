(* Replacing the running binary with a verified artifact. The bytes are checked against the size
   and hash both signers signed before anything on disk changes, then swapped in by rename, keeping
   the previous binary beside it as <binary>.previous. *)

let verify_artifact (a : Release.artifact) bytes =
  if String.length bytes <> a.size then
    Error
      (Printf.sprintf "artifact for %s is %d bytes, the manifest says %d"
         a.platform (String.length bytes) a.size)
  else
    let got = Crypto.sha256 bytes in
    if got <> a.sha256 then
      Error
        (Printf.sprintf "artifact for %s hashes to %s, the manifest says %s"
           a.platform got a.sha256)
    else Ok ()

let replace ~binary bytes =
  let staged = binary ^ ".next" and previous = binary ^ ".previous" in
  match
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o755 staged
      (fun oc -> Out_channel.output_string oc bytes);
    Unix.chmod staged 0o755;
    if Sys.file_exists binary then begin
      if Sys.file_exists previous then Sys.remove previous;
      Unix.link binary previous
    end;
    Unix.rename staged binary
  with
  | () -> Ok ()
  | exception Unix.Unix_error (e, f, p) ->
      Error (Printf.sprintf "%s %s: %s" f p (Unix.error_message e))
  | exception Sys_error e -> Error e
