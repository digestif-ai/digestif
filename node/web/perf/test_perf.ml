(* ISS-41944: every node page answers within [budget_ms] at p95 on a heavy machine, and no page
   grows meaningfully slower than the baseline it last recorded.

   The fixture is a member's machine after years of work: [clones] git clones under ~/code, spread
   over [organizations] organizations, and [transcripts] Claude Code transcripts across a project
   directory per clone, all under a HOME of the test's own, and a log holding [digests] nights of
   digests and [summaries] summaries. The node is the demo circle with its
   hand-set sources released, so the machine scan runs over that HOME exactly as it would on the
   member's machine, and its first pass is stored before any page is read: a page reads the store,
   never the disk (Machine_scan).

   Every GET the UI reads is called [samples] times through the server's own handler, which is the
   node's whole server time for a request: the session check, the route, the store's reads and the
   JSON written out. A route fails when its p95 exceeds [budget_ms], or when it exceeds what
   baseline.json recorded for it, scaled by the run's [machine_shift], by more than [regression]
   allows. A route the baseline does not
   name yet is held to the budget alone and printed, so adding a route is adding its line.

   DIGESTIF_PERF_RECORD=<file> writes what this run measured to <file>, in baseline.json's shape,
   which is how the baseline is retaken after a change that is meant to make a page slower:

       cd node && DIGESTIF_PERF_RECORD=$PWD/web/perf/baseline.json \
         dune exec web/perf/test_perf.exe *)

open Digestif_core
open Digestif_web

let budget_ms = 50.
let clones = 1000
let organizations = 50
let transcripts = 5000

(* A node a few years old (ISS-41988): a note a night for three years, and an ask about every other
   day, a few still open and a third of the rest answered. *)
let notes = 1100
let asks = 600
let samples = 40

