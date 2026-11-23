(* Every circle's node on this machine lives under one parent, ~/digestif (docs/design.md, Circles):
   ~/digestif/<circle id> is that circle's data directory, or a link to a node set up elsewhere
   before the parent existed. A circle id is a short slug the member picks, by default the slug of
   the circle's name; the circle's identity on the wire stays its root hash, which nothing here
   changes. A link resolves to the target exactly as it was written, because the keystore scopes a
   node's keys by its data directory's path (Keystore.default ~scope). *)

let ( let* ) = Result.bind

(* The parent: $DIGESTIF_CIRCLES, else ~/digestif. *)
let parent () =
  match Sys.getenv_opt "DIGESTIF_CIRCLES" with
  | Some d when d <> "" -> d
  | _ ->
      Filename.concat
        (Option.value (Sys.getenv_opt "HOME") ~default:".")
        "digestif"

let max_id_length = 32

(* A circle id: lower-case letters, digits and single hyphens, starting and ending with a letter or
   digit, at most 32 characters, so it is safe in a path, a launchd label and a systemd unit name. *)
let is_id s =
  let n = String.length s in
  let alnum c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') in
  n > 0 && n <= max_id_length
  && alnum s.[0]
  && alnum s.[n - 1]
  && String.for_all (fun c -> alnum c || c = '-') s
  && not
       (let rec dd i =
          i + 1 < n && ((s.[i] = '-' && s.[i + 1] = '-') || dd (i + 1))
        in
        dd 0)

(* The id a circle's name suggests: lower-cased, every run of other characters one hyphen, cut to
   the length an id allows. "" when the name has no letter or digit. *)
let id_of_name name =
  let b = Buffer.create (String.length name) in
  let pending = ref false in
  String.iter
    (fun c ->
      let c = Char.lowercase_ascii c in
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then begin
        if !pending && Buffer.length b > 0 then Buffer.add_char b '-';
        pending := false;
        Buffer.add_char b c
      end
      else pending := true)
    name;
  let s = Buffer.contents b in
  let s =
    if String.length s <= max_id_length then s else String.sub s 0 max_id_length
  in
  (* A cut can end on a hyphen. *)
  let rec trim s =
    let n = String.length s in
    if n > 0 && s.[n - 1] = '-' then trim (String.sub s 0 (n - 1)) else s
  in
  trim s

let refuse_id id =
  Error
    (Printf.sprintf
       "%S is not a circle id: use lower-case letters, digits and single \
        hyphens, at most %d characters (digestif circle list names each)"
       id max_id_length)

let lstat_kind path =
  match Unix.lstat path with
  | { st_kind; _ } -> Some st_kind
  | exception Unix.Unix_error _ -> None

