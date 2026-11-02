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

let refresh (n : Node.t) =
  if Log.get_config n.log Sources.k_fixed = None then
    Store.set_offered n.log (Sources.discover ())

let status_string (n : Node.t) key =
  match
    (Api.handle n ~meth:"GET" ~path:[ "status" ] ~query:[] ~body:None).body
  with
  | Some (`Assoc f) -> (
      match List.assoc_opt key f with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let strings l = `List (List.map (fun s -> `String s) l)

(* What setup found, and the first item not done. Names and paths, never a source's contents. *)
let found (n : Node.t) ~invited_name : Yojson.Safe.t =
  refresh n;
  let opt = function Some s -> `String s | None -> `Null in
  `Assoc
    [
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
                    ("paths", strings s.paths);
                    ("selected", `Bool s.selected);
                  ]
                 @
                 if s.kind = "claude_code" then
                   [ ("directories", strings (Sources.session_directories ())) ]
                 else []))
             (Store.sources n.log)) );
    ]

let save_names (n : Node.t) ~name ~agent_name =
  let name = String.trim name and agent_name = String.trim agent_name in
  if name = "" || agent_name = "" then
    Error "Both names are required: the member's and the agent's."
  else
    let* enc = Node.encryption_key n in
    let body =
      Bodies.make_card ~name ~agent_name
        ~encryption_key:(Keys.encryption_public enc)
    in
    let* _ = Node.write n ~kind:"card" body in
    Store.Setup.names_saved n.log;
    Ok "Saved."

(* [ids], or every source offered with [all]. A command source already saved stays chosen. *)
let save_sources (n : Node.t) ~all ~ids =
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
      else begin
        Store.select_sources n.log chosen;
        Ok "Saved. Nothing was read from them until now."
      end

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

(* The chat's last words (docs/design.md, The setup chat and the first note). [exe] is the full path,
   because the bin directory may not be on PATH. *)
let last_words ~exe ~browser ~host =
  let phrase =
    "Your recovery phrase is still in this window, so close it once your note \
     is open."
  in
  if browser then
    [
      "I'm writing your first note now, from your recent work, and your \
       browser will open on it. Setup is done when it is approved.";
      "If it does not open, or you close it later: " ^ exe ^ " open";
      phrase;
    ]
  else
    [
      "I'm writing your first note now, from your recent work. Setup is done \
       when it is approved.";
      "Run " ^ exe
      ^ " open --print for a link good for five minutes, and from your own \
         machine ssh -L 7420:127.0.0.1:7420 " ^ host ^ " to open it there.";
      phrase;
    ]
