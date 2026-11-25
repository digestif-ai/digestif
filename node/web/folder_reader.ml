(* The folders judging looks at, read where a call that blocks can be abandoned (DIG-483). A listing
   or a stat can block in the kernel for as long as the system likes (macOS asking whether this
   process may read a folder while nobody is at the screen), and no thread of this process can be
   ended to give it up. So each call is made by a child process, killed with SIGKILL at the call's
   limit and never waited for. behaviors/src/folders.ts does the same for the behaviors reader.

   The child is this program again, run with [flag]: the module serves and exits when it finds it, so
   whatever program links the readers can start one. One child serves one call at a time and is kept
   for the next. A message is eight hexadecimal digits, its length, then its bytes. *)

(* Claude Code's encoding of a path (Sources, which documents it). Here because a child keeps only the
   entries a decoding can use. *)
let encode_segment name =
  let b = Buffer.create (String.length name) in
  let rec go i =
    if i < String.length name then begin
      let d = String.get_utf_8_uchar name i in
      (match name.[i] with
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as c -> Buffer.add_char b c
      | _ ->
          Buffer.add_string b
            (if
               Uchar.utf_decode_is_valid d
               && Uchar.to_int (Uchar.utf_decode_uchar d) > 0xFFFF
             then "--"
             else "-"));
      go (i + Uchar.utf_decode_length d)
    end
  in
  go 0;
  Buffer.contents b

