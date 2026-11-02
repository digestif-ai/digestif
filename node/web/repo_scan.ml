(* What the member's clones say about repositories and commit authors (DES-37265, Repositories):
   each clone's remote, read from its own .git/config, names the repository and the organization
   it is grouped under; the clones' configured users and their frequent committers are the commit
   authors setup proposes. Nothing here decides anything: Store.Repositories folds a scan in and
   keeps every choice the member made. *)

open Digestif_core

(* A git config file's (section, key, value) triples, section as written between the brackets
   with any quoted subsection kept: remote "origin" reads as {|remote "origin"|}. Keys are
   lowercased, as git treats them. *)
let config_entries text =
  let section = ref "" in
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
      let l = String.trim line in
      let n = String.length l in
      if n = 0 || l.[0] = '#' || l.[0] = ';' then None
      else if l.[0] = '[' then begin
        (match String.index_opt l ']' with
        | Some i -> section := String.trim (String.sub l 1 (i - 1))
        | None -> ());
        None
      end
      else
        match String.index_opt l '=' with
        | Some i ->
            let key = String.lowercase_ascii (String.trim (String.sub l 0 i)) in
            let v = String.trim (String.sub l (i + 1) (n - i - 1)) in
            let v =
              let m = String.length v in
              if m >= 2 && v.[0] = '"' && v.[m - 1] = '"' then
                String.sub v 1 (m - 2)
              else v
            in
            Some (!section, key, v)
        | None -> None)

let read_file p =
  match In_channel.with_open_bin p In_channel.input_all with
  | s -> Some s
  | exception Sys_error _ -> None

let repo_config repo =
  Option.fold ~none:[] ~some:config_entries
    (read_file (Filename.concat repo ".git/config"))

