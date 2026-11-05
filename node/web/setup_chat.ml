(* `digestif setup`'s own subcommands, the only commands the setup chat may run (docs/design.md, The
   setup chat and the first note). Each confirmed item is saved at once, so a chat closed halfway
   resumes at the first item not done. Until the sources are saved the agent reads only names and
   paths. Every function answers a line for the agent to pass on, or the reason it refused. *)

open Digestif_core

let ( let* ) = Result.bind

let replace_all ~sub ~by s =
  let n = String.length sub in
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i > String.length s - n then
      Buffer.add_string b (String.sub s i (String.length s - i))
    else if String.sub s i n = sub then (
      Buffer.add_string b by;
      go (i + n))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(* behaviors/prompts/setup.md, naming this binary and carrying the always-on rule from its one
   file. *)
let prompt ~text ~rule ~digestif =
  replace_all ~sub:"{{digestif}}" ~by:digestif text
  |> replace_all ~sub:"{{always_on_rules}}" ~by:(String.trim rule)

let refresh (n : Node.t) = Machine_scan.ensure ~now:(Unix.gettimeofday ()) n

let status_string (n : Node.t) key =
  match
    (Api.handle n ~meth:"GET" ~path:[ "status" ] ~query:[] ~body:None).body
  with
  | Some (`Assoc f) -> (
      match List.assoc_opt key f with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let strings l = `List (List.map (fun s -> `String s) l)

module R = Store.Repositories

(* The clones grouped by organization, each organization with its choice and each repository with
   its status, as the Repositories page holds them (Store.Repositories). *)
let organizations_json (n : Node.t) =
  `List
    (List.map
       (fun (o : R.organization) ->
         `Assoc
           [
             ("id", `String o.o_id);
             ("name", `String o.o_name);
             ("choice", `String o.choice);
             ( "repositories",
               `List
                 (List.map
                    (fun (r : R.repository) ->
                      `Assoc
                        [
                          ("id", `String r.r_id);
                          ("name", `String r.r_name);
                          ("status", `String r.status);
                        ])
                    (R.repositories n.log ~organization_id:o.o_id ~limit:max_int
                       ~offset:0)) );
           ])
       (R.organizations n.log))

let authors_json (n : Node.t) =
  Machine_scan.propose_authors ~now:(Unix.gettimeofday ()) n.log;
  `List
    (List.map
       (fun (a : R.author) ->
         `Assoc
           ([ ("email", `String a.email) ]
           @ (match a.a_name with
             | Some s -> [ ("name", `String s) ]
             | None -> [])
           @ [ ("label", `String a.label) ]))
       (R.authors n.log))

(* What setup found, and the first item not done. Names and paths, never a source's contents. Once
   the machine is scanned, git is its repositories by organization rather than its clones' paths,
   and the commit authors whose commits it reads. *)
let found (n : Node.t) ~invited_name : Yojson.Safe.t =
  refresh n;
  let scanned = Store.config n.log R.k_scanned <> None in
  let opt = function Some s -> `String s | None -> `Null in
  `Assoc
    ([
       ( "next",
         match Store.Setup.next n.log with
         | Some item -> `String (Store.Setup.item_name item)
         | None -> `String "done" );
       ( "names",
         `Assoc
           [
             ( "member_name",
               opt
                 (match status_string n "member_name" with
                 | Some "" | None -> invited_name
                 | some -> some) );
             ("agent_name", opt (status_string n "agent_name"));
           ] );
       ( "sources",
         `List
           (List.map
              (fun (s : Store.source) ->
                `Assoc
                  ([
                     ("id", `String s.id);
                     ("kind", `String s.kind);
                     ("label", `String s.label);
                   ]
                  @ (if s.kind = "git" && scanned then
                       [ ("organizations", organizations_json n) ]
                     else [ ("paths", strings s.paths) ])
                  @ [ ("selected", `Bool s.selected) ]
                  @
                  if s.kind = "claude_code" then
                    [
                      ("directories", strings (Sources.session_directories ()));
                    ]
                  else []))
              (Store.sources n.log)) );
     ]
    @ if scanned then [ ("commit_authors", authors_json n) ] else [])

(* The card Settings writes too (Api.Names). *)
let save_names (n : Node.t) ~name ~agent_name =
  if String.trim name = "" || String.trim agent_name = "" then
    Error "Both names are required: the member's and the agent's."
  else
    match Api.Names.publish n ~member_name:name ~agent_name with
    | Error (_, m) -> Error m
    | Ok () -> Ok "Saved."

