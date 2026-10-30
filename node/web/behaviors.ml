(* Behaviors (design.md, The agent is spawned, not embedded; docs/behaviors.md). The node holds no
   intelligence: the nightly note and the read loop are executables it spawns, the way a coding
   harness runs hooks. `digestif run` spawns the nightly behavior on the first pass after the
   member's fixed minute between 3:00 and 3:59 local, once per local date, so a laptop that was
   closed at that minute runs it when it next wakes; and the read behavior after a pass whose sync
   stored something new. A behavior is handed a JSON context on stdin (the data directory, the local
   API address with a session for it, the chosen sources and the local date), writes its output to a
   log beside the node's, and hands its results back through the local API or `digestif note` and
   `digestif tick`. The session ends when the behavior exits, and a behavior that outlives its
   deadline is ended. *)

open Digestif_core

type hook = Nightly | Read

let hooks = [ (Nightly, "nightly"); (Read, "read") ]
let hook_name h = List.assoc h hooks

let hook_of_name n =
  List.find_map (fun (h, s) -> if s = n then Some h else None) hooks

(* The version of the context a behavior is handed; docs/behaviors.md says what each one holds. *)
let interface = 0
let k_exe h = "behavior_" ^ hook_name h
let k_minute = "nightly_minute"
let k_last_date = "behavior_nightly_last_date"

(* How long a run may take before the node ends it, and how long after SIGTERM before SIGKILL. *)
let timeout = function Nightly -> 1800.0 | Read -> 900.0
let grace = 30.0
let executable (log : Log.t) h = Log.get_config log (k_exe h)

let set_executable (log : Log.t) h path =
  if Filename.is_relative path then
    Error "name the behavior by its absolute path"
  else
    match Unix.access path [ Unix.X_OK ] with
    | () when not (Sys.is_directory path) ->
        Ok (Log.set_config log (k_exe h) path)
    | () -> Error (path ^ " is a directory")
    | exception Unix.Unix_error (e, _, _) ->
        Error (Printf.sprintf "%s: %s" path (Unix.error_message e))

let unset_executable (log : Log.t) h =
  Log.exec log "DELETE FROM config WHERE key = ?" [ Log.s (k_exe h) ]

(* The member's fixed minute, chosen once: the first time anything asks for it. *)
let minute (log : Log.t) =
  match Option.bind (Log.get_config log k_minute) int_of_string_opt with
  | Some m when m >= 0 && m < 60 -> m
  | _ ->
      let m = Char.code (Crypto.random 1).[0] mod 60 in
      Log.set_config log k_minute (string_of_int m);
      m

let local_date = Digestif_daily.Daily_digest.local_date
let last_date (log : Log.t) = Log.get_config log k_last_date

(* Due at or after 3:<minute> local on a local date it has not run on. *)
let nightly_due_at ~minute ~last_date ~now =
  let g = Unix.localtime now in
  let after = g.tm_hour > 3 || (g.tm_hour = 3 && g.tm_min >= minute) in
  after && match last_date with Some d -> d < local_date now | None -> true

let chosen_sources (log : Log.t) =
  List.filter (fun (s : Store.source) -> s.selected) (Store.sources log)

(* A member who chose no sources reads and answers only, so there is no note to write. *)
let nightly_due (log : Log.t) ~now =
  executable log Nightly <> None
  && chosen_sources log <> []
  && nightly_due_at ~minute:(minute log) ~last_date:(last_date log) ~now

type api = { url : string; session : string }

let context ~hook ~dir ~digestif ~api ~sources ~now ~deadline : Yojson.Safe.t =
  let strings l = `List (List.map (fun s -> `String s) l) in
  `Assoc
    [
      ("interface", `Int interface);
      ("hook", `String (hook_name hook));
      ("local_date", `String (local_date now));
      ("data_dir", `String dir);
      ("digestif", `String digestif);
      ( "api",
        match api with
        | None -> `Null
        | Some a ->
            `Assoc
              [
                ("url", `String a.url);
                ( "headers",
                  `Assoc
                    [
                      ("Cookie", `String (Server.cookie_name ^ "=" ^ a.session));
                      ("Digestif-Local", `String "1");
                    ] );
              ] );
      ( "sources",
        `List
          (List.map
             (fun (s : Store.source) ->
               `Assoc
                 [
                   ("id", `String s.id);
                   ("kind", `String s.kind);
                   ("label", `String s.label);
                   ("paths", strings (List.map Sources.untilde s.paths));
                   ("yields", strings s.yields);
                 ])
             sources) );
      ("deadline", `String (Time_fmt.of_unix deadline));
    ]

type running = {
  hook : hook;
  pid : int;
  started : float;
  deadline : float;
  session : string option;
  mutable terminated : float option;
}

type t = {
  node : Node.t;
  digestif : string;
  api_url : string option;
  mutable running : running list;
}

let create ~digestif ?api_url node = { node; digestif; api_url; running = [] }
let is_running t h = List.exists (fun r -> r.hook = h) t.running
let dir t = Filename.concat t.node.dir "behaviors"
let log_path t h = Filename.concat (dir t) (hook_name h ^ ".log")

let environment t h =
  let ours = [ "DIGESTIF_HOME"; "DIGESTIF_HOOK" ] in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun kv ->
        match String.index_opt kv '=' with
        | Some i -> not (List.mem (String.sub kv 0 i) ours)
        | None -> true)
  in
  Array.of_list
    (inherited
    @ [ "DIGESTIF_HOME=" ^ t.node.dir; "DIGESTIF_HOOK=" ^ hook_name h ])

