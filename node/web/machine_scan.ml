(* What this machine offers, read once and kept in the store: the sources a member may choose
   (Sources.offered) and the clones the Repositories page lists (Repo_scan). Discovery walks every
   clone and every Claude Code project directory, which on a machine with hundreds of work trees
   takes tens of seconds, so no page waits on it once a scan is stored. A page's read scans only
   when the node has never scanned; `digestif run` rescans on its pass once the stored scan is
   older than [max_age], so a clone made since shows up within that. One discovery feeds both
   lists. A node whose sources were set by hand (the demo circle) is never scanned. *)

open Digestif_core

let k_scanned_at = "ui_machine_scanned_at"

(* How old a stored scan may grow before the pass takes another. *)
let max_age = 900.
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

(* A page's read: what the store holds, scanning first only when the node never has. *)
let ensure ?discover ~now (log : Log.t) =
  if scanned_at log = None then scan ?discover ~now log

let stale ~now (log : Log.t) =
  match scanned_at log with
  | None -> true
  | Some t -> now -. t >= max_age || now < t

(* The pass's rescan: whether it scanned. *)
let refresh_if_stale ?discover ~now (log : Log.t) =
  if (not (fixed log)) && stale ~now log then begin
    scan ?discover ~now log;
    true
  end
  else false
