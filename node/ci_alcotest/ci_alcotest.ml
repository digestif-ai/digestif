(* TEST HEALTH, THE ALCOTEST HALF (ISS-19890, design DES-18577 "Every repository
   with CI").

   A copy of devops templates/dune/test/ci_alcotest.ml; the shell half is
   ci/dune-test.sh, a copy of templates/dune/ci/dune-test.sh. A suite calls
   [run] where it called `Alcotest.run`, and links `alcotest` and `unix`.

   A SPEC IS THE BINARY PLUS THE TEST CASE: `<binary>.<group>.<case>`, every
   character outside [A-Za-z0-9._-] written `_` so that a spec is one word in a
   lists file and a file name. A lists line naming the bare binary names every
   case it holds.

   WHAT IT READS, all set by ci/dune-test.sh and all empty in a run by hand,
   where this is `Alcotest.run` under the binary's own log root (below):

     CI_ALCOTEST_LISTS    the text of the lists file CI_TEST_LISTS names:
                          a quarantined or slow case is left out, a proof case
                          runs whatever else lists it
     CI_SLOW_SPECS        `1` runs the slow cases alone
     CI_ALCOTEST_RERUN    the binaries the rerun runs; any other exits at once
     CI_ALCOTEST_REPORTS  where each case writes `TEST-<spec>.xml`, one JUnit
                          testsuite holding its one testcase, and the binary
                          writes `.ci-binaries/<binary>` (running, passed or
                          failed), which is how the shell tells a binary that
                          died from one that passed

   The first three are the test actions' declared `env_var` deps, so dune
   re-runs a binary whose answer they change and caches it otherwise.

   EACH BINARY KEEPS ITS OWN LOG ROOT, `$PWD/_build/_tests/<binary>`, in every
   run. alcotest's default root is `$PWD/_build/_tests`, the same directory for
   every binary dune runs from one test directory, and each run unlinks and
   re-creates the `latest` symlink there: two binaries started together race on
   that one link and the loser dies with `Failed 6 times to create symlink`. A
   root of its own means no other process writes the links it writes. The
   `Full test results in` line names `.../_tests/<binary>/<suite>`, and
   devops (`Ocaml.suite_finished`) reads the suite off its last segment.
   ISS-34119 *)

let binary =
  let base = Filename.basename Sys.executable_name in
  match Filename.chop_suffix_opt ~suffix:".exe" base with Some b -> b | None -> base

let lists_env = "CI_ALCOTEST_LISTS"
let slow_env = "CI_SLOW_SPECS"
let rerun_env = "CI_ALCOTEST_RERUN"
let reports_env = "CI_ALCOTEST_REPORTS"
let log_dir () = Filename.concat (Filename.concat (Sys.getcwd ()) (Filename.concat "_build" "_tests")) binary
let set name = match Sys.getenv_opt name with Some v when String.trim v <> "" -> Some v | _ -> None
let words text = String.split_on_char ' ' text |> List.map String.trim |> List.filter (( <> ) "")

(* ONLY THE PROCESS THAT STARTED WRITES: a case that forks runs the wrapper in
   the child too. *)
let pid = Unix.getpid ()
let mine () = Unix.getpid () = pid

(* ---- the spec ---- *)

let clean =
  String.map (function ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-') as c -> c | _ -> '_')

let spec_of ~group ~name =
  let s = String.concat "." [ binary; clean group; clean name ] in
  if String.length s <= 180 then s
  else String.sub s 0 170 ^ "-" ^ String.sub (Digest.to_hex (Digest.string s)) 0 8

(* Two cases one spec would name: the second is `<spec>.2`, and so on, in the
   order the suite declares them. *)
let unique seen spec =
  match Hashtbl.find_opt seen spec with
  | None ->
      Hashtbl.replace seen spec 1;
      spec
  | Some n ->
      Hashtbl.replace seen spec (n + 1);
      Printf.sprintf "%s.%d" spec (n + 1)

(* ---- the lists ---- *)

type lists = { quarantined : string list; slow : string list; proof : string list }

(* The `quarantined`, `slow` and `proof` lines of a lists file; ci/dune-test.sh
   has refused a file that is not the format before any binary runs. *)
let parse_lists text =
  List.fold_left
    (fun l line ->
      match words line with
      | [ "quarantined"; s ] -> { l with quarantined = s :: l.quarantined }
      | [ "slow"; s ] -> { l with slow = s :: l.slow }
      | [ "proof"; s ] -> { l with proof = s :: l.proof }
      | _ -> l)
    { quarantined = []; slow = []; proof = [] }
    (String.split_on_char '\n' text)

(* Whether the build runs [spec]. With no lists nothing is left out; with lists
   a quarantined or slow case is, and [slow_only] inverts that to the slow
   cases alone. A quarantined case runs nowhere, and a proof case is the one its
   own build is proving, so it runs. *)
let runs ~lists ~slow_only spec =
  match lists with
  | None -> not slow_only
  | Some l ->
      let on names = List.mem spec names || List.mem binary names in
      if slow_only then on l.slow && not (on l.quarantined)
      else on l.proof || not (on l.quarantined || on l.slow)

(* Every case of [tests] the build runs, each with its spec; a group left with
   none is dropped. *)
let select ~lists ~slow_only tests =
  let seen = Hashtbl.create 64 in
  List.filter_map
    (fun (group, cases) ->
      let kept =
        List.filter_map
          (fun ((name, _, _) as case) ->
            let spec = unique seen (spec_of ~group ~name) in
            if runs ~lists ~slow_only spec then Some (spec, case) else None)
          cases
      in
      if kept = [] then None else Some (group, kept))
    tests

(* ---- the reports ---- *)

let escape text =
  let b = Buffer.create (String.length text) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | '\'' -> Buffer.add_string b "&apos;"
      | ('\n' | '\t') as c -> Buffer.add_char b c
      | c when Char.code c < 0x20 -> Buffer.add_char b '?'
      | c -> Buffer.add_char b c)
    text;
  Buffer.contents b

let write_atomic path text =
  let tmp = Printf.sprintf "%s.%d.tmp" path pid in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc text);
  Sys.rename tmp path

