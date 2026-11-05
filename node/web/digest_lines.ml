(* ISS-42319 (DES-37153, What the digest says without an ask): the lines a digest carries that leave
   the member nothing to decide, each carried once, on the day it happens, under the rule that a
   line off the machine says only what the circle could already know. They are the digest's
   "On your machine" section:

   - New repositories: a scan added repositories to the New repositories local ask. Only the count
     of the ones not told before, never a name.
   - The first note: an Onboarding member's first note waits for them.
   - A run that failed: a problem opened on a job that writes, checks or sends a note. The kind of
     failure stays on the machine.
   - A pause coming: the day the pause banner first shows, for a member not looking at the page.

   What each line has told is kept in config, so a line that has gone out is never carried again;
   [told] records it inside the digest's own transaction, so a digest that fails to write tells
   nothing. *)

open Digestif_core

let k_repositories = "digest_told_repositories_found_at"
let k_first_note = "digest_told_first_note"
let k_problems = "digest_told_problems_first_seen_at"
let k_pause = "digest_told_pause_warning"

(* The jobs that write, check or send a note: a problem opened on one is a run that could not. *)
let note_jobs = [ "write_version"; "pii_check"; "rules_check"; "send" ]

type line = { text : string; tell : unit -> unit }

(* Undecided repositories found after the last ones told, counted. *)
let repositories (log : Log.t) =
  let after = Store.config log k_repositories in
  match
    Log.rows log
      "SELECT COUNT(*), MAX(found_at) FROM ui_repositories WHERE status = \
       'undecided' AND (? IS NULL OR found_at > ?)"
      [ Log.opt after; Log.opt after ]
  with
  | [ [| n; latest |] ] when Log.int n > 0 ->
      let n = Log.int n in
      Some
        {
          text =
            (if n = 1 then "1 new repository waits for you on your machine."
             else
               Printf.sprintf
                 "%d new repositories wait for you on your machine." n);
          tell =
            (fun () ->
              Option.iter
                (Store.set_config log k_repositories)
                (Log.text_opt latest));
        }
  | _ -> None

(* The first note, handed over and waiting, while the member is still Onboarding. *)
let first_note (log : Log.t) =
  if Store.Stages.stage log <> "onboarding" then None
  else
    match Option.bind (Store.Notes.first_id log) (Store.Notes.find log) with
    | Some n
      when n.n_status = "waiting"
           && Store.Notes.has_versions log n.n_id
           && Store.config log k_first_note <> Some n.n_id ->
        Some
          {
            text = "Your first note is ready on your machine.";
            tell = (fun () -> Store.set_config log k_first_note n.n_id);
          }
    | _ -> None

(* An open problem on a note's job that opened after the last one told. *)
let could_not_run (log : Log.t) =
  let after = Store.config log k_problems in
  let opened =
    Store.Problems.open_ log
    |> List.filter (fun (p : Store.Problems.problem) ->
        List.mem p.job note_jobs
        && match after with Some a -> p.first_seen_at > a | None -> true)
  in
  match opened with
  | [] -> None
  | _ ->
      let latest =
        List.fold_left
          (fun acc (p : Store.Problems.problem) -> max acc p.first_seen_at)
          "" opened
      in
      Some
        {
          text =
            "Digestif could not run today. Open it on your machine to see why.";
          tell = (fun () -> Store.set_config log k_problems latest);
        }

(* The pause banner, told once for each note and each start of its 30 days. *)
let pause_coming (log : Log.t) ~now =
  match Store.Pause.warning log ~now with
  | None -> None
  | Some (n, from, at) ->
      let key = Printf.sprintf "%s@%.0f" n.n_id from in
      if Store.config log k_pause = Some key then None
      else
        let written =
          Option.value (Time_fmt.to_unix n.written_at) ~default:from
        in
        Some
          {
            text =
              Printf.sprintf
                "Your %s note has waited %d days. Digestif pauses on %s at %s \
                 unless it goes out."
                (Api.Pause.Ask.day written)
                (int_of_float ((now -. from) /. Store.Pause.day))
                (Api.Pause.Ask.day at) (Api.Pause.Ask.clock at);
            tell = (fun () -> Store.set_config log k_pause key);
          }

let lines (log : Log.t) ~now =
  List.filter_map Fun.id
    [
      repositories log; first_note log; could_not_run log; pause_coming log ~now;
    ]

(* The relay lines (docs/releases.md, Relay releases): what this node deployed to the relay it
   operates or why it rolled back (Relay_deploy.Deploy), a deploy token held for a relay another
   member operates (Relay_deploy.Operate), and a relay left behind (Relay_deploy.Lag).
   Each module keeps what it has told. *)
let relay_lines (node : Node.t) ~now =
  List.map
    (fun (l : Digestif_relay_deploy.Line.t) -> { text = l.text; tell = l.tell })
    (Digestif_relay_deploy.Deploy.digest_lines node ~now
    @ Digestif_relay_deploy.Operate.digest_lines node ~now
    @ Digestif_relay_deploy.Lag.digest_lines node ~now)

(* A rollback the deploy pass could not finish (Relay_deploy.Deploy.lead_lines) leads the
   section, on every digest until the relay answers a version the node knows. *)
let lead_lines (node : Node.t) ~now =
  List.map
    (fun (l : Digestif_relay_deploy.Line.t) -> { text = l.text; tell = l.tell })
    (Digestif_relay_deploy.Deploy.lead_lines node ~now)

(* The digest's hook (Daily_digest.machine): this machine's stage and its lines. *)
let machine (node : Node.t) ~now : Digestif_daily.Daily_digest.machine =
  let log = node.log in
  let ls = lead_lines node ~now @ lines log ~now @ relay_lines node ~now in
  {
    paused = Store.Pause.paused log;
    lines = List.map (fun l -> l.text) ls;
    told = (fun () -> List.iter (fun l -> l.tell ()) ls);
  }
