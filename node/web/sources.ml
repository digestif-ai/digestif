(* The sources a member may let their agent read, and the first step of the nightly note
   (design.md, The nightly note): code, not the agent, extracts a digest of the day from the chosen
   sources (commit subjects and session titles, never raw tool output or diffs), and a writer drafts
   the note from that digest alone. Sources never leave the machine; only what the note says does. *)

open Digestif_core

let home () = Option.value (Sys.getenv_opt "HOME") ~default:"."

(* Paths are shown with ~ for the home directory. *)
let tilde p =
  let h = home () in
  let n = String.length h in
  if n > 0 && String.length p >= n && String.sub p 0 n = h then
    "~" ^ String.sub p n (String.length p - n)
  else p

let untilde p =
  if String.length p >= 1 && p.[0] = '~' then
    home () ^ String.sub p 1 (String.length p - 1)
  else p

let is_dir p = try Sys.is_directory p with Sys_error _ -> false

let children dir =
  match Sys.readdir dir with
  | names ->
      Array.sort compare names;
      Array.to_list names
      |> List.filter (fun n -> n <> "" && n.[0] <> '.')
      |> List.map (Filename.concat dir)
  | exception Sys_error _ -> []

let git_roots = [ "code"; "src"; "projects"; "dev"; "Developer"; "work" ]
let max_repos = 40

(* Git repositories one level under the usual code directories. *)
let discover_repos () =
  List.concat_map (fun r -> children (Filename.concat (home ()) r)) git_roots
  |> List.filter (fun d -> is_dir (Filename.concat d ".git"))
  |> List.filteri (fun i _ -> i < max_repos)

let claude_projects () = Filename.concat (home ()) ".claude/projects"

let git_source paths : Store.source =
  {
    id = "git";
    kind = "git";
    label = "Git repositories";
    paths = List.map tilde paths;
    yields = [ "Commit subjects from the last day" ];
    selected = false;
  }

let claude_source paths : Store.source =
  {
    id = "claude-code";
    kind = "claude_code";
    label = "Claude Code sessions";
    paths = List.map tilde paths;
    yields = [ "Session titles from the last day" ];
    selected = false;
  }

(* A node whose sources were set by hand (the demo circle) never rediscovers them. *)
let k_fixed = "ui_sources_fixed"