(* Whether [path], an entry of the parent named [name], belongs there: a link (to a node, which
   Circles.link checks), a directory named by an id that holds a node or nothing yet (a set-up that
   stopped before its log), or Finder's .DS_Store. *)
let belongs ~name path =
  name = ".DS_Store"
  ||
  match lstat_kind path with
  | Some Unix.S_LNK -> true
  | Some Unix.S_DIR ->
      is_id name
      && (Sys.file_exists (Node.log_path path)
         ||
         match Sys.readdir path with
         | [||] -> true
         | _ -> false
         | exception Sys_error _ -> false)
  | _ -> false

(* The parent, refused when it holds anything other than circle nodes and links: a git checkout of
   the digestif repo at ~/digestif is the case this guards, where a node set up there would put
   keys-scoped state inside a working tree and an id like node or ui would name one of its
   folders. A parent that does not exist yet is fine; the first node creates it. *)
let check_parent () =
  let p = parent () in
  match Sys.readdir p with
  | exception Sys_error _ ->
      if Sys.file_exists p then Error (p ^ " is not a directory") else Ok p
  | names -> (
      let foreign =
        Array.to_list names |> List.sort compare
        |> List.filter (fun name ->
            not (belongs ~name (Filename.concat p name)))
      in
      match foreign with
      | [] -> Ok p
      | _ ->
          let shown = List.filteri (fun i _ -> i < 3) foreign in
          let more = List.length foreign - List.length shown in
          Error
            (Printf.sprintf
               "%s holds %s%s, which is neither a circle's node nor a link to \
                one: the parent of circle nodes holds nothing else, so a git \
                checkout or another folder there is never taken for a circle. \
                Set DIGESTIF_CIRCLES to a directory of its own, such as \
                ~/digestif-circles, or move %s elsewhere"
               p (String.concat ", " shown)
               (if more > 0 then Printf.sprintf " and %d more" more else "")
               (if List.length foreign = 1 then "it" else "them")))

(* The data directory a link names, exactly as written; a relative target is read from the parent. *)
let link_target path =
  let t = Unix.readlink path in
  if Filename.is_relative t then Filename.concat (Filename.dirname path) t
  else t

(* The data directory of circle [id] under the parent. With [~create], an id that names nothing yet
   is the directory a new node is set up in (digestif --circle <id> init or join); without it, it is
   refused, so a mistyped id never sets up an empty node. *)
let dir ?(create = false) id =
  if not (is_id id) then refuse_id id
  else
    let* _ = check_parent () in
    let path = Filename.concat (parent ()) id in
    match lstat_kind path with
    | Some Unix.S_LNK -> Ok (link_target path)
    | Some Unix.S_DIR -> Ok path
    | Some _ -> Error (path ^ " is not a directory")
    | None when create -> Ok path
    | None ->
        Error
          (Printf.sprintf
             "no circle %S on this machine (%s does not exist); digestif \
              circle list names each, and digestif --circle %s init sets up a \
              new one"
             id path id)

type entry = { id : string; dir : string; linked : bool }

(* Every circle under the parent, by id: each directory holding a node, and each link with its
   target. Anything else (a name that is not an id, a directory with no node) is not a circle and is
   left out, so a parent check_parent refuses still lists only nodes. *)
let entries () =
  let p = parent () in
  match Sys.readdir p with
  | exception Sys_error _ -> []
  | names ->
      Array.to_list names |> List.sort compare
      |> List.filter_map (fun id ->
          if not (is_id id) then None
          else
            let path = Filename.concat p id in
            match lstat_kind path with
            | Some Unix.S_LNK -> (
                match link_target path with
                | d -> Some { id; dir = d; linked = true }
                | exception Unix.Unix_error _ -> None)
            | Some Unix.S_DIR when Sys.file_exists (Node.log_path path) ->
                Some { id; dir = path; linked = false }
            | _ -> None)

(* What a data directory holds, read from its log alone (no keystore is opened): its root, the
   circle's name as the root names it, its web UI's address and its last sync. None when no node was
   set up there. *)
type summary = {
  root : string option;
  name : string;
  ui_url : string option;  (** the address its web UI last bound *)
  last_sync : string option;  (** its newest sync of any relay *)
}

let summary dir =
  let path = Node.log_path dir in
  if not (Sys.file_exists path) then None
  else
    let log = Log.open_ path in
    Fun.protect
      ~finally:(fun () -> Log.close log)
      (fun () ->
        let root = Log.get_config log Node.k_root in
        let name =
          match Option.bind root (Log.find log) with
          | Some { signed = { envelope; body = Some b }; _ } -> (
              match Bodies.parse_listing ~kind:envelope.kind b with
              | Ok d -> d.label
              | Error _ -> "")
          | _ -> ""
        in
        let ui_url = Log.get_config log "ui_url" in
        let last_sync =
          List.fold_left
            (fun acc (r : Log.relay_row) ->
              match (acc, r.last_sync_at) with
              | Some a, Some b when a >= b -> acc
              | _, Some b -> Some b
              | _, None -> acc)
            None (Log.relays log)
        in
        Some { root; name; ui_url; last_sync })

(* Make ~/digestif/<id> a link to the node at [target], which stays where it is: its keys, its
   service and its join link all name that path. Linking the same target again is a no-op. *)
let link ~id ~target =
  let* () = if is_id id then Ok () else refuse_id id in
  let target =
    if Filename.is_relative target then Filename.concat (Sys.getcwd ()) target
    else target
  in
  let* () =
    if Sys.file_exists (Node.log_path target) then Ok ()
    else Error ("no node is set up in " ^ target)
  in
  let* p = check_parent () in
  let path = Filename.concat p id in
  match lstat_kind path with
  | Some Unix.S_LNK when link_target path = target -> Ok path
  | Some _ ->
      Error
        (Printf.sprintf "%s already names a circle (digestif circle list)" path)
  | None ->
      Node.mkdir_p p;
      Unix.symlink target path;
      Ok path

(* The id a data directory is known by under the parent: the directory <parent>/<id> itself, or the
   target of the link <parent>/<id>. None for a node no entry names. *)
let id_of_dir dir =
  List.find_map (fun e -> if e.dir = dir then Some e.id else None) (entries ())