type outcome = Passed | Skipped | Failed of { kind : string; message : string; trace : string }

let junit ~spec ~name ~took outcome =
  let failures, skipped, inner =
    match outcome with
    | Passed -> (0, 0, "")
    | Skipped -> (0, 1, "\n    <skipped/>\n  ")
    | Failed { kind; message; trace } ->
        ( 1,
          0,
          Printf.sprintf "\n    <failure message=\"%s\" type=\"%s\">%s</failure>\n  " (escape message)
            (escape kind) (escape trace) )
  in
  Printf.sprintf
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
     <testsuite name=\"%s\" tests=\"1\" failures=\"%d\" errors=\"0\" skipped=\"%d\" time=\"%.3f\">\n\
    \  <testcase classname=\"%s\" name=\"%s\" time=\"%.3f\">%s</testcase>\n\
     </testsuite>\n"
    (escape spec) failures skipped took (escape spec) (escape name) took inner

let is_skip e =
  let slot = Printexc.exn_slot_name e in
  slot = "Skip" || String.ends_with ~suffix:".Skip" slot

(* [case], writing its report into [dir] as it finishes. *)
let wrap ~dir ~spec ((name, speed, f) : unit Alcotest.test_case) : unit Alcotest.test_case =
  ( name,
    speed,
    fun () ->
      let t0 = Unix.gettimeofday () in
      let finish outcome =
        if mine () then
          write_atomic
            (Filename.concat dir ("TEST-" ^ spec ^ ".xml"))
            (junit ~spec ~name ~took:(Unix.gettimeofday () -. t0) outcome)
      in
      match f () with
      | () -> finish Passed
      | exception e ->
          let bt = Printexc.get_raw_backtrace () in
          finish
            (if is_skip e then Skipped
             else
               Failed
                 {
                   kind = Printexc.exn_slot_name e;
                   message = Printexc.to_string e;
                   trace = Printexc.raw_backtrace_to_string bt;
                 });
          Printexc.raise_with_backtrace e bt )

(* ---- the binary ---- *)

let binary_status dir status =
  if mine () then begin
    let d = Filename.concat dir ".ci-binaries" in
    (try Sys.mkdir d 0o755 with Sys_error _ -> ());
    write_atomic (Filename.concat d binary) (status ^ "\n")
  end

(* A rerun runs the binaries it names and no other: any other exits here,
   before it writes anything. *)
let exit_unless_rerun () =
  match set rerun_env with Some names when not (List.mem binary (words names)) -> exit 0 | _ -> ()

let run suite tests =
  exit_unless_rerun ();
  let lists = Option.map parse_lists (set lists_env) in
  let slow_only = set slow_env = Some "1" in
  let selected = select ~lists ~slow_only tests in
  let dir = set reports_env in
  if selected = [] then begin
    Printf.printf "%s: every case is left out by the lists this build runs with\n" binary;
    exit 0
  end;
  let tests =
    List.map
      (fun (group, cases) ->
        ( group,
          List.map
            (fun (spec, case) -> match dir with Some dir -> wrap ~dir ~spec case | None -> case)
            cases ))
      selected
  in
  Option.iter (fun dir -> binary_status dir "running") dir;
  match Alcotest.run ~and_exit:false ~log_dir:(log_dir ()) suite tests with
  | () ->
      Option.iter (fun dir -> binary_status dir "passed") dir;
      exit 0
  | exception Alcotest.Test_error ->
      Option.iter (fun dir -> binary_status dir "failed") dir;
      exit 1
