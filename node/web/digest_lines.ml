(* ISS-42319 (DES-37153, What the digest says without an ask): the lines a digest carries that leave
   the member nothing to decide, each carried once, on the day it happens, under the rule that a
   line off the machine says only what the circle could already know. They are the digest's
   "On your machine" section:

   - New repositories: a scan added repositories to the New repositories local ask. Only the count
     of the ones not told before, never a name.
   - A note waiting: a note waits for the member to approve, the first one in its own words while
     Onboarding, any other while Active.
   - A run that failed: a problem opened on a job that writes, checks or sends a note. The kind of
     failure stays on the machine.
   - A pause coming: the day the pause banner first shows, for a member not looking at the page.

   What each line has told is kept in config, so a line that has gone out is never carried again;
   [told] records it inside the digest's own transaction, so a digest that fails to write tells
   nothing. *)

open Digestif_core

let k_repositories = "digest_told_repositories_found_at"
let k_notes = "digest_told_notes_waiting"
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

(* Every note handed over and waiting for the member, each told once (ISS-50720): the first one,
   while Onboarding, in its own words; any other while Active. Paused writes no note and tells
   none. What has been told is the ids of the waiting notes already carried, pruned to the ones
   still waiting, so a note approved or dismissed drops out and a new one is told on its day. *)
let notes_waiting (log : Log.t) =
  let stage = Store.Stages.stage log in
  if stage = "paused" then None
  else
    let told =
      Option.fold ~none:[] ~some:(String.split_on_char ' ')
        (Store.config log k_notes)
    in
    let first = Store.Notes.first_id log in
    let waiting =
      Store.Notes.waiting log
      |> List.filter (fun (n : Store.Notes.note) ->
          Store.Notes.has_versions log n.n_id
          && (stage <> "onboarding" || first = Some n.n_id))
    in
    let fresh =
      List.filter
        (fun (n : Store.Notes.note) -> not (List.mem n.n_id told))
        waiting
    in
    let text =
      match fresh with
      | [] -> None
      | [ _ ] when stage = "onboarding" ->
          Some "Your first note is ready on your machine."
      | [ _ ] -> Some "A note waits for you to approve on your machine."
      | ns ->
          Some
            (Printf.sprintf "%d notes wait for you to approve on your machine."
               (List.length ns))
    in
    Option.map
      (fun text ->
        {
          text;
          tell =
            (fun () ->
              Store.set_config log k_notes
                (String.concat " "
                   (List.map (fun (n : Store.Notes.note) -> n.n_id) waiting)));
        })
      text

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
      repositories log;
      notes_waiting log;
      could_not_run log;
      pause_coming log ~now;
    ]

(* ISS-51009 (docs/design.md, Suggesting a change to the note prompt): a suggestion this member
   judges, told once when it arrives; each of its rounds, told once when every judge has picked in
   it; and the circle's live prompt changing, told to every member once. Each says only what the
   circle's own messages already say. *)
let k_suggestion hash = "digest_told_suggestion:" ^ hash
let k_round hash = "digest_told_suggestion_round:" ^ hash
let k_live = "digest_told_live_prompt"

let suggestion_lines (node : Node.t) =
  let log = node.log in
  let c = Api.ctx_of node in
  let module P = Api.Prompts in
  let module S = Suggestions in
  match Api.self_identity c with
  | None -> []
  | Some me ->
      let judged = P.all c in
      let name id = if id = me then "you" else P.name_of c id in
      let quoted (j : S.judged) = "\"" ^ j.s.change ^ "\"" in
      let arrivals =
        List.filter_map
          (fun (j : S.judged) ->
            if
              j.status = S.Judging && S.judges_ j ~me && j.s.author <> me
              && Store.config log (k_suggestion j.s.hash) = None
            then
              Some
                {
                  text =
                    Printf.sprintf
                      "%s suggested a change to the nightly note prompt: %s. \
                       You judge it: %s."
                      (P.name_of c j.s.author) j.s.change
                      (match S.running judged ~me with
                      | Some r when r.s.hash = j.s.hash ->
                          "your notes come in two versions until it is decided"
                      | _ ->
                          "it waits for the suggestion you judge now to be \
                           decided");
                  tell =
                    (fun () ->
                      Store.set_config log (k_suggestion j.s.hash) "told");
                }
            else None)
          judged
      in
      let rounds =
        List.concat_map
          (fun (j : S.judged) ->
            if not (S.judges_ j ~me) then []
            else
              let told =
                Option.value
                  (Option.bind
                     (Store.config log (k_round j.s.hash))
                     int_of_string_opt)
                  ~default:0
              in
              List.filter_map
                (fun (r : S.round) ->
                  match r.result with
                  | Some result when r.number > told ->
                      let picks =
                        String.concat ", "
                          (List.map
                             (fun (who, p, _) ->
                               Printf.sprintf "%s picked the %s version"
                                 (name who)
                                 (match p with
                                 | S.Suggested -> "suggested"
                                 | S.Current -> "current"))
                             r.picks)
                      in
                      let outcome =
                        match result with
                        | S.Adopted ->
                            "Adopted: it is the circle's nightly note prompt."
                        | S.Not_adopted ->
                            "Not adopted: the suggestion is closed."
                        | S.Split ->
                            "Split: both versions again with your next note."
                      in
                      Some
                        {
                          text =
                            Printf.sprintf
                              "The note prompt suggestion %s: %s. %s" (quoted j)
                              picks outcome;
                          tell =
                            (fun () ->
                              Store.set_config log (k_round j.s.hash)
                                (string_of_int r.number));
                        }
                  | _ -> None)
                j.rounds)
          judged
      in
      let live =
        match P.live c judged with
        | Some l when Store.config log k_live <> Some l.l_suggestion ->
            [
              {
                text =
                  Printf.sprintf
                    "The circle's nightly note prompt changed: %s suggestion \
                     \"%s\" was adopted. Your notes are written with it from \
                     now on."
                    (if l.l_author = me then "your"
                     else P.name_of c l.l_author ^ "'s")
                    l.l_change;
                tell = (fun () -> Store.set_config log k_live l.l_suggestion);
              };
            ]
        | _ -> []
      in
      arrivals @ rounds @ live

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
  let ls =
    lead_lines node ~now @ lines log ~now @ suggestion_lines node
    @ relay_lines node ~now
  in
  {
    paused = Store.Pause.paused log;
    lines = List.map (fun l -> l.text) ls;
    told = (fun () -> List.iter (fun l -> l.tell ()) ls);
  }
