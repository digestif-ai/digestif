(* The coding agents setup can start in a chat, and the check each must pass before the recovery
   phrase is shown (docs/design.md, Install).

   Setup knows Claude Code and Codex: it finds them on PATH and in their usual install directories,
   and starts each with its own flags, so the promises hold in code (only setup's subcommands in the
   chat, no tools for a run that only answers). Any other program is a typed path. Digestif has no
   flags it can pass one, so it is called with the prompt as its one argument, and its limits are
   only what the prompt asks.

   The check is two runs, the same for every agent: it answers a one-line prompt, which shows it
   works and is signed in, and told to run `digestif setup check <token>` it runs it and the app sees
   the token, which shows it can call setup's subcommands. *)

open Digestif_core

type kind = Claude_code | Codex | Other

type t = {
  kind : kind;
  name : string;  (** "Claude Code", "Codex", or the program's file name *)
  path : string;  (** absolute *)
}

let known =
  [ (Claude_code, "Claude Code", "claude"); (Codex, "Codex", "codex") ]

let limited t = t.kind <> Other
let home () = Option.value (Sys.getenv_opt "HOME") ~default:""

let untilde p =
  if p = "~" then home ()
  else if String.length p >= 2 && String.sub p 0 2 = "~/" then
    Filename.concat (home ()) (String.sub p 2 (String.length p - 2))
  else p

(* A path shown to the member, with the home directory as ~. *)
let tilde p =
  let h = home () in
  let n = String.length h in
  if n > 0 && String.length p > n && String.sub p 0 n = h && p.[n] = '/' then
    "~" ^ String.sub p n (String.length p - n)
  else p

let executable p =
  try
    Unix.access p [ Unix.X_OK ];
    not (Sys.is_directory p)
  with Unix.Unix_error _ | Sys_error _ -> false

let real p = try Unix.realpath p with Unix.Unix_error _ -> p

(* Where each known agent is looked for beyond PATH: the directories their installers write to, which
   a non-login shell (curl | sh) may not have on PATH. *)
let usual_dirs () =
  List.map untilde
    [ "~/.local/bin"; "~/.claude/local"; "~/.npm-global/bin"; "~/.bun/bin" ]
  @ [ "/opt/homebrew/bin"; "/usr/local/bin"; "/usr/bin" ]

let path_dirs () =
  match Sys.getenv_opt "PATH" with
  | Some p -> List.filter (( <> ) "") (String.split_on_char ':' p)
  | None -> []

let lookup ?(dirs = path_dirs () @ usual_dirs ()) program =
  List.find_map
    (fun d ->
      let p = Filename.concat d program in
      if executable p then Some p else None)
    dirs

let kind_of_path p =
  let base = Filename.basename (real p) and named = Filename.basename p in
  match
    List.find_opt
      (fun (_, _, program) -> program = base || program = named)
      known
  with
  | Some (k, name, _) -> (k, name)
  | None -> (Other, named)

(* Every known agent installed on this machine, in the order of [known]. *)
let find ?dirs () =
  List.filter_map
    (fun (kind, name, program) ->
      Option.map (fun path -> { kind; name; path }) (lookup ?dirs program))
    known

(* A path the member typed: ~ expanded, a bare name looked up on PATH, and it must be a program. A
   known agent's path is that agent, flags and all. *)
let of_path ?dirs typed =
  let typed = String.trim typed in
  let p =
    if typed = "" then None
    else if String.contains typed '/' then
      let p = untilde typed in
      let p =
        if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p
      in
      if executable p then Some p else None
    else lookup ?dirs typed
  in
  match p with
  | None -> Error (Printf.sprintf "%s is not a program on this machine" typed)
  | Some path ->
      let kind, name = kind_of_path path in
      Ok { kind; name; path }

(* The run that only answers: no tools at all. *)
let answer_argv t ~prompt =
  match t.kind with
  | Claude_code -> [| t.path; "-p"; "--tools="; prompt |]
  | Codex ->
      [|
        t.path;
        "exec";
        "--skip-git-repo-check";
        "--sandbox";
        "read-only";
        prompt;
      |]
  | Other -> [| t.path; prompt |]

(* A word as a shell reads it: bare when it holds nothing a shell treats specially, so the command an
   agent is told to run matches its permission rule character for character. *)
let shell_word s =
  if
    s <> ""
    && String.for_all
         (function
           | 'a' .. 'z'
           | 'A' .. 'Z'
           | '0' .. '9'
           | '/' | '.' | '_' | '-' | '+' | ':' | '@' | '~' ->
               true
           | _ -> false)
         s
  then s
  else Filename.quote s

(* The command a check run is told to run, exactly. *)
let check_command ~exe ~dir ~token =
  Printf.sprintf "%s setup check %s --data-dir %s" (shell_word exe) token
    (shell_word dir)

(* The run that must call one setup subcommand. Claude Code may run that command and nothing else;
   Codex runs it in a sandbox whose only writable directory is the node's. *)
let check_argv t ~prompt ~exe ~dir =
  match t.kind with
  | Claude_code ->
      [|
        t.path;
        "-p";
        "--tools=Bash";
        "--allowedTools";
        Printf.sprintf "Bash(%s setup check:*)" (shell_word exe);
        "--permission-mode";
        "dontAsk";
        prompt;
      |]
  | Codex ->
      [|
        t.path;
        "exec";
        "--skip-git-repo-check";
        "--sandbox";
        "workspace-write";
        "--cd";
        dir;
        prompt;
      |]
  | Other -> [| t.path; prompt |]

(* The setup chat, interactive: setup's own subcommands only. Claude Code is held to them by its
   permission rules; Codex runs commands in a sandbox writing only the node's directory and asks the
   member before any command it does not trust. *)
let chat_argv t ~prompt ~exe ~dir =
  match t.kind with
  | Claude_code ->
      [|
        t.path;
        "--tools=Bash";
        "--allowedTools";
        Printf.sprintf "Bash(%s setup:*)" (shell_word exe);
        "--permission-mode";
        "dontAsk";
        prompt;
      |]
  | Codex ->
      [|
        t.path;
        "--sandbox";
        "workspace-write";
        "--ask-for-approval";
        "untrusted";
        "--cd";
        dir;
        prompt;
      |]
  | Other -> [| t.path; prompt |]

let answer_prompt = "Reply with the single word ready and nothing else."

let check_prompt command =
  "Run this shell command exactly once, then reply with what it printed and \
   nothing else:\n" ^ command

(* What to do when a known agent does not answer: sign in, the one command for it. *)
let sign_in t =
  match t.kind with
  | Claude_code -> Some "run claude and sign in with /login"
  | Codex -> Some "run codex login"
  | Other -> None

let install_line =
  "Install Claude Code (https://claude.com/claude-code) or Codex \
   (https://developers.openai.com/codex)"

type verdict =
  | Works
  | Fails of string
      (** what it lacks, in a phrase: "does not answer: ...", "did not run
          digestif setup check" *)

let first_line s =
  let s = String.trim s in
  let s =
    match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s
  in
  if String.length s > 160 then String.sub s 0 157 ^ "..." else s

(* The token file `digestif setup check` writes, in the node's data directory. *)
let token_file dir = Filename.concat dir "setup-check"

let read_token dir =
  try
    Some
      (String.trim
         (In_channel.with_open_bin (token_file dir) In_channel.input_all))
  with Sys_error _ -> None

let write_token dir token =
  try
    Node.mkdir_p dir;
    Out_channel.with_open_bin (token_file dir) (fun oc ->
        output_string oc token);
    Ok ()
  with Sys_error e -> Error e

let token_shape t =
  String.length t >= 8
  && String.for_all (function 'a' .. 'z' | '0' .. '9' -> true | _ -> false) t

(* The answer is the word alone, give or take case, quotes and a full stop: a program that echoes the
   prompt back has not answered it. *)
let answered_ready out =
  let w =
    String.lowercase_ascii (String.trim out)
    |> String.to_seq
    |> Seq.filter (function '.' | '`' | '*' | '"' | '\'' -> false | _ -> true)
    |> String.of_seq
  in
  w = "ready"

type runner = string array -> (Proc.result, string) result

let default_run ~timeout : runner = fun argv -> Proc.run ~timeout argv

(* Both runs. [run] is how a program is run (a test passes a fake); [dir] is the node's data
   directory, where `digestif setup check` leaves the token. *)
let check ?(run = default_run ~timeout:180.0) ~exe ~dir t =
  let lacks what out = Fails (what ^ ": " ^ first_line out) in
  match run (answer_argv t ~prompt:answer_prompt) with
  | Error e -> lacks "does not run" e
  | Ok { code; stdout; stderr } when code <> 0 ->
      lacks
        (Printf.sprintf "does not answer (exit %d)" code)
        (if String.trim stderr <> "" then stderr else stdout)
  | Ok { stdout; _ } when not (answered_ready stdout) ->
      lacks "answered something else" stdout
  | Ok _ -> (
      let token = String.lowercase_ascii (Hex.encode (Crypto.random 8)) in
      (try Sys.remove (token_file dir) with Sys_error _ -> ());
      let command = check_command ~exe ~dir ~token in
      let r = run (check_argv t ~prompt:(check_prompt command) ~exe ~dir) in
      let seen = read_token dir = Some token in
      (try Sys.remove (token_file dir) with Sys_error _ -> ());
      match r with
      | _ when seen -> Works
      | Error e -> lacks "did not run digestif setup check" e
      | Ok { stdout; stderr; _ } ->
          lacks "did not run digestif setup check"
            (if String.trim stdout <> "" then stdout else stderr))
