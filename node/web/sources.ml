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
let claude_projects () = Filename.concat (home ()) ".claude/projects"

(* Claude Code names a project's directory under ~/.claude/projects after the project's path, every
   character but an ASCII letter or digit turned to '-'. It replaces per UTF-16 code unit (a
   JavaScript /[^a-zA-Z0-9]/g), so an accented letter is one dash and a character outside the Basic
   Multilingual Plane two, whatever its length in UTF-8; a byte that is not UTF-8 is one dash. The
   encoding loses which dash was a '/', so a name is decoded against the file system: from the
   root, each child directory whose encoded name begins the rest of the name is tried in turn. Only
   paths that exist come back. *)
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

(* How the judging of a project reads the file system (DIG-349). The rules are those of the
   behaviors reader (behaviors/src/sessions.ts, skipRoots, skipReason, MAX_JUDGED_ENTRIES, Budget).
   A project whose directory name is under a system temp root is skipped by its name. A decoding of
   a name never lists or enters a temp root. A path under one is judged by itself and its
   repository, and the walk above it is not made. A folder is listed one entry at a time, to at most
   [max_entries], with a clock of its own. The whole reading has one clock too. A folder over the
   cap, over its time, that cannot be opened or read, or one met after the reading's time ran out
   cannot be judged. That is not an answer of "no books". [Cannot_judge] is raised, the project is
   skipped for the run, no financial mark is written, and [gave_up] is told the folder and why. *)

(* Why a folder or a reading could not be judged. *)
type reason = Cap | Listing_time | Read_error | Permission | Reading_deadline

(* The folder and why. *)
exception Cannot_judge of string * reason

type judging = {
  temp_roots : string list; (* folders a decoding never enters *)
  max_entries : int; (* the most entries one listing reads *)
  max_streamed : int; (* the most entries a decoding streams from one folder *)
  listing_seconds : float; (* the time one listing may take *)
  reading_seconds : float; (* the time the whole reading may take *)
  deadline : float ref;
      (* when the reading ends, [infinity] until it begins. The ref is shared by every copy of a
         judging, so one judging value must never be reused across two readings *)
  clock : unit -> float; (* test hook *)
  opendir : string -> Unix.dir_handle; (* test hook *)
  readdir : Unix.dir_handle -> string; (* test hook *)
  on_listing : string -> unit; (* test hook, told each folder as it is opened *)
  gave_up : reason -> string -> unit;
      (* told once per folder, and once for the reading *)
  on_deadline : int -> unit;
      (* told how many projects a spent reading left unjudged *)
  unjudged : int ref;
      (* projects with sessions in the window that could not be judged *)
}

let max_judged_entries = 10_000

(* A decoding streams at most this many entries from one folder, whatever the listing cap, so a
   folder of millions cannot spend the reading. Past it the folder cannot be decoded. *)
let max_streamed_entries = 100_000

(* One listing may take this long. *)
let max_listing_seconds = 2.0

(* The behaviors reader has no number for judging alone: a source gets a third of the nightly's
   deadline. One reading of the projects directory here may judge for this long in all. *)
let max_reading_seconds = 300.0

let under_any p roots =
  List.exists
    (fun r ->
      let n = String.length r in
      p = r || (String.length p > n && String.sub p 0 n = r && p.[n] = '/'))
    roots

(* The folders the system keeps its temporary files in. A root that is the home directory or
   encloses it is no root at all, since every project would be under it (a TMPDIR set to the home
   directory, or a home under /var/folders). *)
let system_temp_roots () =
  let t = Filename.get_temp_dir_name () in
  let real p = try [ Unix.realpath p ] with Unix.Unix_error _ -> [] in
  let h = home () in
  let homes = h :: real h in
  [
    "/tmp";
    "/private/tmp";
    "/var/folders";
    "/private/var/folders";
    "/var/tmp";
    "/private/var/tmp";
    t;
  ]
  @ real t @ real "/tmp" @ real "/var/folders" @ real "/var/tmp"
  |> List.map (fun r ->
      let n = String.length r in
      if n > 1 && r.[n - 1] = '/' then String.sub r 0 (n - 1) else r)
  |> List.filter (fun r ->
      String.length r > 1
      && not (List.exists (fun x -> under_any x [ r ]) homes))
  |> List.sort_uniq compare

let reason_text = function
  | Cap -> "too many entries"
  | Listing_time -> "too slow to list"
  | Read_error -> "it could not be read"
  | Permission -> "permission denied"
  | Reading_deadline -> "the reading ran out of time"

let log_gave_up reason dir =
  match reason with
  | Reading_deadline ->
      Printf.eprintf
        "%s sources: the reading's time ran out at %s, so the projects after \
         it are skipped this run\n\
         %!"
        (Time_fmt.now ()) dir
  | _ ->
      Printf.eprintf
        "%s sources: could not judge %s (%s), so its project is skipped this run\n\
         %!"
        (Time_fmt.now ()) dir (reason_text reason)

let log_deadline n =
  Printf.eprintf
    "%s sources: the reading's time ran out, %d projects were not judged and \
     are skipped this run\n\
     %!"
    (Time_fmt.now ()) n

