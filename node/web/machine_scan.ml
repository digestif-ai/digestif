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

(* ISS-48149: what a scan's read of the member's own commits asked git (Repo_scan.own_commit_at):
   the clone HEADs it read, those already read on an earlier scan, and those it left for the next
   one because the budget ran out or git did not answer. *)
type own_stats = { heads_read : int; heads_kept : int; heads_left : int }

let no_own = { heads_read = 0; heads_kept = 0; heads_left = 0 }

(* What one scan did and how long each part took, in seconds of the wall clock, for the line the
   node logs: the index's discovery ([discovery], None when the caller handed one in), the
   discovery itself, and the read of the member's own commits. A part that took far longer than its
   work is a machine that slept through it. *)
type report = {
  discovery : stats option;
  discover_s : float;
  own : own_stats;
  own_s : float;
}

let summary r =
  let d =
    match r.discovery with
    | Some d ->
        Printf.sprintf
          "discovery %.1fs (clones %d read, %d kept; projects %d read, %d kept)"
          r.discover_s d.clones_read d.clones_kept d.projects_read
          d.projects_kept
    | None -> Printf.sprintf "discovery %.1fs" r.discover_s
  in
  Printf.sprintf "%s; own commits %.1fs (HEADs %d read, %d kept, %d left)" d
    r.own_s r.own.heads_read r.own.heads_kept r.own.heads_left

(* The paths each Claude Code project directory's name decodes to (Sources.decode_project_dir),
   from the index where its stamp has not moved. Only reads: what the index must learn is added to
   [writes], for the caller to apply under one short transaction. *)
