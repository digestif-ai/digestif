(* What this machine offers, read once and kept in the store: the sources a member may choose
   (Sources.offered) and the clones the Repositories page lists (Repo_scan). Discovery walks every
   clone and every Claude Code project directory, which on a machine with hundreds of work trees
   takes tens of seconds, so no page waits on it once a scan is stored. A page's read scans in the
   foreground only when the node has never scanned. `digestif run` rescans on its pass once the
   stored scan is older than [max_age]; a page's read rescans in the background once it is older
   than [read_max_age], answering from the stored scan meanwhile, which is the only rescan a node
   running `digestif ui` alone gets. One discovery feeds both lists. A node whose sources were set
   by hand (the demo circle) is never scanned. *)

open Digestif_core

let k_scanned_at = "ui_machine_scanned_at"

(* How old a stored scan may grow before the pass takes another. *)
let max_age = 900.

(* How old a stored scan may grow before a page's read takes another, in the background. *)
let read_max_age = 86400.
let fixed (log : Log.t) = Log.get_config log Sources.k_fixed <> None

(* When the stored scan was taken, in seconds since the epoch. *)
let scanned_at (log : Log.t) =
  Option.bind (Log.get_config log k_scanned_at) float_of_string_opt

(* ISS-41944: the scan is incremental. Store.Scan_index keeps what the last scan read of each
   clone and each Claude Code project directory, under a stamp of what that read depended on, and
   a rescan rereads only a stamp that moved, so the pass costs what changed since the last one, not
   the whole machine. Discovery's answer is the same as reading everything again
   (Sources.discover_repos): a clone is a directory with a .git directory, its repository is read
   from its .git/config (Repo_scan.found_of_clone), and one that holds financial records at its top
   level or one level down (Sources.holds_financial_records) is never offered. So a clone's stamp is
   the size and modification time of its .git/config, the modification time of the clone itself
   (which moves when a file is added, removed or renamed at its top level), and that of each of
   its top-level folders (which moves when one of theirs is): reading those is a listing of the
   clone and a stat per entry, where reading the clone is a listing of every folder in it and its
   config. A project directory's stamp is its modification time, which moves when a session is
   written there; its decoded paths are reread when it moves or when one of them is gone. A path
   that has since come to match a project's name beside one that still does is found on the next
   session written there. *)

let stat_opt p = try Some (Unix.stat p) with Unix.Unix_error _ -> None

(* None when [dir] is not a clone. *)
let clone_stamp dir =
  if not (Sources.is_repo dir) then None
  else begin
    let b = Buffer.create 256 in
    let file p =
      match stat_opt p with
      | Some st -> Printf.bprintf b "%d@%.6f;" st.st_size st.st_mtime
      | None -> Buffer.add_string b "-;"
    in
    file (Filename.concat dir ".git/config");
    file dir;
    List.iter
      (fun d ->
        match stat_opt d with
        | Some { st_kind = Unix.S_DIR; st_mtime; _ } ->
            Printf.bprintf b "%s@%.6f;" (Filename.basename d) st_mtime
        | _ -> ())
      (Sources.children dir);
    Some (Buffer.contents b)
  end

let dir_stamp dir =
  match stat_opt dir with
  | Some st -> Printf.sprintf "%.6f" st.st_mtime
  | None -> "-"

(* What one pass reread, for its tests: the clones and project directories whose stamp had moved
   (or that were new), and those kept as the last pass read them. *)
type stats = {
  clones_read : int;
  clones_kept : int;
  projects_read : int;
  projects_kept : int;
}

(* The paths each Claude Code project directory's name decodes to (Sources.decode_project_dir),
   from the index where its stamp has not moved. *)
let worked_in (log : Log.t) =
  let module I = Store.Scan_index in
  let stored = I.projects log in
  let cache = Hashtbl.create 64 in
  let read = ref 0 and kept = ref 0 in
  let dirs = Sources.children (Sources.claude_projects ()) in
  let names = List.map Filename.basename dirs in
  let paths =
    List.concat_map
      (fun dir ->
        let name = Filename.basename dir in
        let stamp = dir_stamp dir in
        match Hashtbl.find_opt stored name with
        | Some (s, paths) when s = stamp && List.for_all Sources.is_dir paths ->
            incr kept;
            paths
        | _ ->
            incr read;
            let paths = Sources.decode_project_dir ~cache name in
            I.put_project log name ~stamp paths;
            paths)
      dirs
  in
  Hashtbl.iter
    (fun name _ -> if not (List.mem name names) then I.remove_project log name)
    stored;
  (paths, !read, !kept)

(* Every clone discovery finds, as the scan's input (Repo_scan.scan), from the index where a
   clone's stamp has not moved, and what the pass reread. *)
let discover_indexed (log : Log.t) =
  let module I = Store.Scan_index in
  Log.transaction log (fun () ->
      let projects, projects_read, projects_kept = worked_in log in
      let stored = I.clones log in
      let candidates = Sources.dedupe (Sources.code_dirs () @ projects) in
      let read = ref 0 and kept = ref 0 in
      let found =
        List.filter_map
          (fun dir ->
            match clone_stamp dir with
            | None ->
                if Hashtbl.mem stored dir then I.remove_clone log dir;
                None
            | Some stamp ->
                let c =
                  match Hashtbl.find_opt stored dir with
                  | Some (c : I.clone) when c.stamp = stamp ->
                      incr kept;
                      c
                  | _ ->
                      incr read;
                      let c : I.clone =
                        {
                          stamp;
                          financial = Sources.holds_financial_records dir;
                          found = Repo_scan.found_of_clone dir;
                        }
                      in
                      I.put_clone log dir c;
                      c
                in
                if c.financial then None
                else Some (dir, { c.found with f_path = Sources.tilde dir }))
          candidates
      in
      let seen = Hashtbl.create 256 in
      List.iter (fun d -> Hashtbl.replace seen d ()) candidates;
      Hashtbl.iter
        (fun path _ ->
          if not (Hashtbl.mem seen path) then I.remove_clone log path)
        stored;
      ( List.map fst found,
        List.map snd found,
        {
          clones_read = !read;
          clones_kept = !kept;
          projects_read;
          projects_kept;
        } ))

(* ISS-42314: the commit authors whose commits are the member's own: the list the member owns once
   it was proposed, else the machine's configured git user. *)
let own_emails ?(global = Repo_scan.global_user) (log : Log.t) =
  let module R = Store.Repositories in
  if R.authors_proposed log then
    List.map (fun (a : R.author) -> a.email) (R.authors log)
  else Option.to_list (Option.map fst (global ()))

(* [f] over [l] on up to [workers] threads, in [l]'s order. Each call of [f] here waits on a git
   process, and a thread waiting on one lets the others run, so a first scan of a thousand clones
   waits on [workers] processes at a time instead of one (ISS-43534). An exception in [f] is raised
   once every thread has finished. *)
let workers = 8

let concurrently f l =
  let a = Array.of_list l in
  let out = Array.make (Array.length a) None in
  let next = Atomic.make 0 in
  let rec work () =
    let i = Atomic.fetch_and_add next 1 in
    if i < Array.length a then begin
      out.(i) <- Some (try Ok (f a.(i)) with e -> Error e);
      work ()
    end
  in
  List.init (min workers (Array.length a)) (fun _ -> Thread.create work ())
  |> List.iter Thread.join;
  Array.to_list out
  |> List.map (function
    | Some (Ok x) -> x
    | Some (Error e) -> raise e
    | None -> assert false)

(* ISS-42314: each undecided repository's last own commit, read from its clones' logs: those this
   scan found ([at]), and on a work run every one still undecided, so the line a row shows is at
   most a day old. Only undecided repositories are asked, since only their rows show it. The
   writes are one transaction, after every log is read, so the store is not held while git runs. *)
let read_own_commits ?global ~work_run ~at (log : Log.t) =
  let module R = Store.Repositories in
  let undecided =
    R.repositories ~status:"undecided" ~limit:max_int ~offset:0 log
    |> List.filter (fun (r : R.repository) -> work_run || r.found_at = at)
  in
  if undecided <> [] then begin
    let emails = own_emails ?global log in
    let newest =
      concurrently
        (fun (r : R.repository) ->
          Repo_scan.last_own_commit ~emails (List.map Sources.untilde r.r_paths))
        undecided
    in
    Log.transaction log (fun () ->
        List.iter2
          (fun (r : R.repository) at ->
            R.set_last_own_commit log r.r_id (Option.map Time_fmt.of_unix at))
          undecided newest)
  end

(* One discovery, folded into both lists: the stored index's ([discover_indexed]), or, when the
   caller hands one in, [discover]'s clones read whole. What it reread, when the index answered.
   [work_run] is the scan a work run starts with, which also rereads every undecided repository's
   last own commit. *)
let scan_stats ?discover ?global ?(work_run = false) ~now (log : Log.t) =
  if fixed log then None
  else begin
    let repos, found, stats =
      match discover with
      | Some d ->
          let repos = d () in
          (repos, Repo_scan.scan repos, None)
      | None ->
          let repos, found, stats = discover_indexed log in
          (repos, found, Some stats)
    in
    Store.set_offered log (Sources.offered repos);
    let at = Time_fmt.of_unix now in
    Store.Repositories.apply_scan log ~at found;
    read_own_commits ?global ~work_run ~at log;
    Log.set_config log k_scanned_at (Printf.sprintf "%.3f" now);
    stats
  end

let scan ?discover ~now (log : Log.t) = ignore (scan_stats ?discover ~now log)

(* ISS-42314 (DES-37153, The new-repositories ask): the scan every work run starts with, before
   the record is read, whatever the stored scan's age, so a repository cloned since the last pass
   is stored by its organization's choice before the note's sources are handed over. A work run
   runs while Onboarding and Active and never while Paused, so neither does this scan. *)
let work_run_scan ?discover ?global ~now (log : Log.t) =
  ignore (scan_stats ?discover ?global ~work_run:true ~now log)

(* Older than [age], or taken at a time the clock has since gone back past. *)
let older_than ~age ~now (log : Log.t) =
  match scanned_at log with
  | None -> true
  | Some t -> now -. t >= age || now < t

let stale ~now (log : Log.t) = older_than ~age:max_age ~now log

(* At most one background rescan at a time in this process. *)
let rescanning = Atomic.make false

(* A stale scan is retaken behind the page that found it: the page answers from the store at once
   and the next read sees the new scan. This is a refresh nobody waits on, not a way round a server
   that answers one request at a time (each request has a thread of its own, Http.run). [f] runs on
   a thread and a connection to the log of its own; nothing when a rescan is already running, the
   thread otherwise. *)
let in_background ?(running = rescanning) ~(dir : string) (f : Log.t -> unit) =
  if Atomic.compare_and_set running false true then
    Some
      (Thread.create
         (fun () ->
           Fun.protect
             ~finally:(fun () -> Atomic.set running false)
             (fun () ->
               try
                 let log = Log.open_ (Node.log_path dir) in
                 Fun.protect
                   ~finally:(fun () -> Log.close log)
                   (fun () -> f log)
               with e ->
                 Printf.eprintf "%s scan: sources and repositories: %s\n%!"
                   (Time_fmt.now ()) (Printexc.to_string e)))
         ())
  else None

(* A page's read: what the store holds. It scans first when the node never has, and retakes a scan
   older than [read_max_age] in the background ([spawn]). *)
let ensure ?discover ?spawn ~now (node : Node.t) =
  let spawn =
    match spawn with
    | Some s -> s
    | None -> fun f -> ignore (in_background ~dir:node.dir f)
  in
  if scanned_at node.log = None then scan ?discover ~now node.log
  else if (not (fixed node.log)) && older_than ~age:read_max_age ~now node.log
  then spawn (fun log -> scan ?discover ~now log)

(* The pass's rescan: whether it scanned. *)
let refresh_if_stale ?discover ~now (log : Log.t) =
  if (not (fixed log)) && stale ~now log then begin
    scan ?discover ~now log;
    true
  end
  else false

(* The scan's commit authors enter the member's list once, the first time it is read (the
   Repositories page or the setup chat); a node whose sources were set by hand proposes none. *)
let propose_authors ~now (log : Log.t) =
  let module R = Store.Repositories in
  if (not (fixed log)) && not (R.authors_proposed log) then
    R.propose_authors log
      (Repo_scan.propose_authors ~now
         (List.map Sources.untilde (R.clone_paths log)))
