(* The macOS service's launcher at one fixed path, <data dir>/launcher/Digestif
   (docs/releases.md, The launcher). launchd starts it, and it spawns the supervisor, so macOS
   holds it responsible for every access the node and its behaviors make: a privacy grant is
   keyed to this path and these bytes, not to the supervisor's release path, and a person answers
   each prompt once per machine.

   The bytes are the launcher every node binary embeds (launcher_data.ml, from ../../launcher), and
   they are written here only when the digest of the source they were built from differs from the
   one recorded beside them. A release rebuilt from the same launcher source, with whatever
   compiler or linker, leaves the installed bytes, and the grant keyed to their cdhash, as they
   are. The bytes come from a binary both release signers signed, or one the member built; nothing
   else ever writes here. DIG-492 *)

let name = "Digestif"
let dir_in dir = Filename.concat dir "launcher"
let path dir = Filename.concat (dir_in dir) name
let source_path dir = path dir ^ ".source"

let executable p =
  try
    Unix.access p [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

(* The launcher the service runs through, once one is installed: macOS only, since no other
   system keys a decision to a path. *)
let installed ?(macos = Keystore.is_macos ()) dir =
  let p = path dir in
  if macos && executable p then Some p else None

type outcome =
  | Unchanged  (** The installed launcher was built from this source. *)
  | Installed  (** Written now: none was there, or its source differs. *)
  | Not_used  (** Not macOS, or this binary embeds no launcher. *)

let read_opt p =
  match In_channel.with_open_bin p In_channel.input_all with
  | s -> Some (String.trim s)
  | exception Sys_error _ -> None

(* Write [contents] to [p] through a file beside it renamed over it, so a reader (launchd starting
   the job) sees the old bytes or the new ones and never part of either. *)
let write_atomic ~perm p contents =
  let tmp = p ^ ".tmp" in
  (try Sys.remove tmp with Sys_error _ -> ());
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    perm tmp (fun oc -> output_string oc contents);
  Unix.chmod tmp perm;
  Unix.rename tmp p

(* Put this binary's launcher at the fixed path unless the one there was built from the same
   source. The digest is written after the bytes, so a write cut short is redone next time. *)
let ensure ?(macos = Keystore.is_macos ()) ?(bytes = Launcher_data.bytes)
    ?(source = Launcher_data.source) dir =
  if (not macos) || bytes = "" then Ok Not_used
  else if executable (path dir) && read_opt (source_path dir) = Some source then
    Ok Unchanged
  else
    try
      Node.mkdir_p (dir_in dir);
      write_atomic ~perm:0o755 (path dir) bytes;
      write_atomic ~perm:0o644 (source_path dir) (source ^ "\n");
      Ok Installed
    with
    | Sys_error e ->
        Error (Printf.sprintf "launcher not installed at %s: %s" (path dir) e)
    | Unix.Unix_error (err, _, _) ->
        Error
          (Printf.sprintf "launcher not installed at %s: %s" (path dir)
             (Unix.error_message err))