let say t h fmt =
  Printf.ksprintf
    (fun line ->
      Out_channel.with_open_gen [ Open_append; Open_creat; Open_wronly ]
        0o600 (log_path t h) (fun oc ->
          Printf.fprintf oc "%s digestif: %s\n" (Time_fmt.now ()) line))
    fmt

(* Spawn [h]: its context on stdin through a file unlinked once the child holds it, stdout and stderr
   appended to behaviors/<hook>.log. *)
let spawn ?(now = Unix.gettimeofday ()) t h =
  match executable t.node.log h with
  | None -> Error (hook_name h ^ ": no behavior is set")
  | Some _ when is_running t h -> Error (hook_name h ^ ": already running")
  | Some exe -> (
      Node.mkdir_p (dir t);
      let deadline = now +. timeout h in
      let session =
        Option.map (fun _ -> Store.new_session t.node.log) t.api_url
      in
      let api =
        match (t.api_url, session) with
        | Some url, Some session -> Some { url; session }
        | _ -> None
      in
      let ctx =
        context ~hook:h ~dir:t.node.dir ~digestif:t.digestif ~api
          ~sources:(chosen_sources t.node.log)
          ~now ~deadline
      in
      let ctx_path = Filename.concat (dir t) (hook_name h ^ ".context.json") in
      let end_session () = Option.iter (Store.end_session t.node.log) session in
      try
        Out_channel.with_open_gen [ Open_trunc; Open_creat; Open_wronly ]
          0o600 ctx_path (fun oc -> Yojson.Safe.to_channel oc ctx);
        let stdin = Unix.openfile ctx_path [ O_RDONLY; O_CLOEXEC ] 0 in
        Sys.remove ctx_path;
        let out =
          Unix.openfile (log_path t h)
            [ O_WRONLY; O_APPEND; O_CREAT; O_CLOEXEC ]
            0o600
        in
        say t h "spawn %s" exe;
        let pid =
          Fun.protect
            ~finally:(fun () -> List.iter Unix.close [ stdin; out ])
            (fun () ->
              Unix.create_process_env exe [| exe |] (environment t h) stdin out
                out)
        in
        t.running <-
          { hook = h; pid; started = now; deadline; session; terminated = None }
          :: t.running;
        if h = Nightly then
          Log.set_config t.node.log k_last_date (local_date now);
        Ok pid
      with
      | Unix.Unix_error (e, _, _) ->
          end_session ();
          (try Sys.remove ctx_path with Sys_error _ -> ());
          Error (Printf.sprintf "%s: %s" exe (Unix.error_message e))
      | Sys_error e ->
          end_session ();
          Error e)

type finished = { f_hook : hook; status : string; seconds : float }

(* OCaml's signal numbers are its own negative constants, so the two the node sends are named. *)
let signal_name s =
  if s = Sys.sigterm then "SIGTERM"
  else if s = Sys.sigkill then "SIGKILL"
  else Printf.sprintf "signal %d" s

let status_of = function
  | Unix.WEXITED c -> Printf.sprintf "exited %d" c
  | WSIGNALED s -> "killed by " ^ signal_name s
  | WSTOPPED s -> "stopped by " ^ signal_name s

(* Collect every behavior that exited, end its session, and end every one past its deadline. *)
let reap ?(now = Unix.gettimeofday ()) t =
  let finished, running =
    List.partition_map
      (fun r ->
        match Unix.waitpid [ WNOHANG ] r.pid with
        | 0, _ ->
            (match r.terminated with
            | None when now >= r.deadline ->
                say t r.hook "past its deadline; ending it";
                (try Unix.kill r.pid Sys.sigterm with Unix.Unix_error _ -> ());
                r.terminated <- Some now
            | Some at when now -. at >= grace -> (
                try Unix.kill r.pid Sys.sigkill with Unix.Unix_error _ -> ())
            | _ -> ());
            Right r
        | _, st -> Left (r, status_of st)
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Left (r, "gone")
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> Right r)
      t.running
  in
  t.running <- running;
  List.map
    (fun (r, status) ->
      Option.iter (Store.end_session t.node.log) r.session;
      say t r.hook "%s" status;
      { f_hook = r.hook; status; seconds = now -. r.started })
    finished

(* Wait for every running behavior, ending any past its deadline: for `digestif behavior run`. *)
let wait_all ?(clock = Unix.gettimeofday) t =
  let rec go acc =
    if t.running = [] then List.rev acc
    else begin
      let f = reap ~now:(clock ()) t in
      (if t.running <> [] then
         try Unix.sleepf 0.2 with Unix.Unix_error (Unix.EINTR, _, _) -> ());
      go (List.rev_append f acc)
    end
  in
  go []

(* What a pass of `digestif run` spawns: the nightly behavior when it is due, the read behavior when
   the sync stored something new. Each runs at most once at a time. *)
let after_pass ?(now = Unix.gettimeofday ()) t ~stored =
  let want =
    (if nightly_due t.node.log ~now && not (is_running t Nightly) then
       [ Nightly ]
     else [])
    @
    if
      stored > 0
      && executable t.node.log Read <> None
      && not (is_running t Read)
    then [ Read ]
    else []
  in
  List.map (fun h -> (h, spawn ~now t h)) want

(* The node is stopping: end every running behavior and its session. *)
let stop_all t =
  List.iter
    (fun r ->
      (try Unix.kill r.pid Sys.sigterm with Unix.Unix_error _ -> ());
      Option.iter (Store.end_session t.node.log) r.session;
      say t r.hook "the node is stopping; ended it")
    t.running;
  t.running <- []

let busy t = t.running <> []
