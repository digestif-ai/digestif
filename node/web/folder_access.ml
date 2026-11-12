(* ISS-81607 (docs/design.md, Reaching a person): the folders macOS keeps behind its privacy
   protection, checked ahead of a reading. A node that launchd started without Full Disk Access is
   refused (EPERM) on ~/Documents, ~/Desktop and ~/Downloads, and the sessions reader skips every
   project under a folder it cannot judge (Sources, DIG-349), so the member's notes go quiet.

   When the node starts, and once a day after, each folder is tried with one opendir and one
   readdir, never more: no walk below its top level, no file opened, nothing written to it. A
   folder that refuses (EACCES or EPERM) and holds at least one known session project, read from
   the names of the chosen Claude Code source's project directories alone, is kept here as
   refused. Each one is a notice from the node (Digest_lines), local to this machine (Item), raised
   once, Done by itself once the folder can be listed again, and raised again only after a new
   refusal. The result stays in this node's config and never leaves the machine. *)

open Digestif_core

let folders = [ "Documents"; "Desktop"; "Downloads" ]

(* How long the result of a check stands before the next pass takes another. *)
let max_age = 86400.

(* While a folder stands refused, the check is taken this often instead, so a notice goes Done
   within the hour of the member granting access rather than the next day. *)
let refused_max_age = 3600.
let k_checked_at = "folder_access_checked_at"

(* The folders the last check found refused with a session project under them, one per line. *)
let k_refused = "folder_access_refused"

(* The refused folders whose notice has been raised, pruned to the refused ones on every check, so
   a folder whose access came back is raised again on its next refusal. *)
let k_told = "folder_access_told"

type probe = {
  opendir : string -> Unix.dir_handle; (* test hook *)
  readdir : Unix.dir_handle -> string; (* test hook *)
  closedir : Unix.dir_handle -> unit; (* test hook *)
}

let default_probe =
  { opendir = Unix.opendir; readdir = Unix.readdir; closedir = Unix.closedir }

(* Whether macOS refuses [dir]: one opendir and one readdir, as the judging listings read a folder
   (Sources.with_dir), and no more of it. A folder that is not there, or fails otherwise, is not
   refused: only a missing permission is what this check tells of. *)
let refused probe dir =
  match probe.opendir dir with
  | exception Unix.Unix_error ((EACCES | EPERM), _, _) -> true
  | exception Unix.Unix_error _ -> false
  | h ->
      Fun.protect
        ~finally:(fun () -> try probe.closedir h with _ -> ())
        (fun () ->
          match probe.readdir h with
          | exception Unix.Unix_error ((EACCES | EPERM), _, _) -> true
          | exception _ -> false
          | _ -> false)

(* The project directory names of [projects] (each a ~/.claude/projects) that name a path at or
   under [dir]. Claude Code names a project's directory by its path with every character but a
   letter or digit turned to '-' (Sources.encode_segment), so a project under ~/Documents is named
   <encoded ~/Documents>-...: read from the names alone, since decoding one would list the folder
   that refuses. *)
let projects_under ~names dir =
  let prefix = Sources.encode_segment dir in
  let n = String.length prefix in
  List.filter
    (fun name ->
      name = prefix
      || String.length name > n
         && String.sub name 0 n = prefix
         && name.[n] = '-')
    names

(* The names of the session projects this node reads: the project directories of each chosen Claude
   Code source. A machine whose member reads no sessions has none, and nothing a refusal could
   skip. *)
let session_project_names (log : Log.t) =
  Store.sources log
  |> List.filter (fun (s : Store.source) ->
      s.selected && s.kind = "claude_code")
  |> List.concat_map (fun (s : Store.source) ->
      List.map Sources.untilde s.paths)
  |> List.concat_map (fun p -> List.map Filename.basename (Sources.children p))
  |> Sources.dedupe

(* Each refused folder with how many session projects sit under it, in [folders] order. *)
let check ?(probe = default_probe) ?(home = Sources.home ()) ~names () =
  List.filter_map
    (fun f ->
      let dir = Filename.concat home f in
      match projects_under ~names dir with
      | [] -> None
      | under ->
          if refused probe dir then Some (dir, List.length under) else None)
    folders

let lines s = List.filter (( <> ) "") (String.split_on_char '\n' s)
let config_list log k = Option.fold ~none:[] ~some:lines (Store.config log k)

(* What the last check found: each refused folder and its project count. *)
let refused_folders (log : Log.t) =
  config_list log k_refused
  |> List.filter_map (fun l ->
      match String.rindex_opt l '\t' with
      | Some i -> (
          match
            int_of_string_opt (String.sub l (i + 1) (String.length l - i - 1))
          with
          | Some n -> Some (String.sub l 0 i, n)
          | None -> None)
      | None -> None)

let told (log : Log.t) = config_list log k_told

let set_told (log : Log.t) l =
  Store.set_config log k_told (String.concat "\n" (Sources.dedupe l))

(* Records a check's result, keeping as told only the folders still refused. *)
let record (log : Log.t) ~now result =
  Log.transaction log (fun () ->
      Store.set_config log k_refused
        (String.concat "\n"
           (List.map (fun (d, n) -> Printf.sprintf "%s\t%d" d n) result));
      let still = List.map fst result in
      set_told log (List.filter (fun d -> List.mem d still) (told log));
      Store.set_config log k_checked_at (Printf.sprintf "%.0f" now))

(* Whether this process has checked yet: the first pass after the node starts always does. *)
let checked_since_start = ref false

let due (log : Log.t) ~now =
  (not !checked_since_start)
  ||
  match Option.bind (Store.config log k_checked_at) float_of_string_opt with
  | Some at ->
      let age =
        if refused_folders log <> [] then refused_max_age else max_age
      in
      now -. at >= age || now < at
  | None -> true

(* The pass's check: run when the node has just started or the last one is a day old. *)
let check_if_due ?probe ?home (log : Log.t) ~now =
  if due log ~now then begin
    checked_since_start := true;
    record log ~now (check ?probe ?home ~names:(session_project_names log) ())
  end

(* The notice's title, on this machine alone: the folder and what it holds. *)
let title (dir, n) =
  Printf.sprintf "Digestif cannot open %s, where %s" (Sources.tilde dir)
    (if n = 1 then "1 of your session projects is"
     else Printf.sprintf "%d of your session projects are" n)

(* The notices not raised yet, each with the folder it tells of. *)
let fresh (log : Log.t) =
  let t = told log in
  List.filter (fun (d, _) -> not (List.mem d t)) (refused_folders log)

let tell (log : Log.t) dir = set_told log (told log @ [ dir ])

(* Whether a notice that told of [dir] no longer holds: the last check could list it. *)
let resolved (log : Log.t) dir = not (List.mem_assoc dir (refused_folders log))