(* What the member changed of what setup proposed for git, the same choices the Repositories page
   makes: an organization's choice, a repository approved or declined, a commit author added or
   relabelled, or removed. *)
type repository_choices = {
  organizations : (string * string) list;  (** organization id, choice *)
  approve : string list;  (** repository ids *)
  decline : string list;
  authors : (string * string) list;  (** email, label *)
  remove_authors : string list;  (** emails *)
}

let no_choices =
  {
    organizations = [];
    approve = [];
    decline = [];
    authors = [];
    remove_authors = [];
  }

(* A flag's KEY=VALUE, split at the last =, since an id or an email may hold one but a choice or a
   label never does. *)
let key_value ~flag s =
  match String.rindex_opt s '=' with
  | Some i when i > 0 && i < String.length s - 1 ->
      Ok
        ( String.trim (String.sub s 0 i),
          String.trim (String.sub s (i + 1) (String.length s - i - 1)) )
  | _ -> Error (Printf.sprintf "--%s takes KEY=VALUE, not %s." flag s)

let one_of what values v =
  if List.mem v values then Ok ()
  else
    Error
      (Printf.sprintf "%s is not a %s: choose one of %s." v what
         (String.concat ", " values))

let rec all_ok f = function
  | [] -> Ok ()
  | x :: rest ->
      let* () = f x in
      all_ok f rest

let rec map_ok f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = map_ok f rest in
      Ok (y :: ys)

(* `setup sources`' flags: --organization ID=CHOICE and --author EMAIL=LABEL as written. *)
let choices_of_flags ~organizations ~approve ~decline ~authors ~remove_authors =
  let* organizations = map_ok (key_value ~flag:"organization") organizations in
  let* authors = map_ok (key_value ~flag:"author") authors in
  Ok { organizations; approve; decline; authors; remove_authors }

(* Every choice checked before any is saved, so a refusal saves nothing. *)
let check_choices (n : Node.t) (c : repository_choices) =
  let* () =
    all_ok
      (fun (id, choice) ->
        if R.organization n.log id = None then
          Error ("No organization is called " ^ id ^ ".")
        else one_of "choice" R.choices choice)
      c.organizations
  in
  let* () =
    all_ok
      (fun id ->
        if R.repository n.log id = None then
          Error ("No repository is called " ^ id ^ ".")
        else if List.mem id c.approve && List.mem id c.decline then
          Error (id ^ " is both approved and declined.")
        else Ok ())
      (c.approve @ c.decline)
  in
  let* () =
    all_ok
      (fun (email, label) ->
        if String.trim email = "" then Error "An author needs an email."
        else one_of "label" R.labels label)
      c.authors
  in
  all_ok
    (fun email ->
      if R.author_by_email n.log email = None then
        Error ("No commit author has the email " ^ email ^ ".")
      else Ok ())
    c.remove_authors

(* Choices first, so All's approving what is undecided never undoes a repository declined in the
   same save. *)
let apply_choices (n : Node.t) (c : repository_choices) =
  List.iter (fun (id, choice) -> R.set_choice n.log id choice) c.organizations;
  List.iter (fun id -> R.set_status n.log id "approved") c.approve;
  List.iter (fun id -> R.set_status n.log id "declined") c.decline;
  List.iter
    (fun (email, label) ->
      match R.author_by_email n.log email with
      | Some a -> R.label_author n.log a.a_id label
      | None -> ignore (R.add_author n.log ~email ~name:None ~label))
    c.authors;
  List.iter
    (fun email ->
      Option.iter
        (fun (a : R.author) -> R.remove_author n.log a.a_id)
        (R.author_by_email n.log email))
    c.remove_authors

(* [ids], or every source offered with [all], and what the member changed of the repositories and
   commit authors proposed. A command source already saved stays chosen. *)
let save_sources ?(choices = no_choices) (n : Node.t) ~all ~ids =
  refresh n;
  let offered = Store.sources n.log in
  let known = List.map (fun (s : Store.source) -> s.id) offered in
  let commands =
    List.filter_map
      (fun (s : Store.source) ->
        if s.kind = Store.k_command && s.selected then Some s.id else None)
      offered
  in
  match List.find_opt (fun id -> not (List.mem id known)) ids with
  | Some id -> Error ("No source is called " ^ id ^ ".")
  | None ->
      let chosen =
        if all then known else List.sort_uniq compare (ids @ commands)
      in
      if chosen = [] then Error "Choose at least one source: they are required."
      else
        let () =
          Machine_scan.propose_authors ~now:(Unix.gettimeofday ()) n.log
        in
        let* () = check_choices n choices in
        apply_choices n choices;
        Store.select_sources n.log chosen;
        Ok "Saved. Nothing was read from them until now."

(* A command source is saved only when it runs (Sources.test_command); the agent gets the line
   count or the error, never the output. *)
let add_command (n : Node.t) ~now ~label ~command =
  let label = String.trim label in
  refresh n;
  let id = Sources.command_id label in
  let taken (s : Store.source) =
    s.id = id || String.lowercase_ascii s.label = String.lowercase_ascii label
  in
  if label = "" then Error "Name the source."
  else if List.exists taken (Store.sources n.log) then
    Error "Another source has that name."
  else
    match Sources.test_command ~now command with
    | Error e -> Error ("It failed: " ^ e ^ ". Not saved.")
    | Ok count ->
        Store.add_command_source n.log ~id ~label ~command;
        Store.Setup.choose_source n.log id;
        Ok
          (Printf.sprintf "Worked, %d line%s. Saved." count
             (if count = 1 then "" else "s"))

let save_brief (n : Node.t) text =
  match String.trim text with
  | "" -> Error "The brief is required: write a few lines."
  | text ->
      Store.set_brief n.log text;
      Ok "Saved."

let add_rule (n : Node.t) text =
  match String.trim text with
  | "" -> Error "Write the rule."
  | text ->
      Store.Setup.add_rule n.log text;
      Ok ("Saved as a rule: " ^ text)

let add_deny (n : Node.t) ~kind value =
  let body = `Assoc [ ("kind", `String kind); ("value", `String value) ] in
  let r =
    Api.handle n ~meth:"POST" ~path:[ "rules"; "deny" ] ~query:[]
      ~body:(Some body)
  in
  match (r.status, r.body) with
  | s, _ when s < 300 ->
      Ok ("Added to your deny list: " ^ String.trim value ^ ".")
  | _, Some (`List (`Assoc e :: _)) -> (
      match List.assoc_opt "message" e with
      | Some (`String m) -> Error m
      | _ -> Error "Refused.")
  | s, _ -> Error (Printf.sprintf "Refused: status %d." s)