let default_judging () =
  {
    temp_roots = system_temp_roots ();
    max_entries = max_judged_entries;
    max_streamed = max_streamed_entries;
    listing_seconds = max_listing_seconds;
    reading_seconds = max_reading_seconds;
    deadline = ref infinity;
    clock = Unix.gettimeofday;
    opendir = Unix.opendir;
    readdir = Unix.readdir;
    on_listing = ignore;
    gave_up = log_gave_up;
    on_deadline = log_deadline;
    unjudged = ref 0;
  }

(* A reading's deadline is set once, when it first begins, and copies of a judging share it, so a
   reading made of many calls has one deadline. *)
let begun j =
  if !(j.deadline) = infinity then j.deadline := j.clock () +. j.reading_seconds;
  j

let reading_key = "gaveup:*reading*"

(* Whether the reading's time has run out for this memo. *)
let reading_spent memo = Hashtbl.mem memo reading_key

(* Every giving up goes through here: remembered in [memo] and told once, per folder, or once for
   the whole reading. It is never remembered as a verdict. *)
let give_up ~memo j ?(whole = false) ?key reason dir =
  let key =
    if whole then reading_key
    else match key with Some k -> k | None -> "gaveup:" ^ dir
  in
  if not (Hashtbl.mem memo key) then (
    Hashtbl.replace memo key true;
    Hashtbl.replace memo (key ^ "\000" ^ reason_text reason) true;
    j.gave_up reason dir);
  raise (Cannot_judge (dir, reason))

(* Why [key] was given up, as [give_up] remembered it. *)
let memo_reason memo key =
  match
    List.find_opt
      (fun r -> Hashtbl.mem memo (key ^ "\000" ^ reason_text r))
      [ Cap; Listing_time; Read_error; Permission; Reading_deadline ]
  with
  | Some r -> r
  | None -> Read_error

let check_reading ~memo j dir =
  if j.clock () >= !(j.deadline) then
    give_up ~memo j ~whole:true Reading_deadline dir

(* The clock of one listing, begun with it. Every hundredth call checks it and the reading's. *)
let ticker ~memo j dir =
  let t0 = j.clock () in
  let n = ref 0 in
  fun () ->
    if !n mod 100 = 0 then (
      check_reading ~memo j dir;
      if j.clock () -. t0 > j.listing_seconds then
        give_up ~memo j Listing_time dir);
    incr n

(* Whether [p] is a directory, as a judgement. A path that is not there (or has a file in the way)
   is not one. One that cannot be looked at (no permission) or fails otherwise cannot be judged,
   which is not the same as being gone. *)
let stat_dir ~memo j p =
  match Unix.stat p with
  | st -> st.st_kind = Unix.S_DIR
  | exception Unix.Unix_error ((ENOENT | ENOTDIR | ELOOP | ENAMETOOLONG), _, _)
    ->
      false
  | exception Unix.Unix_error ((EACCES | EPERM), _, _) ->
      give_up ~memo j Permission p
  | exception Unix.Unix_error _ -> give_up ~memo j Read_error p

(* Whether a path is gone: there is nothing, or a file, where a directory was. A path that cannot
   be looked at is not gone. *)
let path_gone p =
  match Unix.stat p with
  | st -> st.st_kind <> Unix.S_DIR
  | exception Unix.Unix_error ((ENOENT | ENOTDIR | ELOOP | ENAMETOOLONG), _, _)
    ->
      true
  | exception Unix.Unix_error _ -> false

(* Whether the file [p] is there, as a judgement: the verdict mark. Absent is ENOENT or ENOTDIR.
   One that cannot be looked at (no permission), a symlink loop or any other failure cannot be
   judged, and is never taken for absent. *)
let stat_exists ~memo j p =
  match Unix.stat p with
  | _ -> true
  | exception Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> false
  | exception Unix.Unix_error ((EACCES | EPERM), _, _) ->
      give_up ~memo j Permission p
  | exception Unix.Unix_error _ -> give_up ~memo j Read_error p

(* Opens [dir] and runs [f] on it, closing it whatever happens. A folder that is not there is
   [absent]. One that refuses to open (no permission, as without Full Disk Access) or fails
   otherwise cannot be judged, which is not the same as having nothing in it. *)
let with_dir ~memo j dir ~absent f =
  match j.opendir dir with
  | exception Unix.Unix_error ((ENOENT | ENOTDIR | ELOOP | ENAMETOOLONG), _, _)
    ->
      absent
  | exception Unix.Unix_error ((EACCES | EPERM), _, _) ->
      Hashtbl.replace memo ("refused:" ^ dir) true;
      give_up ~memo j Permission dir
  | exception Unix.Unix_error _ ->
      Hashtbl.replace memo ("refused:" ^ dir) true;
      give_up ~memo j Read_error dir
  | h ->
      Fun.protect
        ~finally:(fun () -> try Unix.closedir h with _ -> ())
        (fun () ->
          j.on_listing dir;
          f h)

(* The entries of [dir], read one at a time. A folder that is not there has none. More than
   [max_entries] entries, too long, a folder that cannot be opened or an error part way raises
   [Cannot_judge]. *)
let read_entries ~memo j dir =
  if Hashtbl.mem memo ("gaveup:" ^ dir) then
    raise (Cannot_judge (dir, memo_reason memo ("gaveup:" ^ dir)));
  check_reading ~memo j dir;
  with_dir ~memo j dir ~absent:[] (fun h ->
      let tick = ticker ~memo j dir in
      let rec go n acc =
        match j.readdir h with
        | exception End_of_file -> acc
        | exception Unix.Unix_error _ -> give_up ~memo j Read_error dir
        | "." | ".." -> go n acc
        | name ->
            if n >= j.max_entries then give_up ~memo j Cap dir;
            tick ();
            go (n + 1) (name :: acc)
      in
      go 0 [])

(* The visible children of [dir] with their paths, sorted. *)
let judged_children ~memo j dir =
  read_entries ~memo j dir
  |> List.filter (fun n -> n <> "" && n.[0] <> '.')
  |> List.sort compare
  |> List.map (Filename.concat dir)

let names_under name e =
  let n = String.length e in
  name = e
  || (String.length name > n && String.sub name 0 n = e && name.[n] = '-')

(* Whether a project directory is not the member's, by its name alone: it names a path under a temp
   root. The encoded name cannot tell /tmp/x from /tmp-x, so a name that also reads as a path under
   a folder beside the root whose name starts with the root's (/tmp-scratch beside /tmp) is that
   folder's and is read. The folders beside a root are listed like any other, within the cap. If
   they cannot be, the root has no look-alikes and every name under it is skipped: a reading that
   cannot tell must not read a temp project. Nothing under a skipped root is opened
   (behaviors/src/sessions.ts, skipReason). *)
let skipped_by_name ~memo j =
  let roots =
    List.map
      (fun root ->
        let encoded = encode_segment root in
        let parent = Filename.dirname root in
        let siblings =
          try read_entries ~memo j parent with Cannot_judge _ -> []
        in
        ( encoded,
          List.filter_map
            (fun n ->
              let e = encode_segment (Filename.concat parent n) in
              if
                e <> encoded
                && String.length e > String.length encoded
                && names_under e encoded
              then Some e
              else None)
            siblings ))
      j.temp_roots
  in
  fun name ->
    List.exists
      (fun (e, rivals) ->
        names_under name e && not (List.exists (names_under name) rivals))
      roots

(* The children of [dir] whose encoded names can begin [rest], with those names, sorted. Only a
   prefix of [rest] that ends where it does or before a '-' can be a child's encoded name, so the
   folder is streamed and only those children kept, whatever its size. It cannot be judged when the
   matches pass the listing cap or the folder streams past [max_streamed]. The ceiling is
   remembered per folder, so no later name streams it again, the matches' cap per name. Read once per
   folder and rest through [cache]. *)
let prefix_children ~memo j cache dir rest =
  let key = dir ^ "\000" ^ rest in
  match Hashtbl.find_opt cache key with
  | Some names -> names
  | None ->
      (* Only the decoding's own give-ups count here. A listing that judging gave up on is
         streamed all the same. *)
      let ceiling = "streamed:" ^ dir and too_many = "matches:" ^ key in
      if Hashtbl.mem memo ceiling then
        raise (Cannot_judge (dir, memo_reason memo ceiling));
      if Hashtbl.mem memo too_many then
        raise (Cannot_judge (dir, memo_reason memo too_many));
      (* A folder that refused to open in this run is not opened again. *)
      if Hashtbl.mem memo ("refused:" ^ dir) then
        raise (Cannot_judge (dir, memo_reason memo ("gaveup:" ^ dir)));
      check_reading ~memo j dir;
      let len = String.length rest in
      let wanted = Hashtbl.create 8 in
      for k = 1 to len do
        if k = len || rest.[k] = '-' then
          Hashtbl.replace wanted (String.sub rest 0 k) ()
      done;
      let names =
        with_dir ~memo j dir ~absent:[] (fun h ->
            let rec go n matches acc =
              match j.readdir h with
              | exception End_of_file -> acc
              | exception Unix.Unix_error _ ->
                  give_up ~memo j ~key:ceiling Read_error dir
              | "." | ".." -> go n matches acc
              | name ->
                  if n mod 1000 = 0 then check_reading ~memo j dir;
                  if n >= j.max_streamed then
                    give_up ~memo j ~key:ceiling Cap dir;
                  let e = encode_segment name in
                  if Hashtbl.mem wanted e then (
                    if matches >= j.max_entries then
                      give_up ~memo j ~key:too_many Cap dir;
                    go (n + 1) (matches + 1) ((name, e) :: acc))
                  else go (n + 1) matches acc
            in
            go 0 0 [] |> List.sort compare)
      in
      Hashtbl.add cache key names;
      names

(* The paths a project directory's name can decode to that exist, and why each branch that was given
   up was ([] when none was). It is a lookup, not a judgement: each level streams only the children that
   can match ([prefix_children]), so a folder of any size decodes, and a temp root is never listed
   or entered. A branch that cannot be judged does not end the others, but the paths found are then
   only some of the project's. *)
let decode_judged ?(root = "/") ?(cache = Hashtbl.create 64)
    ?(memo = Hashtbl.create 8) ?(judging = default_judging ()) name =
  let j = judging in
  (* The judging's temp roots, and from the real root the system's own as well. One that holds the
     decoding's own root is not one to keep out of. *)
  let no_go =
    (if root = "/" then j.temp_roots @ system_temp_roots () else j.temp_roots)
    |> List.filter (fun r -> not (under_any root [ r ]))
  in
  let rec go dir rest =
    check_reading ~memo j dir;
    let r = String.length rest in
    let partial = ref [] in
    let found =
      List.concat_map
        (fun (child, e) ->
          let n = String.length e in
          let path = Filename.concat dir child in
          if n = 0 || under_any path no_go then []
          else
            match
              if stat_dir ~memo j path then
                if n = r then ([ path ], [])
                else go path (String.sub rest (n + 1) (r - n - 1))
              else ([], [])
            with
            | paths, why ->
                partial := !partial @ why;
                paths
            | exception Cannot_judge (_, why) ->
                partial := !partial @ [ why ];
                [])
        (prefix_children ~memo j cache dir rest)
    in
    (found, !partial)
  in
  if String.length name > 1 && name.[0] = '-' then
    go root (String.sub name 1 (String.length name - 1))
  else ([], [])

(* The paths a name decodes to. [Cannot_judge] is raised only when a branch was given up and no
   branch found a path. *)
let decode_project_dir ?root ?cache ?memo ?judging name =
  match decode_judged ?root ?cache ?memo ?judging name with
  | [], why :: _ -> raise (Cannot_judge (name, why))
  | paths, _ -> paths

let is_repo d = is_dir (Filename.concat d ".git")

(* The file kinds of personal finance and accounting: plain-text ledgers (Beancount, Ledger,
   hledger), bank and card exports (OFX, QFX, QIF, QBO) and the books of desktop accounting
   programs (GnuCash, KMyMoney, Quicken, QuickBooks, Microsoft Money). *)
let financial_record_suffixes =
  [
    ".beancount";
    ".bean";
    ".ledger";
    ".hledger";
    ".ofx";
    ".qfx";
    ".qif";
    ".qbo";
    ".gnucash";
    ".kmy";
    ".qdf";
    ".qbw";
    ".mny";
  ]

(* Whether a directory holds financial records: one of those files at its top level, or one level
   below. The always-on rule (behaviors/prompts/always-on.md) keeps a person's money out of the
   circle, so discovery never proposes a repository that holds their books. A member who wants one
   read anyway can still choose it by path. behaviors/src/sessions.ts carries the same list and test
   for its own reading of the projects directory. *)
let is_financial_file f =
  let l = String.lowercase_ascii f in
  List.exists (Filename.check_suffix l) financial_record_suffixes

(* Whether [f] holds of any of [l]. One that cannot be judged is remembered and the rest are still
   tried, so a folder with books in it is found beside one that is too big. The first that could
   not be judged is raised only when none held, since an answer of "no books" would be a guess
   (behaviors/src/sessions.ts, holdsFinancialRecords). *)
let exists_judged f l =
  let failed = ref None in
  let hit =
    List.exists
      (fun x ->
        try f x
        with Cannot_judge _ as e ->
          if !failed = None then failed := Some e;
          false)
      l
  in
  if hit then true else match !failed with Some e -> raise e | None -> false

let holds_records ~memo j dir =
  let top = judged_children ~memo j dir in
  List.exists is_financial_file top
  || exists_judged
       (fun d ->
         check_reading ~memo j dir;
         stat_dir ~memo j d
         && List.exists is_financial_file (judged_children ~memo j d))
       top

(* Whether [dir] holds financial records, for discovery and the machine scan, which judge no
   project. It raises [Cannot_judge] for a folder that cannot be judged, and that is not an answer
   of "no books". A reading that judges many folders passes one [judging] and [memo], so they share
   one deadline. *)
let holds_financial_records_exn ?(judging = default_judging ())
    ?(memo = Hashtbl.create 8) dir =
  holds_records ~memo (begun judging) dir

(* The same, for the callers that only offer or hide a repository: one that cannot be judged counts
   as holding records, so it is never offered. *)
let holds_financial_records ?judging ?memo dir =
  try holds_financial_records_exn ?judging ?memo dir
  with Cannot_judge _ -> true

(* Git repositories one level under the usual code directories, then the repositories Claude Code
   has worked in, from its project directories' names. The cost of reading them is bounded in
   [git_subjects], which skips a repository whose HEAD has not moved in the window, and by the
   digest's line cap, never by dropping repositories by name. The one repository never proposed is
   one that holds financial records. *)
let code_dirs () =
  List.concat_map (fun r -> children (Filename.concat (home ()) r)) git_roots

let discover_repos ?(root = "/") () =
  let judging = begun (default_judging ()) in
  let memo = Hashtbl.create 8 in
  let left = ref 0 in
  let worked_in =
    let cache = Hashtbl.create 64 in
    List.map Filename.basename (children (claude_projects ()))
    |> List.concat_map (fun n ->
        try decode_project_dir ~root ~cache ~memo ~judging n
        with Cannot_judge _ ->
          if reading_spent memo then incr left;
          [])
  in
  let found =
    dedupe (code_dirs () @ worked_in)
    |> List.filter (fun d ->
        is_repo d && not (holds_financial_records ~judging ~memo d))
  in
  if !left > 0 then judging.on_deadline !left;
  found

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

(* What this machine offers, given the clones discovery found ([discover_repos]). A member's choice
   survives a rediscovery for every id still offered. *)
let offered repos =
  let claude =
    if is_dir (claude_projects ()) then [ claude_source [ claude_projects () ] ]
    else []
  in
  claude @ if repos = [] then [] else [ git_source repos ]

let discover () = offered (discover_repos ())
let day = 86400.0

let lines s =
  String.split_on_char '\n' s
  |> List.map String.trim
  |> List.filter (fun l -> l <> "")

(* Whether [repo]'s HEAD may hold a commit made since [since]. Every commit, merge, pull or checkout
   that moves HEAD appends to .git/logs/HEAD, so a reflog last written before the window rules the
   repository out without running git. With no reflog to read, git is asked. *)
let head_moved_since ~since repo =
  match Unix.stat (Filename.concat repo ".git/logs/HEAD") with
  | st -> st.st_mtime >= since
  | exception Unix.Unix_error _ -> true

let git_subjects ~since repo =
  if not (head_moved_since ~since repo) then []
  else
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

(* The directory each of a project's transcripts was started in: the cwd on its first record that
   carries one. Claude Code records it on every message, so it names the project's path exactly
   where decoding the directory's name cannot: a path since removed or moved, or one whose name
   Claude Code truncated. Only a transcript's first lines are read. *)
let transcript_cwd p =
  match In_channel.open_bin p with
  | exception Sys_error _ -> None
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close ic)
        (fun () ->
          let rec line n =
            if n = 0 then None
            else
              match In_channel.input_line ic with
              | None -> None
              | Some l -> (
                  match Yojson.Safe.from_string l with
                  | `Assoc f -> (
                      match List.assoc_opt "cwd" f with
                      | Some (`String c) when not (Filename.is_relative c) ->
                          Some c
                      | _ -> line (n - 1))
                  | _ -> line (n - 1)
                  | exception _ -> line (n - 1))
          in
          line 50)

(* Words that make a folder's name read as finance, matched against the name's runs of letters and
   digits, case aside: ~/finance, ~/Personal Finances, ~/tax-returns. *)
let finance_words =
  [
    "accounting";
    "accounts";
    "bank";
    "banking";
    "beancount";
    "bookkeeping";
    "books";
    "budget";
    "budgets";
    "finance";
    "finances";
    "financial";
    "gnucash";
    "hledger";
    "ledger";
    "ledgers";
    "money";
    "quicken";
    "quickbooks";
    "tax";
    "taxes";
  ]

let reads_as_finance name =
  String.lowercase_ascii name
  |> String.map (function ('a' .. 'z' | '0' .. '9') as c -> c | _ -> ' ')
  |> String.split_on_char ' '
  |> List.exists (fun w -> List.mem w finance_words)

(* Whether a folder enclosing a project holds financial records in a subfolder of its own that is
   not a git repository: a dated folder of books (~/finance/2025) beside the folder a session was
   started in. A repository's records are judged by the repository rule, so a code fixture never
   drops the sessions of its neighbours. Read once per folder per listing, through [memo]. *)
let books_one_level_down ~memo ~j dir =
  match Hashtbl.find_opt memo dir with
  | Some v -> v
  | None ->
      let v =
        exists_judged
          (fun d ->
            check_reading ~memo j dir;
            stat_dir ~memo j d
            && (not (Sys.file_exists (Filename.concat d ".git")))
            && List.exists is_financial_file (judged_children ~memo j d))
          (judged_children ~memo j dir)
      in
      Hashtbl.replace memo dir v;
      v

(* Whether a folder enclosing a project holds a financial record at its top level, read once per
   folder per listing through [memo], since every project beside it (thousands in an agent factory's
   ~/ai) is enclosed by it too and would otherwise list it again (ISS-65357). *)
let top_holds_records ~memo ~j dir =
  let key = "top:" ^ dir in
  match Hashtbl.find_opt memo key with
  | Some v -> v
  | None ->
      let v = List.exists is_financial_file (judged_children ~memo j dir) in
      Hashtbl.replace memo key v;
      v

(* Whether a project's path [p] can be seen to hold financial records: p itself, or the repository
   around it, holds them (holds_financial_records), or a folder enclosing it does. The enclosing
   folders are those strictly between p and the home directory (the root, for a path outside home).
   Each is tested at its top level. One outside the repository around p is also tested one level
   down (books_one_level_down), so ~/finance/tools is caught by ~/finance/2025/main.beancount; one
   directly under home only when its name reads as finance, since ~/code or ~/Downloads holding a
   folder with an export in it must not drop every session under it. A path that no longer exists
   is judged by the folders around it that still do. A path under a temp root is judged by itself
   and its repository only, and the walk above it is not made. A folder that cannot be judged, or
   a reading out of time, raises [Cannot_judge] (DIG-349). *)
let financial_path ?(judging = default_judging ()) ~memo p =
  let j = judging in
  check_reading ~memo j p;
  (* A project named for a temp root itself holds none, without listing the root. *)
  if List.mem p j.temp_roots then false
  else
    let boundary =
      let h = home () in
      let n = String.length h in
      if n > 1 && String.length p > n && String.sub p 0 n = h && p.[n] = '/'
      then h
      else "/"
    in
    let rec enclosing_repo d =
      if Sys.file_exists (Filename.concat d ".git") then Some d
      else
        let up = Filename.dirname d in
        if up = d then None else enclosing_repo up
    in
    let repo = enclosing_repo p in
    let in_repo d =
      match repo with
      | None -> false
      | Some r ->
          let n = String.length r in
          d = r || (String.length d > n && String.sub d 0 n = r && d.[n] = '/')
    in
    let holds d = holds_records ~memo j d in
    let rec enclosing_ledger d =
      let up = Filename.dirname d in
      up <> d && up <> boundary
      && (not (under_any up j.temp_roots))
      &&
      (check_reading ~memo j up;
       top_holds_records ~memo ~j up
       || (not (in_repo up))
          && (Filename.dirname up <> boundary
             || reads_as_finance (Filename.basename up))
          && books_one_level_down ~memo ~j up
       || enclosing_ledger up)
    in
    (stat_dir ~memo j p && holds p)
    || Option.fold ~none:false ~some:holds repo
    || ((not (under_any p j.temp_roots)) && enclosing_ledger p)

(* The verdict a project directory's last reading left: a file of this name inside the project
   directory, beside its transcripts, written when a path of the project was seen to hold financial
   records. Both readers of the projects directory read and write it (behaviors/src/sessions.ts,
   FINANCIAL_MARK), so a project whose books were removed or moved since keeps being skipped by
   either. It holds one line saying so and nothing of the project's. *)
let financial_mark = ".digestif-financial"

(* A mark that cannot be looked at is neither written over nor removed. *)
let remember_financial ~memo j dir =
  let mark = Filename.concat dir financial_mark in
  if try not (stat_exists ~memo j mark) with Cannot_judge _ -> false then
    try
      Out_channel.with_open_bin mark (fun oc ->
          output_string oc
            "Digestif: this project held financial records when last seen, so \
             its sessions are not read.\n")
    with Sys_error _ -> ()

let forget_financial dir =
  try Sys.remove (Filename.concat dir financial_mark) with Sys_error _ -> ()

(* The paths a project directory's name decodes to, and whether the decoding was given up in part
   (some paths found, a branch not) or whole (none found, a branch not). *)
type decoding = Decoded | Part_given_up of reason list | Given_up

let decoded ~root ~cache ~memo ~judging dir =
  match decode_judged ~root ~cache ~memo ~judging (Filename.basename dir) with
  | [], _ :: _ -> ([], Given_up)
  | (paths, _ :: _) as r -> (paths, Part_given_up (snd r))
  | paths, [] -> (paths, Decoded)
  | exception Cannot_judge _ -> ([], Given_up)

(* Every path judged, one that cannot be judged ([Cannot_judge]) set aside: whether one was seen to
   hold financial records, and whether any was set aside, counting [decode_gave_up] (DIG-349).
   Books seen on one path are a verdict whatever another path did. *)
let judge_paths ~judging ~memo ~decode_gave_up paths =
  List.fold_left
    (fun (financial, gave_up) p ->
      if financial then (true, gave_up)
      else
        match financial_path ~judging ~memo p with
        | f -> (f, gave_up)
        | exception Cannot_judge _ -> (false, true))
    (false, decode_gave_up) paths

(* What judging a project came to. [Unjudged] is not [Clean]: the project is skipped for the run
   and nothing is recorded about it. *)
type verdict = Financial | Clean | Unjudged

(* Judges the project directory [dir] that holds a session of a financial project. Any path its
   name can decode to, or any directory its [transcripts] were started in, can be seen to hold
   financial records, or its last reading found that ([financial_mark]) and one of those paths is
   gone, or none is left to look at. Ambiguity fails closed. A financial verdict is remembered. A
   project whose every path is there and holds none is [Clean], and forgets its mark. With neither
   a decoded path nor a recorded one, and no verdict, it is [Clean].

   A path that cannot be judged, or a name that cannot be decoded (in part, when no transcript
   names a path either), and no books seen on another path, is [Unjudged], and the mark is neither written nor forgotten. The paths the transcripts
   name that judge clean do not stand in for a decoding that gave up. That is the rule of the
   behaviors reader (behaviors/src/sessions.ts, financialProject, anyFinancialPath). A project the
   mark already skips with a path gone stays [Financial], without being reported as unjudged. *)
let financial_project ?judging ~root ~cache ~memo dir transcripts =
  let judging = begun (Option.value judging ~default:(default_judging ())) in
  let from_name, decoding = decoded ~root ~cache ~memo ~judging dir in
  let cwds = List.filter_map transcript_cwd transcripts in
  (* A decoding given up in part leaves the paths found. A branch that was too big to list may be
     covered by the transcripts' own paths, as in the TypeScript reader. One that could not be read
     (permission, a failure, time) never is, whatever the transcripts say. With no transcript path
     the project is not judged. *)
  let decode_gave_up =
    match decoding with
    | Decoded -> false
    | Given_up -> true
    | Part_given_up why -> cwds = [] || List.exists (fun r -> r <> Cap) why
  in
  let paths = from_name @ cwds |> dedupe in
  match judge_paths ~judging ~memo ~decode_gave_up paths with
  | true, _ ->
      remember_financial ~memo judging dir;
      Financial
  | false, gave_up -> (
      match stat_exists ~memo judging (Filename.concat dir financial_mark) with
      | exception Cannot_judge _ -> Unjudged
      | marked ->
          let a_path_is_gone = List.exists path_gone paths in
          if gave_up then
            if marked && paths <> [] && a_path_is_gone then Financial
            else Unjudged
          else if not marked then Clean
          else if paths <> [] && not a_path_is_gone then (
            forget_financial dir;
            Clean)
          else Financial)

(* A project directory with no transcript in the window is not read, but its verdict is recorded
   while its path can still be seen, so a session started there later is skipped even when the
   books are gone by the time it is read. It is judged by the paths its name decodes to, and a
   verdict is only ever set here. A path that cannot be judged writes nothing. *)
let note_financial ?judging ~root ~cache ~memo dir =
  let judging = begun (Option.value judging ~default:(default_judging ())) in
  match stat_exists ~memo judging (Filename.concat dir financial_mark) with
  | exception Cannot_judge _ -> Unjudged
  | true -> Financial
  | false -> (
      let paths, decoding = decoded ~root ~cache ~memo ~judging dir in
      let decode_gave_up = decoding <> Decoded in
      match judge_paths ~judging ~memo ~decode_gave_up paths with
      | true, _ ->
          remember_financial ~memo judging dir;
          Financial
      | false, true -> Unjudged
      | false, false -> Clean)

(* The transcripts under a chosen path: its own top-level transcripts when it is a project
   directory, chosen by the member whatever it holds, else those of each project directory one
   level below it (~/.claude/projects) that is not a financial project. Only a transcript modified
   since [since] is listed, and a project is judged by those alone. The projects with transcripts in
   the window are judged first and the idle ones after, each with its verdict recorded
   ([note_financial]), so projects that are stale cannot use up the reading's time before the
   active ones are judged. The reading has one deadline. A caller that reads several paths passes
   one begun [judging]. The behaviors reader (behaviors/src/sessions.ts, sessionFiles) lists the
   same files. *)
let session_files ?(root = "/") ?(since = 0.) ?judging dir =
  let recent ps =
    List.filter
      (fun p ->
        match Unix.stat p with
        | st -> st.st_mtime >= since
        | exception Unix.Unix_error _ -> false)
      ps
  in
  let judging = Option.value judging ~default:(default_judging ()) in
  match jsonl_files dir with
  | [] ->
      (* The reading's time starts here, with its first project directory, not before. *)
      let judging = begun judging in
      let cache = Hashtbl.create 64 in
      let memo = Hashtbl.create 64 in
      let skipped = skipped_by_name ~memo judging in
      let projects =
        children dir |> List.filter is_dir
        |> List.filter (fun p -> not (skipped (Filename.basename p)))
        |> List.map (fun p -> (p, recent (jsonl_files p)))
      in
      let active = List.filter (fun (_, ts) -> ts <> []) projects in
      let idle = List.filter (fun (_, ts) -> ts = []) projects in
      (* The projects left unjudged once the reading's time ran out. *)
      let left = ref 0 in
      let files =
        List.concat_map
          (fun (p, ts) ->
            match financial_project ~judging ~root ~cache ~memo p ts with
            | Clean -> ts
            | Financial -> []
            | Unjudged ->
                incr judging.unjudged;
                if reading_spent memo then incr left;
                [])
          active
      in
      List.iter
        (fun (p, _) ->
          match note_financial ~judging ~root ~cache ~memo p with
          | Unjudged -> if reading_spent memo then incr left
          | Financial | Clean -> ())
        idle;
      if !left > 0 then judging.on_deadline !left;
      files
  | own -> recent own

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

(* How much of a transcript is read for its title. Claude Code records the aiTitle on a session's
   records from its first ones, and an older transcript's summary line is at its top, so the title is
   in a transcript's head; one of the last day can run to tens of megabytes, which is tool output. *)
let max_title_bytes = 1_048_576

(* The first [max_bytes] of a transcript, cut back to its last whole line. A file no longer than
   that is read whole. *)
let transcript_head ?(max_bytes = max_title_bytes) p =
  match In_channel.open_bin p with
  | exception Sys_error _ -> None
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close ic)
        (fun () ->
          let buf = Bytes.create max_bytes in
          let rec fill n =
            if n >= max_bytes then n
            else
              match In_channel.input ic buf n (max_bytes - n) with
              | 0 -> n
              | k -> fill (n + k)
          in
          match fill 0 with
          | exception Sys_error _ -> None
          | n ->
              let s = Bytes.sub_string buf 0 n in
              if n < max_bytes then Some s
              else
                Some
                  (match String.rindex_opt s '\n' with
                  | Some i -> String.sub s 0 i
                  | None -> ""))

(* A session's title, for each transcript modified since [since]: the aiTitle Claude Code records
   on the session's records, else the summary line older transcripts carry, both read from the
   transcript's head ([transcript_head]), else the session's first prompt in [history] (the transcript's file name is its session id). Equal titles are kept
   once: a resumed session writes a new transcript under the same title. *)
let session_titles ?root ?(history = claude_history ()) ?judging ~since dir =
  let titled =
    session_files ?root ?judging ~since dir
    |> List.filter_map (fun p ->
        match transcript_head p with
        | None -> None
        | Some content ->
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

(* What setup shows for Claude Code sessions: the top-level directories they were started in, under
   the home directory (~/code), read from the names of the project directories and nothing else. *)
let session_directories ?(root = "/") () =
  let h = home () in
  let top p =
    let prefix = h ^ "/" in
    let n = String.length prefix in
    if String.length p > n && String.sub p 0 n = prefix then
      match String.split_on_char '/' (String.sub p n (String.length p - n)) with
      | first :: _ -> "~/" ^ first
      | [] -> tilde p
    else tilde p
  in
  let cache = Hashtbl.create 64 in
  let memo = Hashtbl.create 8 in
  let judging = begun (default_judging ()) in
  let left = ref 0 in
  let dirs =
    List.map Filename.basename (children (claude_projects ()))
    |> List.concat_map (fun n ->
        try decode_project_dir ~root ~cache ~memo ~judging n
        with Cannot_judge _ ->
          if reading_spent memo then incr left;
          [])
  in
  if !left > 0 then judging.on_deadline !left;
  List.map top dirs |> dedupe

(* A command source (docs/behaviors.md, Command sources): the member's program, run as its paths
   with --since and the window's start appended, an ISO 8601 date time with its offset, one item
   per line of stdout. The node bounds what it takes: the run's time, the lines per source and each
   line's length. A failed run yields no lines and the reason, naming the source, for the run's
   tick. *)
let command_timeout = 30.0
let max_command_lines = 200

(* One run of a command source: its lines, or the exit status and what it said on stderr. *)
let run_command ?(timeout = command_timeout) ~since argv =
  let argv =
    Array.of_list (argv @ [ "--since"; Time_fmt.of_unix_local since ])
  in
  match Proc.run ~timeout argv with
  | Ok { code = 0; stdout; _ } ->
      Ok
        (lines stdout
        |> List.filteri (fun i _ -> i < max_command_lines)
        |> List.map clip)
  | Ok { code; stderr; _ } -> Error (`Exited (code, stderr))
  | Error e -> Error (`Failed e)

let command_lines ?timeout ~since ~label argv =
  match argv with
  | [] -> Error (label ^ ": no program")
  | _ -> (
      match run_command ?timeout ~since argv with
      | Ok l -> Ok l
      | Error (`Exited (code, _)) ->
          Error (Printf.sprintf "%s exited %d" label code)
      | Error (`Failed e) -> Error (Printf.sprintf "%s: %s" label e))

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

(* A command source is tested when it is saved (docs/design.md, The setup chat and the first note):
   the app runs it with --since a day ago and hands over only a line count or the error, never the
   output, so the agent still reads nothing from a source until it is saved. *)
let tested ~run command =
  match check_program command with
  | Error e -> Error e
  | Ok () -> (
      let command =
        match command with p :: rest -> untilde p :: rest | [] -> []
      in
      match run command with
      | Ok x -> Ok x
      | Error (`Failed e) -> Error e
      | Error (`Exited (code, stderr)) ->
          let said =
            match lines stderr with [] -> "" | l :: _ -> clip l ^ " "
          in
          Error (Printf.sprintf "%s(exit %d)" said code))

let test_command ?(now = Unix.gettimeofday ()) ?timeout command =
  tested command ~run:(fun c ->
      Result.map List.length (run_command ?timeout ~since:(now -. day) c))

(* A program run as given, with nothing appended, for whether it works: the setup chat's test of a
   filing command (ISS-80140), which answers that it worked or the error and never the output. *)
let test_program ?(timeout = command_timeout) command =
  tested command ~run:(fun c ->
      match Proc.run ~timeout (Array.of_list c) with
      | Ok { code = 0; _ } -> Ok ()
      | Ok { code; stderr; _ } -> Error (`Exited (code, stderr))
      | Error e -> Error (`Failed e))

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

(* The failure line for [n] projects left unjudged: the first three distinct folders and why, so the
   member can grant access, move a huge folder or wait. [given_up] is newest first. *)
let unjudged_failure n given_up =
  let seen = dedupe (List.rev given_up) in
  let pairs =
    List.filteri (fun i _ -> i < 3) seen
    |> List.map (fun (d, r) ->
        Printf.sprintf "%s (%s)" (tilde d) (reason_text r))
  in
  Printf.sprintf "%d project%s not read: could not be judged%s" n
    (if n = 1 then "" else "s")
    (if pairs = [] then "" else ", " ^ String.concat ", " pairs)

(* The digest lines the writer is given, from the chosen sources, and why any command source gave
   none. *)
let extract_with_failures ?(now = Unix.gettimeofday ())
    (chosen : Store.source list) =
  let since = now -. day in
  let failures = ref [] in
  (* One deadline for the whole reading, however many paths the sources name. It begins with the
     first Claude Code project judged, so a slow git source does not use it up. Every failure to
     judge is kept, for the line that tells the member what to do. *)
  let given_up = ref [] in
  let judging =
    let j = default_judging () in
    {
      j with
      gave_up =
        (fun reason dir ->
          given_up := (dir, reason) :: !given_up;
          j.gave_up reason dir);
    }
  in
  let extracted =
    List.concat_map
      (fun (s : Store.source) ->
        let paths = List.map untilde s.paths in
        match s.kind with
        | "git" ->
            List.concat_map (git_subjects ~since) paths
            |> List.map (fun x -> "commit: " ^ x)
        | "claude_code" ->
            List.concat_map (session_titles ~judging ~since) paths
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
  let unjudged = !(judging.unjudged) in
  if unjudged > 0 then
    failures := unjudged_failure unjudged !given_up :: !failures;
  (extracted, List.rev !failures)

let extract ?now chosen = fst (extract_with_failures ?now chosen)

(* The writer: a program run with no tools, given the digest lines on stdin, answering on stdout.
   DIGESTIF_WRITER names it for one process; `digestif writer set` (and `digestif service install`,
   from DIGESTIF_WRITER) records it in the node's config, which is all a node running as the service
   has. *)
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

(* Runs the writer for [task] (DIGESTIF_WRITER_TASK), lines on stdin. *)
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
