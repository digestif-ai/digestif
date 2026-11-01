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

let git_roots = [ "code"; "src"; "projects"; "dev"; "Developer"; "work" ]
let max_repos = 40
let claude_projects () = Filename.concat (home ()) ".claude/projects"

(* Claude Code names a project's directory under ~/.claude/projects after the project's path, every
   character but a letter or digit turned to '-'. That loses which dash was a '/', so a name is
   decoded against the file system: from the root, each child directory whose encoded name begins
   the rest of the name is tried in turn. Only paths that exist come back. *)
let encode_segment name =
  String.map
    (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as c -> c | _ -> '-')
    name

(* Each directory's entries with their encoded names, read once per discovery. *)
let all_children cache dir =
  match Hashtbl.find_opt cache dir with
  | Some names -> names
  | None ->
      let names =
        match Sys.readdir dir with
        | names ->
            Array.sort compare names;
            Array.to_list names |> List.map (fun c -> (c, encode_segment c))
        | exception Sys_error _ -> []
      in
      Hashtbl.add cache dir names;
      names

let decode_project_dir ?(root = "/") ?(cache = Hashtbl.create 64) name =
  let rec go dir rest from =
    let r = String.length rest - from in
    let begins e =
      let n = String.length e in
      let rec eq i = i = n || (rest.[from + i] = e.[i] && eq (i + 1)) in
      n > 0 && n <= r && eq 0
    in
    List.concat_map
      (fun (child, e) ->
        let n = String.length e in
        if not (begins e) then []
        else
          let path = Filename.concat dir child in
          if n = r then if is_dir path then [ path ] else []
          else if rest.[from + n] = '-' && is_dir path then
            go path rest (from + n + 1)
          else [])
      (all_children cache dir)
  in
  if String.length name > 1 && name.[0] = '-' then go root name 1 else []

let is_repo d = is_dir (Filename.concat d ".git")

(* Git repositories one level under the usual code directories, then the repositories Claude Code
   has worked in, from its project directories' names. *)
let discover_repos () =
  let fixed =
    List.concat_map (fun r -> children (Filename.concat (home ()) r)) git_roots
  in
  let worked_in =
    let cache = Hashtbl.create 64 in
    List.map Filename.basename (children (claude_projects ()))
    |> List.concat_map (decode_project_dir ~cache)
  in
  dedupe (fixed @ worked_in)
  |> List.filter is_repo
  |> List.filteri (fun i _ -> i < max_repos)

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

(* A directory's own top-level transcripts. Nothing below it is listed: a session's subagent and
   tool-result directories hold another agent's transcripts, not a session of the member's. *)
let jsonl_files dir =
  List.filter (fun p -> Filename.check_suffix p ".jsonl") (children dir)

(* The transcripts under a chosen path: its own top-level transcripts when it is a project
   directory, else those of each project directory one level below it (~/.claude/projects). The
   behaviors reader (behaviors/src/sessions.ts, sessionFiles) lists the same files. *)
let session_files dir =
  match jsonl_files dir with
  | [] -> List.concat_map jsonl_files (List.filter is_dir (children dir))
  | own -> own

(* An item is at most this many characters (a command source's line, a session's title). *)
let max_line_chars = 1000

let clip l =
  if String.length l <= max_line_chars then l
  else String.sub l 0 (max_line_chars - 1) ^ "…"

(* The first line of [content] that mentions the quoted [key] and for which [f], given the line's
   fields as a JSON object, answers. Only lines that mention the key are split out and parsed, so a
   long transcript costs one scan. *)
let first_mentioning key f content =
  let needle = Re.compile (Re.str (Printf.sprintf {|"%s"|} key)) in
  let len = String.length content in
  let rec from pos =
    match Re.exec_opt ~pos needle content with
    | None -> None
    | Some g -> (
        let at = Re.Group.start g 0 in
        let start =
          match String.rindex_from_opt content at '\n' with
          | Some i -> i + 1
          | None -> 0
        in
        let stop =
          Option.value (String.index_from_opt content at '\n') ~default:len
        in
        let answer =
          match
            Yojson.Safe.from_string (String.sub content start (stop - start))
          with
          | `Assoc fields -> f fields
          | _ -> None
          | exception _ -> None
        in
        match answer with
        | Some _ -> answer
        | None -> if stop >= len then None else from (stop + 1))
  in
  from 0

let non_empty = function
  | Some (`String v) when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

(* Only a record's own top-level key counts: a field of the same name nested in a tool result or
   a message belongs to that, not to the session. *)
let ai_title =
  first_mentioning "aiTitle" (fun f -> non_empty (List.assoc_opt "aiTitle" f))

let summary_line =
  first_mentioning "summary" (fun f ->
      match List.assoc_opt "type" f with
      | Some (`String "summary") -> non_empty (List.assoc_opt "summary" f)
      | _ -> None)

(* The whole text on one line, whitespace collapsed. *)
let one_line s =
  String.split_on_char '\n' s
  |> List.concat_map (String.split_on_char '\t')
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (fun w -> w <> "")
  |> String.concat " "

(* The first prompt of each of [ids] in Claude Code's prompt history (one JSON object per line,
   with display and sessionId), on one line. A slash command is not a prompt. *)
let first_prompts history ids =
  let found = Hashtbl.create 16 in
  (match ids with
  | [] -> ()
  | _ -> (
      let wanted = Re.compile (Re.alt (List.map Re.str ids)) in
      match In_channel.with_open_bin history In_channel.input_all with
      | exception Sys_error _ -> ()
      | content ->
          String.split_on_char '\n' content
          |> List.iter (fun l ->
              if Re.execp wanted l then
                match Yojson.Safe.from_string l with
                | `Assoc f -> (
                    match
                      (List.assoc_opt "sessionId" f, List.assoc_opt "display" f)
                    with
                    | Some (`String id), Some (`String d)
                      when List.mem id ids && not (Hashtbl.mem found id) ->
                        let d = one_line d in
                        if d <> "" && d.[0] <> '/' then Hashtbl.add found id d
                    | _ -> ())
                | _ -> ()
                | exception _ -> ())));
  found

let claude_history () = Filename.concat (home ()) ".claude/history.jsonl"

(* A session's title, for each transcript modified since [since]: the aiTitle Claude Code records
   on the session's records, else the summary line older transcripts carry, else the session's
   first prompt in [history] (the transcript's file name is its session id). Equal titles are kept
   once: a resumed session writes a new transcript under the same title. *)
let session_titles ?(history = claude_history ()) ~since dir =
  let titled =
    session_files dir
    |> List.filter (fun p ->
        match Unix.stat p with
        | st -> st.st_mtime >= since
        | exception Unix.Unix_error _ -> false)
    |> List.filter_map (fun p ->
        match In_channel.with_open_bin p In_channel.input_all with
        | exception Sys_error _ -> None
        | content ->
            let title =
              match ai_title content with
              | Some t -> Some t
              | None -> summary_line content
            in
            Some (Filename.remove_extension (Filename.basename p), title))
  in
  let untitled =
    List.filter_map (fun (id, t) -> if t = None then Some id else None) titled
  in
  let prompts = first_prompts history untitled in
  List.filter_map
    (fun (id, t) ->
      match t with Some t -> Some t | None -> Hashtbl.find_opt prompts id)
    titled
  |> List.map (fun t -> clip (one_line t))
  |> dedupe

(* A command source (docs/behaviors.md, Command sources): the member's program, run as its paths
   with --since UNIX_SECONDS appended, one item per line of stdout. The node bounds what it takes:
   the run's time, the lines per source and each line's length. A failed run yields no lines and
   the reason, naming the source, for the run's tick. *)
let command_timeout = 30.0
let max_command_lines = 200

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