let worked_in ?(root = "/") ~judging ~memo ~writes (log : Log.t) =
  let module I = Store.Scan_index in
  let stored = I.projects log in
  let cache = Hashtbl.create 64 in
  let read = ref 0 and kept = ref 0 in
  (* Names left undecoded once the reading's time ran out. *)
  let left = ref 0 in
  let skipped = Sources.skipped_by_name ~memo judging in
  let dirs = Sources.children (Sources.claude_projects ()) in
  let names = List.map Filename.basename dirs in
  let paths =
    List.concat_map
      (fun dir ->
        let name = Filename.basename dir in
        (* A project under a temp root is skipped by its name, never decoded; one whose decoding
           cannot be judged is read again by the next scan, so nothing is stored for it. *)
        if skipped name then []
        else
        let stamp = dir_stamp dir in
        match Hashtbl.find_opt stored name with
        | Some (s, paths) when s = stamp && List.for_all Sources.is_dir paths ->
            incr kept;
            paths
        | _ ->
            incr read;
            match Sources.decode_judged ~root ~cache ~memo ~judging name with
            | paths, partial ->
                (* A decoding given up in part is not stored, so the next scan makes it whole. *)
                if partial && Sources.reading_spent memo then incr left;
                if not partial then
                  writes := (fun () -> I.put_project log name ~stamp paths) :: !writes;
                paths
            | exception Sources.Cannot_judge _ ->
                if Sources.reading_spent memo then incr left;
                [])
      dirs
  in
  Hashtbl.iter
    (fun name _ ->
      if not (List.mem name names) then
        writes := (fun () -> I.remove_project log name) :: !writes)
    stored;
  if !left > 0 then judging.Sources.on_deadline !left;
  (paths, !read, !kept)

(* What a clone whose stamp moved is read as: whether it holds financial records, and its
   repository from its .git/config. A clone that cannot be judged raises [Sources.Cannot_judge].
   The reading's [judging] and [memo] are shared, so every clone is read within one deadline. *)
let read_clone ?judging ?memo ~stamp dir : Store.Scan_index.clone =
  {
    stamp;
    financial = Sources.holds_financial_records_exn ?judging ?memo dir;
    found = Repo_scan.found_of_clone dir;
  }

(* Every clone discovery finds, as the scan's input (Repo_scan.scan), from the index where a
   clone's stamp has not moved, and what the pass reread. Discovery reads the disk and runs git
   for every clone whose stamp moved, which on a first scan of a heavy machine is minutes; the
   store is not held for any of it. The index's writes are collected as the disk is read and
   applied in one transaction at the end, so the write lock is held for the writes alone and a
   request answering meanwhile waits milliseconds for it, never the scan (ISS-48148). A second
   process scanning at once writes the same rows by the same keys, so the later transaction wins
   with an answer as current as the earlier one's. *)
let discover_indexed ?root ?read_clone:injected ?judging (log : Log.t) =
  let module I = Store.Scan_index in
  let exception Cannot_judge_clone in
  let judging =
    Sources.begun (Option.value judging ~default:(Sources.default_judging ()))
  in
  let memo = Hashtbl.create 8 in
  let read_clone =
    match injected with Some f -> f | None -> read_clone ~judging ~memo
  in
  (* Clones left unread once the reading's time ran out. *)
  let left = ref 0 in
  let writes = ref [] in
  let write f = writes := f :: !writes in
  let projects, projects_read, projects_kept =
    worked_in ?root ~judging ~memo ~writes log
  in
  let stored = I.clones log in
  let candidates = Sources.dedupe (Sources.code_dirs () @ projects) in
  let read = ref 0 and kept = ref 0 in
  let found =
    List.filter_map
      (fun dir ->
        try
        let c =
          match clone_stamp dir with
          | None -> None
          | Some stamp -> (
              match Hashtbl.find_opt stored dir with
              | Some (c : I.clone) when c.stamp = stamp ->
                  incr kept;
                  Some c
              | _ ->
                  incr read;
                  (* A clone that cannot be judged is not offered and nothing is stored for it, so
                     the next scan reads it again. *)
                  let c =
                    try read_clone ~stamp dir
                    with Sources.Cannot_judge _ ->
                      if Sources.reading_spent memo then incr left;
                      raise Cannot_judge_clone
                  in
                  write (fun () -> I.put_clone log dir c);
                  Some c)
        in
        match c with
        | None ->
            if Hashtbl.mem stored dir then
              write (fun () -> I.remove_clone log dir);
            None
        | Some c when c.financial -> None
        | Some c -> Some (dir, { c.found with f_path = Sources.tilde dir })
        with Cannot_judge_clone -> None)
      candidates
  in
  if !left > 0 then judging.Sources.on_deadline !left;
  let seen = Hashtbl.create 256 in
  List.iter (fun d -> Hashtbl.replace seen d ()) candidates;
  Hashtbl.iter
    (fun path _ ->
      if not (Hashtbl.mem seen path) then
        write (fun () -> I.remove_clone log path))
    stored;
  if !writes <> [] then
    Log.transaction log (fun () -> List.iter (fun f -> f ()) (List.rev !writes));
  ( List.map fst found,
    List.map snd found,
    { clones_read = !read; clones_kept = !kept; projects_read; projects_kept }
  )

(* ISS-42314: the commit authors whose commits are the member's own: the list the member owns once
   it was proposed, else the machine's configured git user. *)
let own_emails ?(global = Repo_scan.global_user) (log : Log.t) =
  let module R = Store.Repositories in
  if R.authors_proposed log then
    List.map (fun (a : R.author) -> a.email) (R.authors log)
  else Option.to_list (Option.map fst (global ()))

(* [f] over [l] on up to [workers] threads, in [l]'s order. Each call of [f] here waits on a git
   process, and a thread waiting on one lets the others run, so a first scan of a thousand clones
   waits on [workers] processes at a time instead of one (ISS-43534). No call starts once [until]
   has passed: an item never started is None (ISS-48149). An exception in [f] is raised once every
   thread has finished. *)
let workers = 8

let concurrently ?until f l =
  let a = Array.of_list l in
  let out = Array.make (Array.length a) None in
  let next = Atomic.make 0 in
  let open_ () =
    match until with None -> true | Some u -> Unix.gettimeofday () < u
  in
  let rec work () =
    if open_ () then begin
      let i = Atomic.fetch_and_add next 1 in
      if i < Array.length a then begin
        out.(i) <- Some (try Ok (f a.(i)) with e -> Error e);
        work ()
      end
    end
  in
  List.init (min workers (Array.length a)) (fun _ -> Thread.create work ())
  |> List.iter Thread.join;
  Array.to_list out
  |> List.map (function
    | Some (Ok x) -> Some x
    | Some (Error e) -> raise e
    | None -> None)

(* ISS-48149: how long one scan may spend asking git for the member's own commits. A history with
   no commit of theirs is read to its root, so a machine holding a large repository's clones asked
   once per clone took over an hour, and the work run waits on its scan before the note starts.
   What the budget leaves is read on the next scan, which starts where this one stopped, since each
   HEAD's answer is kept. *)
let own_commit_budget = 120.

(* ISS-42314: each undecided repository's last own commit, read from its clones' logs: those this
   scan found ([at]), and on a work run every one still undecided, so the line a row shows is at
   most a day old. Only undecided repositories are asked, since only their rows show it. The
   writes are one transaction, after every log is read, so the store is not held while git runs.
   ISS-48149: a repository's answer is the newest over its clones' HEADs, and a HEAD's answer never
   changes, so it is read once per HEAD and list of authors (Store.Scan_index.own_commits), the
   clones on one HEAD are asked once between them, and the reading stops at [budget] seconds. A
   repository with a HEAD not read yet keeps the answer it had; a repository this scan found is
   asked first. *)
let read_own_commits ?global ?(budget = own_commit_budget) ~work_run ~at
    (log : Log.t) =
  let module R = Store.Repositories in
  let module I = Store.Scan_index in
  let undecided =
    R.repositories ~status:"undecided" ~limit:max_int ~offset:0 log
    |> List.filter (fun (r : R.repository) -> work_run || r.found_at = at)
  in
  let undecided =
    let fresh, rest =
      List.partition (fun (r : R.repository) -> r.found_at = at) undecided
    in
    fresh @ rest
  in
  if undecided = [] then no_own
  else begin
    let until = Unix.gettimeofday () +. budget in
    let emails = own_emails ?global log in
    let authors = Repo_scan.authors_key emails in
    let heads =
      concurrently
        (fun (r : R.repository) ->
          List.filter_map
            (fun p ->
              let p = Sources.untilde p in
              Option.map (fun h -> (h, p)) (Repo_scan.head p))
            r.r_paths)
        undecided
      |> List.map (Option.value ~default:[])
    in
    let known = I.own_commits log ~authors in
    let kept = Hashtbl.create 64 in
    let asks =
      let seen = Hashtbl.create 64 in
      List.concat_map
        (List.filter_map (fun (h, p) ->
             if Hashtbl.mem known h then begin
               Hashtbl.replace kept h ();
               None
             end
             else if Hashtbl.mem seen h then None
             else begin
               Hashtbl.replace seen h ();
               Some (h, p)
             end))
        heads
    in
    let answers =
      concurrently ~until
        (fun (_, p) ->
          let timeout = Float.max 1. (until -. Unix.gettimeofday ()) in
          Repo_scan.own_commit_at ~timeout ~emails p)
        asks
    in
    let read = ref 0 and left = ref 0 in
    Log.transaction log (fun () ->
        List.iter2
          (fun (h, _) answer ->
            match answer with
            | Some (Ok at) ->
                incr read;
                Hashtbl.replace known h at;
                I.put_own_commit log ~authors h at
            | Some (Error _) | None -> incr left)
          asks answers;
        List.iter2
          (fun (r : R.repository) heads ->
            let ats = List.map (fun (h, _) -> Hashtbl.find_opt known h) heads in
            if List.for_all Option.is_some ats then
              R.set_last_own_commit log r.r_id
                (Option.map Time_fmt.of_unix
                   (Repo_scan.newest (List.filter_map Fun.id ats))))
          undecided heads;
        if work_run && !left = 0 then
          I.keep_own_commits log ~authors (List.concat_map (List.map fst) heads));
    { heads_read = !read; heads_kept = Hashtbl.length kept; heads_left = !left }
  end

(* One discovery, folded into both lists: the stored index's ([discover_indexed]), or, when the
   caller hands one in, [discover]'s clones read whole. What it did and how long each part took.
   [work_run] is the scan a work run starts with, which also rereads every undecided repository's
   last own commit. *)
let scan_report ?root ?discover ?global ?own_budget ?(work_run = false) ~now
    (log : Log.t) =
  if fixed log then None
  else begin
    let t0 = Unix.gettimeofday () in
    let repos, found, stats =
      match discover with
      | Some d ->
          let repos = d () in
          (repos, Repo_scan.scan repos, None)
      | None ->
          let repos, found, stats = discover_indexed ?root log in
          (repos, found, Some stats)
    in
    Store.set_offered log (Sources.offered repos);
    let at = Time_fmt.of_unix now in
    Store.Repositories.apply_scan log ~at found;
    let t1 = Unix.gettimeofday () in
    let own = read_own_commits ?global ?budget:own_budget ~work_run ~at log in
    let t2 = Unix.gettimeofday () in
    Log.set_config log k_scanned_at (Printf.sprintf "%.3f" now);
    Some { discovery = stats; discover_s = t1 -. t0; own; own_s = t2 -. t1 }
  end

let scan_stats ?root ?discover ?global ?(work_run = false) ~now (log : Log.t) =
  Option.bind (scan_report ?root ?discover ?global ~work_run ~now log) (fun r ->
      r.discovery)

let scan ?root ?discover ~now (log : Log.t) =
  ignore (scan_stats ?root ?discover ~now log)

(* ISS-42314 (DES-37153, The new-repositories ask): the scan every work run starts with, before
   the record is read, whatever the stored scan's age, so a repository cloned since the last pass
   is stored by its organization's choice before the note's sources are handed over. A work run
   runs while Onboarding and Active and never while Paused, so neither does this scan. *)
let work_run_scan ?discover ?global ?own_budget ~now (log : Log.t) =
  scan_report ?discover ?global ?own_budget ~work_run:true ~now log

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

(* The pass's rescan: what it did, when it scanned. *)
let refresh_report_if_stale ?discover ~now (log : Log.t) =
  if (not (fixed log)) && stale ~now log then scan_report ?discover ~now log
  else None

(* The pass's rescan: whether it scanned. *)
let refresh_if_stale ?discover ~now (log : Log.t) =
  Option.is_some (refresh_report_if_stale ?discover ~now log)

(* The scan's commit authors enter the member's list once, the first time it is read (the
   Repositories page or the setup chat); a node whose sources were set by hand proposes none. *)
let propose_authors ~now (log : Log.t) =
  let module R = Store.Repositories in
  if (not (fixed log)) && not (R.authors_proposed log) then
    R.propose_authors log
      (Repo_scan.propose_authors ~now
         (List.map Sources.untilde (R.clone_paths log)))
