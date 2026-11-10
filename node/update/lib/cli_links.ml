(* The commands a member runs from PATH follow the node's last healthy release (docs/releases.md,
   The commands on PATH). ~/.local/bin/digestif and ~/.local/bin/digestif-update are symlinks to
   <data dir>/good/bin/<name>, so every update the node keeps moves them with it, and the
   digestif-update a signer signs with is only ever one the node's own signature check took.

   The hosted install links them to the release it staged, since good does not exist until
   `digestif service install` makes the layout; that install, every start of the supervisor and
   every pass of `digestif run` point them at good, after which they follow good with nothing more
   to do. The pass is the step an automatic update reaches: the supervisor that was running keeps
   running and starts the new release's `run`, so a node whose supervisor predates a link change
   gets it from the first pass of the release that carries it, and a digestif-update the old good
   lacked is made on the first pass after the new release becomes good. A link into this node's releases/ is the
   install's and is moved; anything else at that path (a binary install.sh copied from a checkout,
   a link the member made elsewhere) is the member's and is left alone. A missing digestif-update
   is made beside an existing ~/.local/bin, since nothing else puts the signer's tool on PATH; a
   missing digestif is not, since a member who builds from source may keep the CLI elsewhere on
   PATH (install.sh). *)

let names = [ "digestif"; "digestif-update" ]

(* The directory both links live in, ~/.local/bin, or None with no HOME. *)
let default_bin_dir () =
  match Sys.getenv_opt "HOME" with
  | Some h when h <> "" -> Some (Filename.concat h ".local/bin")
  | _ -> None

let absolute dir =
  if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir

let target ~dir name =
  Filename.concat (Filename.concat (Layout.good_link (absolute dir)) "bin") name

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Whether [link]'s text names something under this node's releases/ or good/current, by the data
   directory as given or as its real path (a link written through either spelling). *)
let ours ~dir link_text =
  let dir = absolute dir in
  let roots =
    dir :: (try [ Unix.realpath dir ] with Unix.Unix_error _ -> [])
  in
  List.exists
    (fun root ->
      List.exists
        (fun sub ->
          starts_with ~prefix:(Filename.concat root sub ^ "/") link_text)
        [ "releases"; "good"; "current" ])
    roots

type change = { path : string; was : string option; now : string }

(* What to do with [path] for the link [name]: Some the target to point it at, or None to leave it.
   A release good names that lacks the command (one staged from a checkout carries bin/digestif
   alone, Stage.local) gets no link to it. *)
let decide ~dir ~name path =
  let want = target ~dir name in
  if not (Sys.file_exists want) then None
  else
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        if name = "digestif-update" && Sys.file_exists (Filename.dirname path)
        then Some (None, want)
        else None
    | exception Unix.Unix_error _ -> None
    | { Unix.st_kind = Unix.S_LNK; _ } -> (
        match Unix.readlink path with
        | exception Unix.Unix_error _ -> None
        | t when t = want -> None
        | t when ours ~dir t -> Some (Some t, want)
        | _ -> None)
    | _ -> None

(* Replace [path] with a symlink to [want], atomically: a new link beside it renamed over it. *)
let point path want =
  let tmp = path ^ ".tmp" in
  (try Unix.unlink tmp with Unix.Unix_error _ -> ());
  Unix.symlink want tmp;
  Unix.rename tmp path

(* Point each command in [bin_dir] at the node's good release, as above. Does nothing before good
   exists. Returns what changed; a link that cannot be written is an Error naming it, and the
   others are still tried. *)
let link ~dir ~bin_dir =
  if Layout.good dir = None then Ok []
  else
    let results =
      List.filter_map
        (fun name ->
          let path = Filename.concat bin_dir name in
          match decide ~dir ~name path with
          | None -> None
          | Some (was, now) -> (
              match point path now with
              | () -> Some (Ok { path; was; now })
              | exception Unix.Unix_error (e, _, _) ->
                  Some
                    (Error
                       (Printf.sprintf "%s not linked to %s: %s" path now
                          (Unix.error_message e)))))
        names
    in
    match
      List.filter_map (function Error e -> Some e | Ok _ -> None) results
    with
    | [] ->
        Ok
          (List.filter_map
             (function Ok c -> Some c | Error _ -> None)
             results)
    | errors -> Error (String.concat "; " errors)

let describe c = Printf.sprintf "%s -> %s" c.path c.now

(* [link] for ~/.local/bin, with every change and failure printed as one line on stderr: a link
   is never a reason for a service install, the supervisor or the node to fail. [last] carries the
   failure printed before, so a caller that repeats the step (each pass of `digestif run`) prints
   a failure once, until it changes or clears. *)
let link_default ?(last = ref None) ~dir () =
  match default_bin_dir () with
  | None -> ()
  | Some bin_dir -> (
      match link ~dir ~bin_dir with
      | Ok changes ->
          last := None;
          List.iter
            (fun c -> Printf.eprintf "linked %s\n%!" (describe c))
            changes
      | Error e ->
          if !last <> Some e then Printf.eprintf "%s\n%!" e;
          last := Some e)