(* Nights of this node's digests in the log: a member's node writes one a night, so this is eight
   years of them, or a circle's summaries over two. Every request folds the circle from the log, and
   the fold reads circle-state envelopes alone, so a page's floor holds as the log ages (ISS-42063). *)
let digests = 3000

(* Summaries in the log beside them: a circle adds one per member per night, so this is ten members
   for ten months, or three for nearly three years. The feed, a message's replies and a member's
   recent list page in the log and open only what they show, so they hold as these pile up
   (ISS-42119). *)
let summaries = 3000

(* Meaningfully slower: more than [factor] times the recorded p95 and more than [slack_ms] above
   it. Both, so a route recorded at a fraction of a millisecond is not failed by scheduling noise,
   and a slow route is not let through a regression that only adds a constant. A runner's load
   moves one route's p95 by up to about three times between runs, which is what the factor clears.

   A slow or loaded machine moves EVERY route at once, and by more than that: a cloud runner has
   measured every route at two to four times its baseline in the same run. So the baseline a route
   is held to is first scaled by the run's [shift], the median over every route the baseline names
   of what it measured over what was recorded, and never below one, so a fast machine is held to
   the baseline as recorded. A median is moved by the machine and not by one route: a route that
   regresses still stands out from the rest by its factor, and a slower page everywhere is still
   held to the budget, which no shift scales (ISS-42329). *)
let factor = 3.
let slack_ms = 5.

let regression ?(shift = 1.) ~baseline p95 =
  let baseline = baseline *. shift in
  p95 > baseline *. factor && p95 > baseline +. slack_ms

let median = function
  | [] -> None
  | l ->
      let a = Array.of_list l in
      Array.sort compare a;
      let n = Array.length a in
      Some
        (if n mod 2 = 1 then a.(n / 2) else (a.((n / 2) - 1) +. a.(n / 2)) /. 2.)

(* How much slower than the baseline's machine this run's machine is: the median of measured over
   recorded across the routes the baseline names, at least one. *)
let machine_shift ~baseline measured =
  List.filter_map
    (fun (name, ms) ->
      match List.assoc_opt name baseline with
      | Some b when b > 0. -> Some (ms /. b)
      | _ -> None)
    measured
  |> median |> Option.value ~default:1. |> Float.max 1.

(* the fixture *)

let tmpdir () =
  let d = Filename.temp_file "digestif-perf" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  d

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    Unix.mkdir d 0o755
  end

let write p text =
  mkdir_p (Filename.dirname p);
  Out_channel.with_open_bin p (fun oc -> output_string oc text)

(* A month ago: no clone's HEAD has moved in the digest's window, as on most of a heavy machine. *)
let old = Unix.gettimeofday () -. (40. *. 86400.)

let clone home i =
  let dir = Printf.sprintf "%s/code/repo-%04d" home i in
  let org = Printf.sprintf "org-%02d" (i mod organizations) in
  write
    (Filename.concat dir ".git/config")
    (Printf.sprintf
       "[core]\n\
        \trepositoryformatversion = 0\n\
        [remote \"origin\"]\n\
        \turl = https://github.com/%s/repo-%04d.git\n\
        \tfetch = +refs/heads/*:refs/remotes/origin/*\n"
       org i);
  write (Filename.concat dir ".git/HEAD") "ref: refs/heads/main\n";
  let reflog = Filename.concat dir ".git/logs/HEAD" in
  write reflog "0000 1111 Someone <someone@example.com> 0 +0000\tclone\n";
  Unix.utimes reflog old old;
  write (Filename.concat dir "README.md") "# A clone\n";
  write (Filename.concat dir "src/main.ml") "let () = ()\n";
  dir

let transcript p i =
  write p
    (String.concat "\n"
       [
         Printf.sprintf {|{"type":"ai-title","aiTitle":"Session %d"}|} i;
         {|{"type":"user","message":{"role":"user","content":"work"}}|};
         {|{"type":"assistant","message":{"role":"assistant","content":"done"}}|};
       ]
    ^ "\n");
  Unix.utimes p old old

let machine () =
  let home = tmpdir () in
  let dirs = List.init clones (clone home) in
  let per = transcripts / clones in
  List.iteri
    (fun i dir ->
      let project =
        Filename.concat
          (Filename.concat home ".claude/projects")
          (Sources.encode_segment dir)
      in
      for k = 0 to per - 1 do
        transcript
          (Filename.concat project (Printf.sprintf "s-%04d-%d.jsonl" i k))
          ((i * per) + k)
      done)
    dirs;
  write (Filename.concat home ".claude/history.jsonl") "";
  home

(* [notes] notes, one a night going back from yesterday, each approved and with its one version. *)
let add_notes (n : Node.t) =
  Log.transaction n.log (fun () ->
      for i = 1 to notes do
        let at =
          Time_fmt.of_unix (Unix.gettimeofday () -. (float_of_int i *. 86400.))
        in
        ignore
          (Store.Notes.add n.log ~at ~status:"approved"
             (Printf.sprintf "Worked on: night %d.\nStuck on: nothing." i))
      done)

(* [asks] asks the member's agent raised, sealed to the member as the demo's are: the newest few
   still open, the rest lapsed, and every third answered before it lapsed. *)
let add_asks (n : Node.t) =
  let enc = Result.get_ok (Node.encryption_key n) in
  let now = Unix.gettimeofday () in
  let at h = Time_fmt.of_unix (now -. (h *. 3600.)) in
  Log.transaction n.log (fun () ->
      for i = 1 to asks do
        let a : Digestif_mail.Ask.t =
          {
            kind = None;
            title = Printf.sprintf "Ask %d" i;
            detail = "An intro the circle asked for.";
            about = None;
            options =
              [
                { id = "yes"; label = "Make the intro"; recommended = true };
                { id = "no"; label = "Decline"; recommended = false };
              ];
            on_no_answer = "no";
            lapses_at = Some (at (float_of_int ((i * 48) - 120)));
          }
        in
        let plaintext =
          match Digestif_mail.Ask.plaintext a with
          | `Assoc f -> `Assoc (f @ [ ("kind", `String "intro") ])
          | j -> j
        in
        let hash, _ =
          Result.get_ok
            (Node.write n ~kind:"ask"
               (`Assoc
                  [
                    ( "sealed",
                      Digestif_mail.Seal.seal ~recipients:[ enc.public ]
                        plaintext );
                  ]))
        in
        if i mod 3 = 0 then
          ignore
            (Result.get_ok
               (Node.write n ~kind:"decision"
                  (Digestif_mail.Ask.decision_body ~member_key:enc.public
                     ~ask:hash ~option:"yes")))
      done)

(* [digests] nights of this node's own digests and [summaries] of its summaries, the oldest first,
   behind everything the demo wrote. A digest's body is a digest's shape with a sealed mail of a
   digest's size, which nothing on a page reads; a summary's is a night's note in the agent's voice,
   which the feed shows. *)
let aged_log (n : Node.t) =
  let key = match Node.device_key n with Ok k -> k | Error e -> failwith e in
  let seq, prev = Node.next_position n key in
  let now = Unix.gettimeofday () in
  let write (seq, prev) ~created_at kind body =
    let sg = Envelope.create ~key ~seq ?prev ~created_at ~epoch:0 ~kind body in
    (seq + 1, Some (Node.store n sg))
  in
  let night ?(after = 0.) count i =
    Time_fmt.of_unix (now -. (float_of_int (count - i) *. 86400.) +. after)
  in
  (* One transaction, as the notes and asks are written: a commit per envelope is a WAL sync per
     envelope, which over six thousand of them was most of this test's time (ISS-42494). *)
  Log.transaction n.log @@ fun () ->
  let position =
    List.fold_left
      (fun position i ->
        let created_at = night digests i in
        write position ~created_at "digest"
          (`Assoc
             [
               ("date", `String (String.sub created_at 0 10));
               ("sealed", `String (String.make 1500 'x'));
               ("links", `List []);
             ]))
      (seq, prev) (List.init digests Fun.id)
  in
  ignore
    (List.fold_left
       (fun position i ->
         (* A night's summary, an hour after that night's digest. *)
         write position
           ~created_at:(night ~after:3600. summaries i)
           "summary"
           (Content.summary_body ~voice:"agent" ~stage:"active"
              ~text:
                (Printf.sprintf
                   "Worked on: night %d of the importer.\n\
                    Learned: %s\n\
                    Stuck on: nothing."
                   i (String.make 400 'x'))
              ()))
       position
       (List.init summaries Fun.id))

(* The demo circle on [home]: its member, notes, asks and rules, with the machine scan of [home]
   stored in place of the demo's hand-set sources, and a few years of notes and asks. *)
let node home =
  Unix.putenv "HOME" home;
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  (match Demo.seed n with Ok () -> () | Error e -> failwith e);
  add_notes n;
  add_asks n;
  aged_log n;
  Log.exec n.log "DELETE FROM config WHERE key = ?" [ Log.s Sources.k_fixed ];
  Log.exec n.log "DELETE FROM config WHERE key = ?"
    [ Log.s Machine_scan.k_scanned_at ];
  let t0 = Unix.gettimeofday () in
  Machine_scan.scan ~now:t0 n.log;
  let first = Unix.gettimeofday () -. t0 in
  let t1 = Unix.gettimeofday () in
  let stats = Machine_scan.scan_stats ~now:t1 n.log in
  let again = Unix.gettimeofday () -. t1 in
  Printf.printf "machine scan: first %.0fms, unchanged rescan %.0fms\n%!"
    (first *. 1000.) (again *. 1000.);
  (match stats with
  | Some s when s.clones_read = 0 && s.projects_read = 0 -> ()
  | Some s ->
      Alcotest.failf "an unchanged rescan reread %d clones and %d projects"
        s.clones_read s.projects_read
  | None -> Alcotest.fail "the rescan did not read the index");
  n

(* the server, as the UI calls it *)

let request ?(headers = []) target : Http.request =
  let path, query =
    match String.index_opt target '?' with
    | Some i ->
        ( String.sub target 0 i,
          Http.parse_query
            (String.sub target (i + 1) (String.length target - i - 1)) )
    | None -> (target, [])
  in
  {
    meth = "GET";
    target;
    path;
    query;
    headers = ("host", "127.0.0.1:7420") :: headers;
    body = "";
  }

let session n =
  let token = Store.new_launch_token n.Node.log in
  let r = Server.handler n (request ("/launch?token=" ^ token)) in
  let cookie = List.assoc "Set-Cookie" r.headers in
  String.sub cookie 0 (String.index cookie ';')

let get n cookie path =
  Server.handler n
    (request
       ~headers:[ ("cookie", cookie); ("digestif-local", "1") ]
       ("/api/v0/" ^ path))

let json n cookie path =
  let r = get n cookie path in
  if r.status <> 200 then
    failwith (Printf.sprintf "GET %s answered %d: %s" path r.status r.body);
  Yojson.Safe.from_string r.body

let items = function
  | `List l -> l
  | `Assoc f ->
      List.find_map
        (fun k ->
          match List.assoc_opt k f with Some (`List l) -> Some l | _ -> None)
        [ "items"; "notes" ]
      |> Option.value ~default:[]
  | _ -> []

let field name = function
  | `Assoc f -> (
      match List.assoc_opt name f with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let first_of n cookie path name =
  List.find_map (field name) (items (json n cookie path))

let enc s =
  String.concat ""
    (List.map
       (function
         | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~') as c
           ->
             String.make 1 c
         | c -> Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq s)))

(* Every GET the UI reads, by the name the baseline keys it on, and the path it is called at. A
   route that takes an id is called with one the list route hands back. *)
let routes n cookie =
  let org = Option.get (first_of n cookie "organizations" "id") in
  (* A page after the first: the cursor is the 50th row of [list], the last a screen shows. *)
  let after name list key path =
    match List.filteri (fun i _ -> i = 49) (items (json n cookie list)) with
    | [ r ] -> [ (name, path (enc (Option.get (field key r)))) ]
    | _ -> failwith (Printf.sprintf "%s handed back fewer than 50 rows" list)
  in
  let with_id name list key path =
    match first_of n cookie list key with
    | Some id -> [ (name, path (enc id)) ]
    | None -> failwith (Printf.sprintf "%s handed back no %s" list key)
  in
  [
    ("status", "status");
    ("feed", "feed?limit=50");
    ("asks", "asks?status=open");
    ("members", "members");
    ("invitees", "invitees");
    ("paused", "paused");
    ("brief", "brief");
    ("sources", "sources");
    ("rules", "rules");
    ("rules/quiet_hours", "rules/quiet_hours");
    ("rules/deny", "rules/deny");
    ("notes", "notes");
    ("settings/approval", "settings/approval");
    ("learnings", "learnings");
    ("settings/note_time", "settings/note_time");
    ("settings/names", "settings/names");
    ("problems", "problems?open=true");
    ("organizations", "organizations");
    ("repositories", "repositories?limit=50");
    ( "repositories?organization_id",
      "repositories?limit=51&organization_id=" ^ enc org );
    ("repositories?q", "repositories?limit=50&q=repo-09");
    ("repositories/counts", "repositories/counts");
    ("commit_authors", "commit_authors");
    (* ISS-41988: the paged forms the UI reads, a page and the page after it. *)
    ("notes?limit", "notes?limit=51");
    ("asks?limit", "asks?limit=51");
    ("members?limit", "members?limit=51");
    ("rules/deny?limit", "rules/deny?limit=51");
  ]
  @ after "notes?cursor" "notes?limit=51" "id" (fun c ->
      "notes?limit=51&cursor=" ^ c)
  @ after "asks?cursor" "asks?limit=51" "id" (fun c ->
      "asks?limit=51&cursor=" ^ c)
  @ with_id "feed/:hash" "feed?limit=1" "hash" (fun h -> "messages/" ^ h)
  @ with_id "members/:identity" "members" "identity" (fun i -> "members/" ^ i)
  @ with_id "rules/deny/:id" "rules/deny" "id" (fun i -> "rules/deny/" ^ i)
  @ with_id "notes/:id" "notes" "id" (fun i -> "notes/" ^ i)
  @ with_id "notes/:id/log" "notes" "id" (fun i -> "notes/" ^ i ^ "/log")

let p95 times =
  let a = Array.of_list times in
  Array.sort compare a;
  let n = Array.length a in
  a.(max 0 (int_of_float (Float.ceil (0.95 *. float_of_int n)) - 1))

(* Each route's p95 server time over [samples] calls, in milliseconds, after two calls to warm it. *)
let measure n cookie (name, path) =
  let once () =
    let t = Unix.gettimeofday () in
    let r = get n cookie path in
    let ms = (Unix.gettimeofday () -. t) *. 1000. in
    if r.status <> 200 && r.status <> 404 then
      failwith (Printf.sprintf "GET %s answered %d: %s" path r.status r.body);
    ms
  in
  ignore (once ());
  ignore (once ());
  (name, p95 (List.init samples (fun _ -> once ())))

(* the baseline *)

let baseline_file = "baseline.json"

let read_baseline () =
  match Yojson.Safe.from_file baseline_file with
  | `Assoc f -> (
      match List.assoc_opt "p95_ms" f with
      | Some (`Assoc routes) ->
          List.filter_map
            (fun (k, v) ->
              match v with
              | `Float x -> Some (k, x)
              | `Int x -> Some (k, float_of_int x)
              | _ -> None)
            routes
      | _ -> [])
  | _ -> []
  | exception Sys_error _ -> []

let write_baseline file measured =
  Out_channel.with_open_bin file @@ fun oc ->
  output_string oc
  @@ Yojson.Safe.pretty_to_string
       (`Assoc
          [
            ( "fixture",
              `Assoc
                [
                  ("clones", `Int clones);
                  ("organizations", `Int organizations);
                  ("transcripts", `Int transcripts);
                  ("notes", `Int notes);
                  ("asks", `Int asks);
                  ("samples", `Int samples);
                  ("digests", `Int digests);
                  ("summaries", `Int summaries);
                ] );
            ( "p95_ms",
              `Assoc
                (List.map
                   (fun (k, v) -> (k, `Float (Float.round (v *. 100.) /. 100.)))
                   measured) );
          ]);
  output_char oc '\n'