(* The url of the clone's origin, else of the first remote its config names. *)
let remote_url entries =
  let remotes =
    List.filter_map
      (fun (s, k, v) ->
        if
          k = "url" && String.length s > 7
          && String.sub s 0 7 = "remote "
        then Some (s, v)
        else None)
      entries
  in
  match List.assoc_opt {|remote "origin"|} remotes with
  | Some u -> Some u
  | None -> Option.map snd (List.nth_opt remotes 0)

let strip_suffix suffix s =
  if Filename.check_suffix s suffix then Filename.chop_suffix s suffix else s

(* A remote url's host and path segments: https://host/a/b.git, ssh://user@host:22/a/b,
   user@host:a/b.git (scp-like) and a local path all come apart the same way. The host is
   lowercased and loses its port; a local path has no host. *)
let parse_remote url =
  let url = String.trim url in
  let host_and_path =
    match Re.exec_opt (Re.Perl.compile_pat {|^[a-zA-Z][a-zA-Z0-9+.-]*://|}) url with
    | Some g ->
        let rest =
          String.sub url (Re.Group.stop g 0)
            (String.length url - Re.Group.stop g 0)
        in
        let auth, path =
          match String.index_opt rest '/' with
          | Some i ->
              (String.sub rest 0 i, String.sub rest i (String.length rest - i))
          | None -> (rest, "")
        in
        let host =
          match String.rindex_opt auth '@' with
          | Some i -> String.sub auth (i + 1) (String.length auth - i - 1)
          | None -> auth
        in
        let host =
          match String.index_opt host ':' with
          | Some i -> String.sub host 0 i
          | None -> host
        in
        if String.sub url 0 (Re.Group.stop g 0) = "file://" then ("", path)
        else (host, path)
    | None -> (
        (* scp-like: a colon before any slash *)
        match (String.index_opt url ':', String.index_opt url '/') with
        | Some c, slash when slash = None || Option.get slash > c ->
            let auth = String.sub url 0 c in
            let host =
              match String.rindex_opt auth '@' with
              | Some i -> String.sub auth (i + 1) (String.length auth - i - 1)
              | None -> auth
            in
            (host, String.sub url (c + 1) (String.length url - c - 1))
        | _ -> ("", url))
  in
  let host, path = host_and_path in
  let segments =
    String.split_on_char '/' path
    |> List.filter (fun s -> s <> "" && s <> ".")
  in
  let segments =
    match List.rev segments with
    | last :: rest -> List.rev (strip_suffix ".git" last :: rest)
    | [] -> []
  in
  (String.lowercase_ascii host, segments)

(* One clone as Store.Repositories takes it. The repository is the remote, ids lowercased so two
   spellings of one remote are one repository; the organization is every segment but the last,
   shown without its host when that host is github.com. A clone with no remote, or one whose url
   names no repository, is its own repository and organization, named by its folder. *)
let found_of_clone repo : Store.Repositories.found =
  let path = Sources.tilde repo in
  let own () : Store.Repositories.found =
    let id = "local:" ^ path in
    {
      f_id = id;
      f_name = Filename.basename repo;
      f_org_id = id;
      f_org_name = Filename.basename repo;
      f_path = path;
    }
  in
  match remote_url (repo_config repo) with
  | None -> own ()
  | Some url -> (
      let host, segments = parse_remote url in
      match List.rev segments with
          | [] -> own ()
          | name :: owner_rev ->
              let owner = String.concat "/" (List.rev owner_rev) in
              let key parts =
                String.lowercase_ascii
                  (String.concat "/" (List.filter (fun s -> s <> "") parts))
              in
              let org_id = key [ host; owner ] in
              let org_id = if org_id = "" then "local:" ^ path else org_id in
              let org_name =
                match (host, owner) with
                | ("github.com" | ""), o when o <> "" -> o
                | h, "" -> h
                | h, o -> h ^ "/" ^ o
              in
              let org_name =
                if org_name = "" then Filename.basename repo else org_name
              in
              {
                f_id = key [ host; owner; name ];
                f_name = name;
                f_org_id = org_id;
                f_org_name = org_name;
                f_path = path;
              })

(* Every clone discovery finds (Sources.discover_repos), as the scan's input. *)
let scan () = List.map found_of_clone (Sources.discover_repos ())

(* commit authors *)

let user_of entries =
  let get k =
    List.find_map
      (fun (s, key, v) ->
        if String.lowercase_ascii s = "user" && key = k && v <> "" then Some v
        else None)
      entries
  in
  Option.map (fun e -> (e, get "name")) (get "email")

let global_user () =
  match Proc.run [| "git"; "config"; "--global"; "--get"; "user.email" |] with
  | Ok { code = 0; stdout; _ } when String.trim stdout <> "" ->
      let name =
        match Proc.run [| "git"; "config"; "--global"; "--get"; "user.name" |] with
        | Ok { code = 0; stdout; _ } when String.trim stdout <> "" ->
            Some (String.trim stdout)
        | _ -> None
      in
      Some (String.trim stdout, name)
  | _ -> None

(* How far back a committer is counted, and how many commits make one frequent. *)
let frequent_window_days = 90
let frequent_min_commits = 10
let frequent_max = 20

(* Each identity's commits on a clone's HEAD in the window, as (email, name) per commit. A clone
   whose HEAD has not moved in the window is not asked (Sources.head_moved_since). *)
let committers ~now repo =
  let since = now -. (float_of_int frequent_window_days *. Sources.day) in
  if not (Sources.head_moved_since ~since repo) then []
  else
    match
      Proc.run
        [|
          "git";
          "-C";
          repo;
          "log";
          "--no-merges";
          Printf.sprintf "--since=@%d" (int_of_float since);
          "--format=%ae%x09%an";
          "-n";
          "500";
          "HEAD";
        |]
    with
    | Ok { code = 0; stdout; _ } ->
        Sources.lines stdout
        |> List.filter_map (fun l ->
            match String.index_opt l '\t' with
            | Some i ->
                Some
                  ( String.sub l 0 i,
                    String.sub l (i + 1) (String.length l - i - 1) )
            | None -> None)
    | _ -> []

(* The authors setup proposes, as (email, name, label): every configured user of the clones and
   of the machine is Yours; every other identity with at least [frequent_min_commits] commits in
   the window across the clones is Your fleet, the most frequent [frequent_max] of them. The
   fleet's share may include a coworker's identity, which the member removes on the page. *)
let propose_authors ?(global = global_user ()) ~now repos =
  let norm = Store.Repositories.normalize_email in
  let yours =
    Option.to_list global
    @ List.filter_map (fun r -> user_of (repo_config r)) repos
  in
  let yours =
    List.fold_left
      (fun acc (e, n) ->
        if List.exists (fun (e', _) -> norm e' = norm e) acc then acc
        else acc @ [ (e, n) ])
      [] yours
  in
  let counts = Hashtbl.create 64 in
  List.iter
    (fun r ->
      List.iter
        (fun (e, n) ->
          let k = norm e in
          if k <> "" then
            let c, _ = Option.value (Hashtbl.find_opt counts k) ~default:(0, n) in
            Hashtbl.replace counts k (c + 1, n))
        (committers ~now r))
    repos;
  let fleet =
    Hashtbl.fold (fun e (c, n) acc -> (e, n, c) :: acc) counts []
    |> List.filter (fun (e, _, c) ->
        c >= frequent_min_commits
        && not (List.exists (fun (y, _) -> norm y = e) yours))
    |> List.sort (fun (e1, _, c1) (e2, _, c2) ->
        match compare c2 c1 with 0 -> compare e1 e2 | n -> n)
    |> List.filteri (fun i _ -> i < frequent_max)
  in
  List.map (fun (e, n) -> (e, n, "yours")) yours
  @ List.map (fun (e, n, _) -> (e, Some n, "your_fleet")) fleet