(* What the saved sources hold, through the reader a note uses. Refused until they are saved. *)
let read (n : Node.t) ~now =
  match Store.Setup.next n.log with
  | Some (Names | Sources) ->
      Error "Nothing is read until the sources are saved."
  | _ ->
      Ok
        (Sources.extract ~now
           (List.filter
              (fun (s : Store.source) -> s.selected)
              (Store.sources n.log)))

(* Names, sources and brief are required before the first note. *)
let ready_for_first_note (n : Node.t) =
  match Store.Setup.next n.log with
  | Some First_note | None -> Ok ()
  | Some item ->
      Error ("Not yet: save " ^ Store.Setup.item_name item ^ " first.")

(* Starts the first note, once. *)
let start_first_note (n : Node.t) =
  let* () = ready_for_first_note n in
  Store.Setup.start_first_note n.log;
  Ok ()

(* The chat's last words (docs/design.md, The setup chat and the first note). [cli] is the installed
   digestif's full path, because its directory may not be on PATH. The node's service writes the note,
   so the window can close at once, and one plain line says so with how to open Digestif later;
   [phrase_shown] says this run printed the recovery phrase in it, which only a first digestif join
   does, and only then is the phrase named. ISS-47892 ISS-48140 *)
let last_words ~cli ~browser ~host ~phrase_shown =
  let first =
    if browser then
      "Setup is done. Your browser is opening Digestif, where your first note \
       appears once it is written, for you to approve before it goes to your \
       circle."
    else
      "Setup is done. Your first note appears in Digestif once it is written, \
       for you to approve before it goes to your circle."
  in
  let close =
    "You can close this window now: the Digestif service on this machine \
     writes the note in the background, not this chat. To open Digestif \
     later: " ^ cli ^ " open"
  in
  let tunnel =
    if browser then []
    else
      [
        "This machine has no browser. From your own machine, run ssh -L \
         7420:127.0.0.1:7420 " ^ host ^ ", then " ^ cli
        ^ " open --print here for a link good for five minutes.";
      ]
  in
  let phrase =
    if phrase_shown then
      [
        "Your recovery phrase is still in this window: make sure it is saved, \
         then close the window.";
      ]
    else []
  in
  (first :: tunnel) @ (close :: phrase)