(* Why a route's p95 fails, or None. *)
let verdict ?(shift = 1.) ~baseline (name, ms) =
  if ms > budget_ms then
    Some
      (Printf.sprintf "%s: p95 %.1fms is over the %.0fms budget" name ms
         budget_ms)
  else
    match List.assoc_opt name baseline with
    | Some b when regression ~shift ~baseline:b ms ->
        Some
          (Printf.sprintf
             "%s: p95 %.1fms against a baseline of %.1fms (%.2fms on this \
              run's machine, %.2fx); retake the baseline only if this page is \
              meant to be slower"
             name ms b (b *. shift) shift)
    | _ -> None

(* The suite runs beside every other test binary dune starts, and beside other work on a shared
   runner, so one round can be slowed by the machine rather than the route. Every route is measured
   once, which is what the run's [shift] is taken from; a route that fails against it is measured
   again, up to [rounds] in all, and its best round is its answer: a slow route is slow in every
   round. A run that records the baseline takes every round ([all]), so the baseline is what the
   route costs and not what the machine was doing. *)
let rounds = 3

let rec settle n cookie ~all ~shift ~baseline ~round (name, path) measured =
  let failed = verdict ~shift ~baseline measured <> None in
  if round < rounds && (all || failed) then
    let again =
      settle n cookie ~all ~shift ~baseline ~round:(round + 1) (name, path)
        (measure n cookie (name, path))
    in
    if snd again < snd measured then again else measured
  else measured

let budget () =
  let n = node (machine ()) in
  let cookie = session n in
  let baseline = read_baseline () in
  let record =
    match Sys.getenv_opt "DIGESTIF_PERF_RECORD" with
    | Some f when String.trim f <> "" -> Some f
    | _ -> None
  in
  let routes = routes n cookie in
  let first = List.map (measure n cookie) routes in
  let shift = if record <> None then 1. else machine_shift ~baseline first in
  Printf.printf "this run's machine against the baseline's: %.2fx\n" shift;
  let measured =
    List.map2
      (settle n cookie ~all:(record <> None) ~shift ~baseline ~round:1)
      routes first
  in
  let failures =
    List.filter_map
      (fun (name, ms) ->
        Printf.printf "%-30s p95 %6.2fms  baseline %s\n" name ms
          (match List.assoc_opt name baseline with
          | Some b -> Printf.sprintf "%.2fms" b
          | None -> "none yet");
        verdict ~shift ~baseline (name, ms))
      measured
  in
  Option.iter
    (fun f ->
      write_baseline f measured;
      Printf.printf "recorded the baseline in %s\n" f)
    record;
  match failures with [] -> () | l -> Alcotest.fail (String.concat "\n" l)

(* What counts as meaningfully slower, on its own. *)
let regressions () =
  let fails ~baseline ms =
    verdict ~baseline:[ ("r", baseline) ] ("r", ms) <> None
  in
  Alcotest.(check bool) "noise on a fast route" false (fails ~baseline:0.4 3.);
  Alcotest.(check bool)
    "a fast route grown past the slack" true (fails ~baseline:0.4 6.);
  Alcotest.(check bool)
    "a slow route within the factor" false (fails ~baseline:10. 25.);
  Alcotest.(check bool) "a slow route past it" true (fails ~baseline:10. 31.);
  Alcotest.(check bool)
    "over the budget, whatever the baseline" true (fails ~baseline:49. 51.);
  Alcotest.(check bool)
    "a route with no baseline yet" false
    (verdict ~baseline:[] ("new", 20.) <> None)

(* A machine that is slower everywhere, against a route that is slower on its own (ISS-42329). *)
let shifts () =
  let baseline =
    [ ("a", 3.); ("b", 2.3); ("c", 0.3); ("d", 1.2); ("e", 0.6) ]
  in
  let slow = [ ("a", 9.0); ("b", 9.3); ("c", 1.2); ("d", 3.4); ("e", 1.8) ] in
  let shift = machine_shift ~baseline slow in
  Alcotest.(check bool)
    "a slow runner's shift is the median ratio" true
    (Float.abs (shift -. 3.) < 0.01);
  Alcotest.(check bool)
    "every route on the slow runner passes" true
    (List.for_all (fun r -> verdict ~shift ~baseline r = None) slow);
  Alcotest.(check bool)
    "unshifted, the slow runner fails" true
    (List.exists (fun r -> verdict ~baseline r <> None) slow);
  let one = ("a", 40.) :: List.remove_assoc "a" slow in
  let shift = machine_shift ~baseline one in
  Alcotest.(check bool)
    "one route regressing on the slow runner still fails" true
    (verdict ~shift ~baseline ("a", 40.) <> None);
  let fast = List.map (fun (k, b) -> (k, b /. 2.)) baseline in
  Alcotest.(check bool)
    "a fast machine is held to the baseline as recorded" true
    (machine_shift ~baseline fast = 1.);
  Alcotest.(check bool)
    "no baseline, no shift" true
    (machine_shift ~baseline:[] slow = 1.);
  Alcotest.(check bool)
    "the budget is not shifted" true
    (verdict ~shift:10. ~baseline:[ ("r", 49.) ] ("r", 51.) <> None)

let () =
  Ci_alcotest.run "perf"
    [
      ( "node",
        [
          Alcotest.test_case "what counts as slower" `Quick regressions;
          Alcotest.test_case "a slower machine" `Quick shifts;
          Alcotest.test_case "every page within budget" `Quick budget;
        ] );
    ]
