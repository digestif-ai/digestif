(* Setup in the terminal: `digestif join <invite>` (which the hosted install script runs) and
   `digestif setup` (the way back in). docs/design.md, Install, is the contract.

   The order is what the machine needs, coding agents, phrase, join, service, start the agent. A
   keystore and an agent are required and the join spends the single-use invite, so both are checked
   first and nothing is spent until the machine and an agent are known to work. The join is signed
   and stored before it is posted (Join_store), so running either command again posts the same
   envelope and continues where setup stopped, and never spends the invite twice.

   Every effect comes in through [env], so a test drives the whole flow with a scripted terminal,
   fake agents and an in-process relay. *)

open Digestif_core

type env = {
  io : Terminal.io;
  macos : bool;
  exe : string;  (** the installed digestif, by its full path *)
  machine : unit -> Machine_check.line list;
  find_agents : unit -> Agents.t list;
  of_path : string -> (Agents.t, string) result;
  check_agent : Agents.t -> Agents.verdict;
  saved_agent : unit -> Agents.t option;
  save_agent : Agents.t -> unit;
  new_phrase : unit -> string;
  stored_join : unit -> (Join_store.t option, string) result;
  prepare : phrase:string -> (Join_store.t, string) result;
  post : Join_store.t -> (Invite_node.posted, string) result;
  install_service : unit -> (unit, string) result;
  start_chat : Agents.t -> (int, string) result;  (** the chat's exit status *)
}

(* Why setup stopped. Every stop before the join spends nothing, and says so. *)
type stop = string

let unspent = "Your invite is unspent: the same command works afterwards."
let ( let* ) = Result.bind

(* ---- what the machine needs ---- *)

let pad n s =
  if String.length s >= n then s ^ " "
  else s ^ String.make (n - String.length s) ' '

let machine env =
  env.io.say "What Digestif needs on this machine";
  let lines = env.machine () in
  List.iter
    (fun (l : Machine_check.line) ->
      env.io.say
        ("  " ^ pad 15 l.label ^ pad 17 l.what
        ^ if l.ok then l.detail else "does not work"))
    lines;
  match List.filter (fun (l : Machine_check.line) -> not l.ok) lines with
  | [] -> Ok ()
  | failed ->
      Error
        (String.concat "\n"
           (List.map (fun (l : Machine_check.line) -> l.detail) failed
           @ [ unspent ]))

(* ---- coding agents ---- *)

let cannot_limit =
  "Digestif cannot limit what this agent runs, so its limits are only what the \
   prompt asks."

let describe (a : Agents.t) = a.name ^ " (" ^ Agents.tilde a.path ^ ")"

(* A typed path, resolved and checked the same way as an agent setup found. *)
let typed_agent env typed =
  match env.of_path typed with
  | Error e -> Error e
  | Ok a -> (
      env.io.say ("  checking " ^ describe a ^ " ...");
      match env.check_agent a with
      | Works ->
          if not (Agents.limited a) then env.io.say cannot_limit;
          Ok a
      | Fails why -> Error (a.name ^ " " ^ why))

(* Asks for a path until one works, or the member presses Enter to stop. *)
let rec ask_path env prompt =
  match env.io.ask prompt with
  | None -> None
  | Some s when String.trim s = "" -> None
  | Some s -> (
      match typed_agent env s with
      | Ok a -> Some a
      | Error e -> ask_path env (e ^ ". Type the path to another agent:"))

let none_works failed =
  let sign_ins =
    List.filter_map
      (fun ((a : Agents.t), _) ->
        Option.map (fun s -> a.name ^ ": " ^ s) (Agents.sign_in a))
      failed
  in
  "No coding agent works on this machine. "
  ^ (match sign_ins with
    | [] -> Agents.install_line ^ "."
    | l -> Agents.install_line ^ ", or sign in (" ^ String.concat "; " l ^ ").")
  ^ "\n" ^ unspent

(* Every agent setup knows is checked; one that works is confirmed, several are offered, and the
   prompt always takes a path. *)
let choose_agent env =
  env.io.say "Coding agents on this machine";
  let found = env.find_agents () in
  let checked =
    List.map
      (fun a ->
        env.io.say ("  checking " ^ describe a ^ " ...");
        (a, env.check_agent a))
      found
  in
  let working =
    List.filter_map (function a, Agents.Works -> Some a | _ -> None) checked
  in
  let failed =
    List.filter_map
      (function a, Agents.Fails why -> Some (a, why) | _ -> None)
      checked
  in
  let width =
    List.fold_left
      (fun m (a : Agents.t) -> max m (String.length a.name))
      0 found
    + 2
  in
  List.iteri
    (fun i (a : Agents.t) ->
      env.io.say
        (Printf.sprintf "  %d  %s%s works, signed in" (i + 1) (pad width a.name)
           (pad 26 (Agents.tilde a.path))))
    working;
  List.iter
    (fun ((a : Agents.t), why) ->
      env.io.say
        (Printf.sprintf "  -  %s%s %s" (pad width a.name)
           (pad 26 (Agents.tilde a.path))
           why))
    failed;
  match working with
  | [] -> (
      env.io.say (none_works failed);
      match
        ask_path env "Type the path to another agent, or press Enter to stop."
      with
      | Some a -> Ok a
      | None -> Error "Stopped: no coding agent works on this machine.")
  | [ only ] ->
      let rec go prompt =
        match env.io.ask prompt with
        | None ->
            Error "Stopped before the recovery phrase; nothing has been spent."
        | Some s when String.trim s = "" -> Ok only
        | Some s -> (
            match typed_agent env s with
            | Ok a -> Ok a
            | Error e ->
                go
                  (e ^ ". Press Enter for " ^ only.name
                 ^ ", or type another path:"))
      in
      go
        ("Using " ^ only.name
       ^ ". Press Enter, or type the path to another agent.")
  | several ->
      let n = List.length several in
      let rec go prompt =
        match env.io.ask prompt with
        | None ->
            Error "Stopped before the recovery phrase; nothing has been spent."
        | Some s -> (
            let s = String.trim s in
            match int_of_string_opt s with
            | _ when s = "" -> Ok (List.hd several)
            | Some i when i >= 1 && i <= n -> Ok (List.nth several (i - 1))
            | Some _ ->
                go
                  (Printf.sprintf
                     "Type 1 to %d, or the path to another agent. [1]" n)
            | None -> (
                match typed_agent env s with
                | Ok a -> Ok a
                | Error e ->
                    go (e ^ ". Type a number, or the path to another agent. [1]")
                ))
      in
      go
        "Which should write your notes? Type a number, or the path to another \
         agent. [1]"

(* ---- the recovery phrase ---- *)

let rtrim s =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = ' ' do
    decr n
  done;
  String.sub s 0 !n

(* The words in four columns, numbered down each column. *)
let grid phrase =
  let words = Array.of_list (String.split_on_char ' ' phrase) in
  let n = Array.length words in
  let rows = (n + 3) / 4 in
  List.init rows (fun r ->
      rtrim
        (String.concat ""
           (List.filter_map
              (fun c ->
                let i = (c * rows) + r in
                if i < n then Some (Printf.sprintf "%4d %-9s" (i + 1) words.(i))
                else None)
              [ 0; 1; 2; 3 ])))

(* What is wrong with a pasted phrase, naming the first wrong word, or None when it matches. *)
let mismatch ~expected typed =
  let words s =
    String.split_on_char ' ' (Phrase.normalize s) |> List.filter (( <> ) "")
  in
  let e = Array.of_list (words expected) and t = Array.of_list (words typed) in
  let rec go i =
    if i >= Array.length e then
      if Array.length t > Array.length e then
        Some
          (Printf.sprintf "The phrase has %d words, not %d." (Array.length e)
             (Array.length t))
      else None
    else if i >= Array.length t then
      Some
        (if i = 0 then "Nothing was pasted."
         else Printf.sprintf "Word %d is missing." (i + 1))
    else if e.(i) <> t.(i) then
      Some (Printf.sprintf "Word %d is not %s." (i + 1) t.(i))
    else go (i + 1)
  in
  go 0

let phrase env =
  let p = env.new_phrase () in
  let io = env.io in
  io.say
    "Your recovery phrase. It is your account, and Digestif does not keep it.";
  io.say "You have not joined yet: closing this window now spends nothing.";
  List.iter io.say (grid p);
  io.say
    "Press c to copy it. Save it in a secrets manager, such as 1Password or \
     Bitwarden,";
  let copied =
    match io.key "rather than writing it down." with
    | Some ('c' | 'C') ->
        if io.copy p then (
          io.say "Copied to the clipboard.";
          true)
        else (
          io.say
            "The clipboard did not take it; select the words above instead.";
          false)
    | _ -> false
  in
  let rec confirm prompt =
    match io.secret prompt with
    | None -> Error "Stopped before the join; nothing has been spent."
    | Some typed -> (
        match mismatch ~expected:p typed with
        | None -> Ok ()
        | Some why -> confirm (why ^ " Paste it again:"))
  in
  let* () = confirm "Paste the phrase back from your secrets manager:" in
  if copied then ignore (io.copy "");
  io.say "Recovery phrase confirmed.";
  Ok p

(* ---- the join, the service and the chat ---- *)

let way_back env =
  "If this window closes, run " ^ Agents.tilde env.exe ^ " setup to continue."

let post env stored =
  match env.post stored with
  | Error e ->
      Error
        ("The join is signed and stored, but no relay took it yet: " ^ e ^ "\n"
       ^ way_back env)
  | Ok _ ->
      (match stored.Join_store.guest_name with
      | Some name -> env.io.say ("Joined the circle as " ^ name ^ ".")
      | None -> env.io.say "Joined the circle.");
      env.io.say (way_back env);
      Ok ()

let service env =
  let* () =
    Result.map_error
      (fun e -> "The service did not install: " ^ e ^ "\n" ^ way_back env)
      (env.install_service ())
  in
  env.io.say
    (if env.macos then
       "Service installed: a launchd agent, running now and at every login."
     else
       "Service installed: a systemd user unit, running now and at every \
        login. To keep it running while you are logged out: loginctl \
        enable-linger $USER");
  Ok ()

(* Start the chosen agent with the setup prompt; when the chat fails, ask for another agent. *)
let rec chat env agent =
  env.io.say ("Starting " ^ agent.Agents.name ^ " with the setup prompt ...");
  match env.start_chat agent with
  | Ok 0 -> Ok ()
  | failed ->
      env.io.say
        (match failed with
        | Ok code -> Printf.sprintf "%s stopped with exit %d." agent.name code
        | Error e -> agent.name ^ " did not start: " ^ e);
      let* next = choose_agent env in
      env.save_agent next;
      chat env next

(* After the join: post a stored join not yet posted, the service, then the chat. *)
let after_join env (stored : Join_store.t) ~agent =
  let* () = post env stored in
  let* agent =
    match agent with
    | Some a -> Ok a
    | None -> (
        match env.saved_agent () with
        | Some a -> Ok a
        | None ->
            let* a = choose_agent env in
            env.save_agent a;
            Ok a)
  in
  let* () = service env in
  chat env agent

(* `digestif join <invite>`: everything from the machine check, or the way back in when this machine
   already holds the join for this invite. [invite_key] is the invite's public key. *)
let join env ~invite_key =
  let* stored = env.stored_join () in
  match stored with
  | Some s when s.invite_key = invite_key -> after_join env s ~agent:None
  | Some _ ->
      Error
        ("This machine already holds a join for another invite.\n"
       ^ way_back env)
  | None ->
      let* () = machine env in
      let* agent = choose_agent env in
      let* phrase = phrase env in
      let* stored = env.prepare ~phrase in
      env.save_agent agent;
      after_join env stored ~agent:(Some agent)

(* `digestif setup`: continue where setup stopped. *)
let resume env =
  let* stored = env.stored_join () in
  match stored with
  | Some s -> after_join env s ~agent:None
  | None ->
      Error
        "This machine has not joined a circle yet. Run the install command \
         from your invite email."