(* What this machine offers. A member's choice survives a rediscovery for every id still offered. *)
let discover () =
  let claude =
    if is_dir (claude_projects ()) then [ claude_source [ claude_projects () ] ]
    else []
  in
  let repos = discover_repos () in
  claude @ if repos = [] then [] else [ git_source repos ]

let day = 86400.0

let lines s =
  String.split_on_char '\n' s
  |> List.map String.trim
  |> List.filter (fun l -> l <> "")

let git_subjects ~since repo =
  match
    Proc.run
      [|
        "git";
        "-C";
        repo;
        "log";
        "--no-merges";
        Printf.sprintf "--since=@%d" (int_of_float since);
        "--format=%s";
        "-n";
        "50";
      |]
  with
  | Ok { code = 0; stdout; _ } -> lines stdout
  | _ -> []

let rec jsonl_files dir =
  List.concat_map
    (fun p ->
      if is_dir p then jsonl_files p
      else if Filename.check_suffix p ".jsonl" then [ p ]
      else [])
    (children dir)

(* A session's title is the summary line Claude Code writes into its transcript. *)
let session_titles ~since dir =
  jsonl_files dir
  |> List.filter (fun p ->
      match Unix.stat p with
      | st -> st.st_mtime >= since
      | exception Unix.Unix_error _ -> false)
  |> List.concat_map (fun p ->
      match In_channel.with_open_bin p In_channel.input_all with
      | exception Sys_error _ -> []
      | content ->
          String.split_on_char '\n' content
          |> List.filter_map (fun l ->
              match Yojson.Safe.from_string l with
              | `Assoc f -> (
                  match
                    (List.assoc_opt "type" f, List.assoc_opt "summary" f)
                  with
                  | Some (`String "summary"), Some (`String s) -> Some s
                  | _ -> None)
              | _ -> None
              | exception _ -> None))

(* A command source (docs/behaviors.md, Command sources): the member's program, run as its paths
   with --since UNIX_SECONDS appended, one item per line of stdout. The node bounds what it takes:
   the run's time, the lines per source and each line's length. A failed run yields no lines and
   the reason, naming the source, for the run's tick. *)
let command_timeout = 30.0
let max_command_lines = 200
let max_line_chars = 1000

let clip l =
  if String.length l <= max_line_chars then l
  else String.sub l 0 (max_line_chars - 1) ^ "…"

let command_lines ?(timeout = command_timeout) ~since ~label argv =
  match argv with
  | [] -> Error (label ^ ": no program")
  | _ -> (
      let argv =
        Array.of_list (argv @ [ "--since"; string_of_int (int_of_float since) ])
      in
      match Proc.run ~timeout argv with
      | Ok { code = 0; stdout; _ } ->
          Ok
            (lines stdout
            |> List.filteri (fun i _ -> i < max_command_lines)
            |> List.map clip)
      | Ok { code; _ } -> Error (Printf.sprintf "%s exited %d" label code)
      | Error e -> Error (Printf.sprintf "%s: %s" label e))

(* The program must be named by its absolute path and be executable; arguments are free. *)
let check_program = function
  | [] | "" :: _ -> Error "Name the program."
  | p :: _ when Filename.is_relative (untilde p) ->
      Error "Name the program by its absolute path."
  | p :: _ -> (
      let p = untilde p in
      match Unix.access p [ Unix.X_OK ] with
      | () when not (is_dir p) -> Ok ()
      | () -> Error (p ^ " is a directory.")
      | exception Unix.Unix_error (e, _, _) ->
          Error (Printf.sprintf "%s: %s." p (Unix.error_message e)))

(* A command source's id: "command-" and the label's letters and digits, lowercased. *)
let command_id label =
  let b = Buffer.create 16 in
  String.iter
    (fun c ->
      match Char.lowercase_ascii c with
      | ('a' .. 'z' | '0' .. '9') as c -> Buffer.add_char b c
      | _ ->
          if Buffer.length b > 0 && Buffer.nth b (Buffer.length b - 1) <> '-'
          then Buffer.add_char b '-')
    label;
  let slug = Buffer.contents b in
  let slug =
    if slug <> "" && slug.[String.length slug - 1] = '-' then
      String.sub slug 0 (String.length slug - 1)
    else slug
  in
  "command-" ^ if slug = "" then "source" else slug

let dedupe l =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun x ->
      if Hashtbl.mem seen x then false
      else begin
        Hashtbl.add seen x ();
        true
      end)
    l

let max_lines = 500

(* The digest lines the writer is given, from the chosen sources, and why any command source gave
   none. *)
let extract_with_failures ?(now = Unix.gettimeofday ())
    (chosen : Store.source list) =
  let since = now -. day in
  let failures = ref [] in
  let extracted =
    List.concat_map
      (fun (s : Store.source) ->
        let paths = List.map untilde s.paths in
        match s.kind with
        | "git" ->
            List.concat_map (git_subjects ~since) paths
            |> List.map (fun x -> "commit: " ^ x)
        | "claude_code" ->
            List.concat_map (session_titles ~since) paths
            |> List.map (fun x -> "session: " ^ x)
        | k when k = Store.k_command -> (
            match command_lines ~since ~label:s.label s.paths with
            | Ok l -> List.map (fun x -> s.label ^ ": " ^ x) l
            | Error e ->
                failures := e :: !failures;
                [])
        | _ -> [])
      chosen
    |> dedupe
    |> List.filteri (fun i _ -> i < max_lines)
  in
  (extracted, List.rev !failures)

let extract ?now chosen = fst (extract_with_failures ?now chosen)

(* The writer: a program run with no tools, given the digest lines on stdin, answering the note on
   stdout. DIGESTIF_WRITER names it for one process; `digestif writer set` (and `digestif service
   install`, from DIGESTIF_WRITER) records it in the node's config, which is all a node running as
   the service has. With none, the node drafts a plain note from the lines itself, so the preview
   always shows what would leave. *)
let plain_draft extracted =
  let items =
    List.filter_map
      (fun l ->
        match String.index_opt l ':' with
        | Some i ->
            Some (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
        | None -> Some l)
      extracted
  in
  let worked =
    match items with
    | [] -> "nothing the chosen sources recorded today."
    | _ -> String.concat "; " (List.filteri (fun i _ -> i < 6) items) ^ "."
  in
  "Worked on: " ^ worked
  ^ "\nLearned: nothing written yet.\nStuck on: nothing yet."

let k_writer = "writer"

let writer (log : Log.t) =
  match Sys.getenv_opt "DIGESTIF_WRITER" with
  | Some w when String.trim w <> "" -> Some w
  | _ -> Log.get_config log k_writer

let set_writer (log : Log.t) path =
  Result.map
    (fun () -> Log.set_config log k_writer (untilde path))
    (check_program [ path ])

let unset_writer (log : Log.t) =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s k_writer ]

(* Runs the writer for [task] (DIGESTIF_WRITER_TASK: "note", or "brief"), lines on stdin. *)
let run_writer ~task w lines =
  match
    Proc.run
      ~env:[ "DIGESTIF_WRITER_TASK=" ^ task ]
      ~stdin:(String.concat "\n" lines ^ "\n")
      [| w |]
  with
  | Ok { code = 0; stdout; _ } when String.trim stdout <> "" ->
      Ok (String.trim stdout)
  | Ok { code; stderr; _ } ->
      Error
        (Printf.sprintf "the writer exited %d: %s" code (String.trim stderr))
  | Error e -> Error e

let write log extracted =
  match writer log with
  | Some w -> run_writer ~task:"note" w extracted
  | None -> Ok (plain_draft extracted)

(* A first brief for the member to edit (docs/behaviors.md, The writer): the writer drafts it from
   the member's card and the chosen sources' lines. With no writer there is no draft; the node
   never invents one. *)
let draft_brief log ~name ~agent_name extracted =
  match writer log with
  | None -> Error "No writer is set, so there is nothing to draft with."
  | Some w ->
      let card =
        (if name = "" then [] else [ "name: " ^ name ])
        @ if agent_name = "" then [] else [ "agent: " ^ agent_name ]
      in
      run_writer ~task:"brief" w (card @ extracted)