(* A prefix of [rest] that ends where it does or before a '-' can be a child's encoded name. *)
type wanted = { rest : string; max_matches : int }

type call =
  | List of { dir : string; max : int; wanted : wanted option }
      (** up to [max] entries of [dir], only those [wanted] when given *)
  | Stat of string

(* Where a listing stopped: at its end, at more than [max] entries, at more than [max_matches] of them
   wanted, or at an error part way. *)
type stop = End | Over | Too_many | Broke

type answer =
  | Names of string list * stop
  | Found of { dir : bool }
  | Absent  (** ENOENT, or ENOTDIR for a file in the way *)
  | Refused  (** EACCES or EPERM *)
  | Failed
  | Timed_out of { started : bool }
      (** past the limit; [started] when the first entry was read, so the folder
          is long, not blocked *)

let failure = function
  | Unix.ENOENT | ENOTDIR -> Absent
  | EACCES | EPERM -> Refused
  | _ -> Failed

let list ~opendir ~readdir ~started ~dir ~max ~wanted =
  match opendir dir with
  | exception Unix.Unix_error (e, _, _) -> failure e
  | h ->
      let keeps =
        match wanted with
        | None -> fun _ -> true
        | Some { rest; _ } ->
            let len = String.length rest in
            let names = Hashtbl.create 8 in
            for k = 1 to len do
              if k = len || rest.[k] = '-' then
                Hashtbl.replace names (String.sub rest 0 k) ()
            done;
            fun name -> Hashtbl.mem names (encode_segment name)
      in
      let max_matches =
        match wanted with Some w -> w.max_matches | None -> max_int
      in
      let first = ref true in
      let rec go n matches acc =
        match readdir h with
        | exception End_of_file -> Names (acc, End)
        (* A refusal at the first read is the folder's, as at its open (Folder_access). *)
        | exception Unix.Unix_error ((EACCES | EPERM), _, _) when !first ->
            Refused
        | exception Unix.Unix_error _ -> Names (acc, Broke)
        | name ->
            first := false;
            if n = 0 && matches = 0 then started ();
            if name = "." || name = ".." then go n matches acc
            else if n >= max then Names (acc, Over)
            else if not (keeps name) then go (n + 1) matches acc
            else if matches >= max_matches then Names (acc, Too_many)
            else go (n + 1) (matches + 1) (name :: acc)
      in
      Fun.protect
        ~finally:(fun () -> try Unix.closedir h with _ -> ())
        (fun () -> go 0 0 [])

(* The call made here, in this process. *)
let perform ?(opendir = Unix.opendir) ?(readdir = Unix.readdir)
    ?(started = ignore) = function
  | List { dir; max; wanted } ->
      list ~opendir ~readdir ~started ~dir ~max ~wanted
  | Stat p -> (
      match Unix.stat p with
      | st -> Found { dir = st.st_kind = Unix.S_DIR }
      | exception Unix.Unix_error (e, _, _) -> failure e)

(* The messages. A path and an entry hold no NUL, so one parts their fields. *)
let of_call = function
  | Stat p -> "S\000" ^ p
  | List { dir; max; wanted } ->
      let rest, matches =
        match wanted with
        | Some w -> ("=" ^ w.rest, w.max_matches)
        | None -> ("", 0)
      in
      String.concat "\000"
        [ "L"; string_of_int max; string_of_int matches; rest; dir ]

let to_call s =
  match String.split_on_char '\000' s with
  | [ "S"; p ] -> Some (Stat p)
  | [ "L"; max; matches; rest; dir ] ->
      let wanted =
        if rest = "" then None
        else
          Some
            {
              rest = String.sub rest 1 (String.length rest - 1);
              max_matches = int_of_string matches;
            }
      in
      Some (List { dir; max = int_of_string max; wanted })
  | _ -> None

let stops = [ (End, 'e'); (Over, 'o'); (Too_many, 'm'); (Broke, 'b') ]

let of_answer = function
  | Names (names, stop) ->
      String.concat "\000"
        (Printf.sprintf "N%c" (List.assoc stop stops) :: names)
  | Found { dir } -> if dir then "D" else "P"
  | Absent -> "A"
  | Refused -> "R"
  | Failed -> "F"
  | Timed_out _ -> assert false

let to_answer s =
  match s with
  | "D" -> Found { dir = true }
  | "P" -> Found { dir = false }
  | "A" -> Absent
  | "R" -> Refused
  | _ -> (
      match String.split_on_char '\000' s with
      | head :: names when String.length head = 2 && head.[0] = 'N' -> (
          match List.find_opt (fun (_, c) -> c = head.[1]) stops with
          | Some (stop, _) -> Names (names, stop)
          | None -> Failed)
      | _ -> Failed)

(* Said once by a child, before any call: it has started. And during a listing, at its first entry. *)
let ready = "!"
let begun = "+"
let header = 8

let write_message fd s =
  let b = Bytes.of_string (Printf.sprintf "%08x%s" (String.length s) s) in
  let rec go off =
    if off < Bytes.length b then
      match Unix.write fd b off (Bytes.length b - off) with
      | n -> go (off + n)
      | exception Unix.Unix_error (EINTR, _, _) -> go off
  in
  go 0

(* The other end is gone, or its time has run out. *)
exception Gone
exception Late

(* The next message on [fd], each wait for more of it at most until [deadline]. *)
let read_message ~deadline fd =
  let read n =
    let b = Bytes.create n in
    let rec go off =
      if off < n then
        let wait = deadline -. Unix.gettimeofday () in
        if wait <= 0. then raise Late
        else
          match Unix.select [ fd ] [] [] wait with
          | exception Unix.Unix_error (EINTR, _, _) -> go off
          | [], _, _ -> raise Late
          | _ -> (
              match Unix.read fd b off (n - off) with
              | 0 -> raise Gone
              | k -> go (off + k)
              | exception Unix.Unix_error (EINTR, _, _) -> go off)
    in
    (try go 0 with Unix.Unix_error _ -> raise Gone);
    Bytes.to_string b
  in
  match int_of_string_opt ("0x" ^ read header) with
  | Some n -> read n
  | None -> raise Gone

(* How long a child with nothing to do stays, and how long one is kept for the next call: less, so the
   one a call is sent to is never about to leave. *)
let idle_seconds = 10.
let kept_seconds = 5.

(* The child's whole life: one answer a call, until it is let go of or left idle. *)
let serve ?opendir ?readdir () =
  let out = Unix.stdout in
  let rec go () =
    match
      read_message ~deadline:(Unix.gettimeofday () +. idle_seconds) Unix.stdin
    with
    | exception (Gone | Late) -> ()
    | s ->
        let answer =
          match to_call s with
          | None -> Failed
          | Some c ->
              perform ?opendir ?readdir
                ~started:(fun () -> write_message out begun)
                c
        in
        write_message out (of_answer answer);
        go ()
  in
  try
    write_message out ready;
    go ()
  with Unix.Unix_error _ -> ()

let flag = "--digestif-folder-reader"

let () =
  if Array.length Sys.argv = 2 && Sys.argv.(1) = flag then begin
    serve ();
    Unix._exit 0
  end

type child = { pid : int; calls : Unix.file_descr; answers : Unix.file_descr }

(* The children of one program, idle ones kept for the next call. *)
type pool = {
  argv : string array;
  lock : Mutex.t;
  mutable idle : (child * float) list;  (** with when each was left idle *)
  mutable ended : int list;  (** killed or let go of, not reaped yet *)
}

let pool argv = { argv; lock = Mutex.create (); idle = []; ended = [] }

(* This program, by the path it was started from: a release installed meanwhile may not be it. *)
let own =
  let self = Sys.executable_name in
  pool [| (try Unix.realpath self with Unix.Unix_error _ -> self); flag |]

(* Lets go of a child. One that is killed is not waited for: it is reaped, if it has ended, when the
   next child is started. *)
let let_go ?(kill = false) pool c =
  (if kill then try Unix.kill c.pid Sys.sigkill with Unix.Unix_error _ -> ());
  List.iter
    (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())
    [ c.calls; c.answers ];
  Mutex.protect pool.lock (fun () -> pool.ended <- c.pid :: pool.ended)

let reap pool =
  Mutex.protect pool.lock (fun () ->
      pool.ended <-
        List.filter
          (fun pid ->
            match Unix.waitpid [ Unix.WNOHANG ] pid with
            | 0, _ -> true
            | _ -> false
            | exception Unix.Unix_error _ -> false)
          pool.ended)

(* How long a child may take to start: a busy machine's time, not a folder's, so no call's limit
   counts it. *)
let start_seconds = 10.

let start pool =
  reap pool;
  let calls_r, calls = Unix.pipe ~cloexec:true () in
  let answers, answers_w = Unix.pipe ~cloexec:true () in
  let null = Unix.openfile "/dev/null" [ O_WRONLY; O_CLOEXEC ] 0 in
  let spawned =
    Fun.protect
      ~finally:(fun () -> List.iter Unix.close [ calls_r; answers_w; null ])
      (fun () ->
        try
          Some
            (Unix.create_process pool.argv.(0) pool.argv calls_r answers_w null)
        with Unix.Unix_error _ -> None)
  in
  match spawned with
  | None ->
      List.iter Unix.close [ calls; answers ];
      raise Gone
  | Some pid -> (
      let c = { pid; calls; answers } in
      let deadline = Unix.gettimeofday () +. start_seconds in
      match read_message ~deadline answers with
      | s when s = ready -> c
      | _ | (exception (Gone | Late)) ->
          let_go ~kill:true pool c;
          raise Gone)

(* An idle child, or a new one. The bool says it served before. *)
let take pool =
  let now = Unix.gettimeofday () in
  let fresh, stale =
    Mutex.protect pool.lock (fun () ->
        let fresh, stale =
          List.partition (fun (_, at) -> now -. at < kept_seconds) pool.idle
        in
        match fresh with
        | [] ->
            pool.idle <- [];
            (None, stale)
        | (c, _) :: rest ->
            pool.idle <- rest;
            (Some c, stale))
  in
  List.iter (fun (c, _) -> let_go pool c) stale;
  match fresh with Some c -> (c, true) | None -> (start pool, false)

let keep pool c =
  Mutex.protect pool.lock (fun () ->
      pool.idle <- (c, Unix.gettimeofday ()) :: pool.idle)

(* A child that has gone is an error, not a signal that ends this process. *)
let send c s =
  let was = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigpipe was)
    (fun () ->
      try write_message c.calls s with Unix.Unix_error _ -> raise Gone)

(* The call made by a child of [pool], abandoned after [seconds]. A child that cannot be started or
   ends before it answers is [Failed]. *)
let rec ask pool ~seconds call =
  match take pool with
  | exception (Gone | Unix.Unix_error _) -> Failed
  | c, served -> (
      let deadline = Unix.gettimeofday () +. seconds in
      let started = ref false in
      let rec wait () =
        match read_message ~deadline c.answers with
        | s when s = begun ->
            started := true;
            wait ()
        | s -> to_answer s
      in
      match
        send c (of_call call);
        wait ()
      with
      | answer ->
          keep pool c;
          answer
      | exception Late ->
          let_go ~kill:true pool c;
          Timed_out { started = !started }
      | exception Gone ->
          let_go ~kill:true pool c;
          if served then ask pool ~seconds call else Failed)
