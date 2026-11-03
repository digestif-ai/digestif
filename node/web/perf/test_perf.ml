(* ISS-41944: every node page answers within [budget_ms] at p95 on a heavy machine, and no page
   grows meaningfully slower than the baseline it last recorded.

   The fixture is a member's machine after years of work: [clones] git clones under ~/code, spread
   over [organizations] organizations, and [transcripts] Claude Code transcripts across a project
   directory per clone, all under a HOME of the test's own, and a log holding [digests] nights of
   digests. The node is the demo circle with its
   hand-set sources released, so the machine scan runs over that HOME exactly as it would on the
   member's machine, and its first pass is stored before any page is read: a page reads the store,
   never the disk (Machine_scan).

   Every GET the UI reads is called [samples] times through the server's own handler, which is the
   node's whole server time for a request: the session check, the route, the store's reads and the
   JSON written out. A route fails when its p95 exceeds [budget_ms], or when it exceeds what
   baseline.json recorded for it by more than [regression] allows. A route the baseline does not
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
let samples = 40

(* Nights of this node's digests in the log: a member's node writes one a night, so this is eight
   years of them, or a circle's summaries over two. Every request folds the circle from the log, and
   the fold reads circle-state envelopes alone, so a page's floor holds as the log ages (ISS-42063). *)
let digests = 3000

(* Meaningfully slower: more than [factor] times the recorded p95 and more than [slack_ms] above
   it. Both, so a route recorded at a fraction of a millisecond is not failed by scheduling noise,
   and a slow route is not let through a regression that only adds a constant. A runner's load
   moves a route's p95 by up to about three times between runs, which is what the factor clears. *)
let factor = 3.
let slack_ms = 5.

let regression ~baseline p95 =
  p95 > baseline *. factor && p95 > baseline +. slack_ms

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

(* [digests] nights of this node's own digests, the oldest first, behind everything the demo wrote.
   The body is a digest's shape with a sealed mail of a digest's size: nothing on a page reads it. *)
let aged_log (n : Node.t) =
  let key = match Node.device_key n with Ok k -> k | Error e -> failwith e in
  let seq, prev = Node.next_position n key in
  let now = Unix.gettimeofday () in
  ignore
    (List.fold_left
       (fun (seq, prev) night ->
         let created_at =
           Time_fmt.of_unix (now -. (float_of_int (digests - night) *. 86400.))
         in
         let sg =
           Envelope.create ~key ~seq ?prev ~created_at ~epoch:0 ~kind:"digest"
             (`Assoc
                [
                  ("date", `String (String.sub created_at 0 10));
                  ("sealed", `String (String.make 1500 'x'));
                  ("links", `List []);
                ])
         in
         (seq + 1, Some (Node.store n sg)))
       (seq, prev) (List.init digests Fun.id))

(* The demo circle on [home]: its member, notes, asks and rules, with the machine scan of [home]
   stored in place of the demo's hand-set sources. *)
let node home =
  Unix.putenv "HOME" home;
  let n = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  Store.init n.log;
  (match Demo.seed n with Ok () -> () | Error e -> failwith e);
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
  ]
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
                  ("samples", `Int samples);
                  ("digests", `Int digests);
                ] );
            ( "p95_ms",
              `Assoc
                (List.map
                   (fun (k, v) -> (k, `Float (Float.round (v *. 100.) /. 100.)))
                   measured) );
          ]);
  output_char oc '\n'

(* Why a route's p95 fails, or None. *)
let verdict ~baseline (name, ms) =
  if ms > budget_ms then
    Some
      (Printf.sprintf "%s: p95 %.1fms is over the %.0fms budget" name ms
         budget_ms)
  else
    match List.assoc_opt name baseline with
    | Some b when regression ~baseline:b ms ->
        Some
          (Printf.sprintf
             "%s: p95 %.1fms against a baseline of %.1fms; retake the baseline \
              only if this page is meant to be slower"
             name ms b)
    | _ -> None

(* The suite runs beside every other test binary dune starts, and beside other work on a shared
   runner, so one round can be slowed by the machine rather than the route. A route that fails is
   measured again, up to [rounds] in all, and its best round is its answer: a slow route is slow in
   every round. A run that records the baseline takes every round ([all]), so the baseline is what
   the route costs and not what the machine was doing. *)
let rounds = 3

let rec settle n cookie ~all ~baseline ~round (name, path) =
  let measured = measure n cookie (name, path) in
  let failed = verdict ~baseline measured <> None in
  match () with
  | () when round < rounds && (all || failed) ->
      let again =
        settle n cookie ~all ~baseline ~round:(round + 1) (name, path)
      in
      if snd again < snd measured then again else measured
  | _ -> measured

let budget () =
  let n = node (machine ()) in
  let cookie = session n in
  let baseline = read_baseline () in
  let record =
    match Sys.getenv_opt "DIGESTIF_PERF_RECORD" with
    | Some f when String.trim f <> "" -> Some f
    | _ -> None
  in
  let measured =
    List.map
      (settle n cookie ~all:(record <> None) ~baseline ~round:1)
      (routes n cookie)
  in
  let failures =
    List.filter_map
      (fun (name, ms) ->
        Printf.printf "%-30s p95 %6.2fms  baseline %s\n" name ms
          (match List.assoc_opt name baseline with
          | Some b -> Printf.sprintf "%.2fms" b
          | None -> "none yet");
        verdict ~baseline (name, ms))
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

let () =
  Ci_alcotest.run "perf"
    [
      ( "node",
        [
          Alcotest.test_case "what counts as slower" `Quick regressions;
          Alcotest.test_case "every page within budget" `Quick budget;
        ] );
    ]
