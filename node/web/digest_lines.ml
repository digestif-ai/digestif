(* ISS-42319 (DES-37153, What the digest says without an ask): the lines a digest carries that leave
   the member nothing to decide, each carried once, on the day it happens, under the rule that a
   line off the machine says only what the circle could already know. They are the digest's
   "On your machine" section:

   - New repositories: a scan found repositories that wait undecided. Only the count of the ones
     not told before, never a name.
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

(* [about] is what the line told of, kept beside the notice it raises so the notice clears itself
   once that no longer holds ([resolved]). *)
type line = {
  text : string;
  tell : unit -> unit;
  about : string;
  page : string;  (** Where on this machine the member acts (DIG-355). *)
}

(* The page a subject's line points at (DIG-355); every subject a line is raised for has one. *)
let page_of subject = Option.value (Item.notice_page subject) ~default:"/"

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
          about =
            Option.value after ~default:""
            ^ "|"
            ^ Option.value (Log.text_opt latest) ~default:"";
          page = page_of "repositories";
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
          about =
            String.concat " "
              (List.map (fun (n : Store.Notes.note) -> n.n_id) fresh);
          page = page_of "note_ready";
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
          about =
            String.concat " "
              (List.map (fun (p : Store.Problems.problem) -> p.p_id) opened);
          page = page_of "could_not_run";
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
            about = key;
            page = page_of "pause_coming";
            text =
              Printf.sprintf
                "Your %s note has waited %d days. Digestif pauses on %s at %s \
                 unless it goes out."
                (Api.Pause.Ask.day written)
                (int_of_float ((now -. from) /. Store.Pause.day))
                (Api.Pause.Ask.day at) (Api.Pause.Ask.clock at);
            tell = (fun () -> Store.set_config log k_pause key);
          }

(* ISS-52614 (docs/design.md, Inbox): each of these is a notice from the node now, not a digest
   line: raised once, on the day it happens, New in the member's Inbox, and carried by the digest's
   Inbox part with Acknowledge. New repositories is local and stays on the machine. *)
let notices (log : Log.t) ~now =
  List.filter_map
    (fun (subject, line) -> Option.map (fun l -> (subject, l)) line)
    [
      ("repositories", repositories log);
      ("note_ready", notes_waiting log);
      ("could_not_run", could_not_run log);
      ("pause_coming", pause_coming log ~now);
    ]

let k_about id = "digest_notice_about:" ^ id
let words s = List.filter (( <> ) "") (String.split_on_char ' ' s)

(* Whether what a notice of [subject] told of, [about], no longer holds: the notes it told of were
   approved or dismissed, the problems closed, the repositories decided, the note it warned of went
   out or its 30 days began again. A pause warning stays open once the pause lands: the member is no
   longer Active then, and what it warned of happened. A notice raised before [about] was kept has
   none, and clears from the state now: no note waits, no problem on a note's job is open, no
   repository waits undecided, no pause warning shows. ISS-71859 *)
let resolved (log : Log.t) ~now subject about =
  let open_problems () =
    Store.Problems.open_ log
    |> List.filter (fun (p : Store.Problems.problem) ->
        List.mem p.job note_jobs)
    |> List.map (fun (p : Store.Problems.problem) -> p.p_id)
  in
  let undecided ~after ~latest =
    match
      Log.rows log
        "SELECT COUNT(*) FROM ui_repositories WHERE status = 'undecided' AND \
         (? IS NULL OR ? = '' OR found_at > ?) AND (? IS NULL OR found_at <= \
         ?)"
        [
          Log.opt after;
          Log.opt after;
          Log.opt after;
          Log.opt latest;
          Log.opt latest;
        ]
    with
    | [ [| n |] ] -> Some (Log.int n)
    | _ -> None
  in
  match (subject, about) with
  | "note_ready", about ->
      let waiting =
        Store.Notes.waiting log
        |> List.filter (fun (n : Store.Notes.note) ->
            Store.Notes.has_versions log n.n_id)
        |> List.map (fun (n : Store.Notes.note) -> n.n_id)
      in
      let told = words (Option.value about ~default:"") in
      if told = [] then waiting = []
      else not (List.exists (fun id -> List.mem id waiting) told)
  | "could_not_run", Some about ->
      let open_ = open_problems () in
      not (List.exists (fun id -> List.mem id open_) (words about))
  | "could_not_run", None -> open_problems () = []
  | "pause_coming", _ when not (Store.Stages.active log) -> false
  | "pause_coming", None -> Store.Pause.warning log ~now = None
  | "pause_coming", Some about -> (
      let note_id =
        match String.rindex_opt about '@' with
        | Some i -> String.sub about 0 i
        | None -> about
      in
      let still_waiting =
        List.exists
          (fun (n : Store.Notes.note) -> n.n_id = note_id)
          (Store.Notes.waiting log)
      in
      (not still_waiting)
      ||
      match Store.Pause.next log ~now with
      | None -> true
      | Some (n, from, _) -> Printf.sprintf "%s@%.0f" n.n_id from <> about)
  | "repositories", Some about -> (
      match String.index_opt about '|' with
      | None -> false
      | Some i -> (
          let after = String.sub about 0 i in
          let latest = String.sub about (i + 1) (String.length about - i - 1) in
          match undecided ~after:(Some after) ~latest:(Some latest) with
          | Some n -> n = 0
          | None -> false))
  | "repositories", None -> undecided ~after:None ~latest:None = Some 0
  | _ -> false

(* Settle every open notice from the node whose cause is gone, Done for the member as resolved, so
   the Inbox holds only what still waits on them. *)
let clear_notices (node : Node.t) ~now =
  let log = node.log in
  Log.rows log
    "SELECT id, subject FROM ui_items WHERE kind = 'notice' AND voice =      \
     'node' AND done IS NULL AND subject IS NOT NULL"
    []
  |> List.iter (fun row ->
      match row with
      | [| id; subject |] ->
          let id = Log.text id and subject = Log.text subject in
          if resolved log ~now subject (Store.config log (k_about id)) then
            Store.Items.settle log id ~why:"resolved" ~at:(Time_fmt.of_unix now)
      | _ -> ());
  (* What a notice told of is kept only while it is open: settled here, acknowledged or marked Done
     by the member, its key goes. *)
  let prefix = k_about "" in
  Log.exec log
    "DELETE FROM config WHERE substr(key, 1, ?) = ? AND substr(key, ?) IN \
     (SELECT id FROM ui_items WHERE done IS NOT NULL)"
    Sqlite3.Data.
      [
        INT (Int64.of_int (String.length prefix));
        Log.s prefix;
        INT (Int64.of_int (String.length prefix + 1));
      ]

(* Clear the notices whose cause is gone, then raise every notice not raised yet, each recorded as
   told once it is in the Inbox, with what it told of. Run on every pass and again inside the
   digest's own transaction, so a notice is New on the day it happens, a digest never misses one,
   and none outlives its cause by more than a pass. *)
let raise_notices (node : Node.t) ~now =
  clear_notices node ~now;
  let c = Api.ctx_of node in
  List.iter
    (fun (subject, (l : line)) ->
      match Api.Inbox.raise_notice c ~subject ~title:l.text
          ?detail:(Item.notice_instruction subject) ()
      with
      | Ok id ->
          Store.set_config node.log (k_about id) l.about;
          l.tell ()
      | Error e ->
          Printf.eprintf "%s digest: the %s notice: %s\n" (Time_fmt.now ())
            subject e)
    (notices node.log ~now)

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
                  about = "";
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
                          about = "";
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
                about = "";
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
    (fun (l : Digestif_relay_deploy.Line.t) ->
      { text = l.text; tell = l.tell; about = "" })
    (Digestif_relay_deploy.Deploy.digest_lines node ~now
    @ Digestif_relay_deploy.Operate.digest_lines node ~now
    @ Digestif_relay_deploy.Lag.digest_lines node ~now)

(* A rollback the deploy pass could not finish (Relay_deploy.Deploy.lead_lines) leads the
   section, on every digest until the relay answers a version the node knows. *)
let lead_lines (node : Node.t) ~now =
  List.map
    (fun (l : Digestif_relay_deploy.Line.t) ->
      { text = l.text; tell = l.tell; about = "" })
    (Digestif_relay_deploy.Deploy.lead_lines node ~now)

(* Where the member opens an item on this machine. *)
let page (node : Node.t) id =
  Option.value (Server.url node) ~default:"http://127.0.0.1" ^ "/inbox/" ^ id

(* The digest's hook (Daily_digest.machine), run inside the digest's transaction: this machine's
   stage, its lines, the Inbox part and Your agent did. *)
let machine (node : Node.t) ~now : Digestif_daily.Daily_digest.machine =
  let log = node.log in
  raise_notices node ~now;
  let ls =
    lead_lines node ~now @ suggestion_lines node @ relay_lines node ~now
  in
  let c = Api.ctx_of node in
  let inbox = Api.Inbox.digest_entries c ~page:(page node) in
  {
    paused = Store.Pause.paused log;
    lines = List.map (fun l -> l.text) ls;
    inbox;
    agent_did =
      Api.Inbox.agent_did c
        ~since:(Log.get_config log Digestif_daily.Daily_digest.k_last_at);
    told = (fun () -> List.iter (fun l -> l.tell ()) ls);
  }
