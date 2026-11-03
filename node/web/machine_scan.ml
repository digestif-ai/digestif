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

(* One discovery, folded into both lists. *)
let scan ?(discover = Sources.discover_repos) ~now (log : Log.t) =
  if not (fixed log) then begin
    let repos = discover () in
    Store.set_offered log (Sources.offered repos);
    Store.Repositories.apply_scan log ~at:(Time_fmt.of_unix now)
      (Repo_scan.scan repos);
    Log.set_config log k_scanned_at (Printf.sprintf "%.3f" now)
  end

(* Older than [age], or taken at a time the clock has since gone back past. *)
let older_than ~age ~now (log : Log.t) =
  match scanned_at log with
  | None -> true
  | Some t -> now -. t >= age || now < t

let stale ~now (log : Log.t) = older_than ~age:max_age ~now log

(* At most one background rescan at a time in this process. *)
let rescanning = Atomic.make false

(* [f] on a thread of its own, against a connection of its own to the node's log, so the read that
   started it answers at once. Nothing when a rescan is already running; the thread otherwise. *)
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
