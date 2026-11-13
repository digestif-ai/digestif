(* The node's local API, spec/digestif-node.json: every operation the web UI calls, answered from
   the log, the fold and the local store. Nothing here is wire format. A write that signs an envelope
   puts it in the log and asks for a sync, which pushes it to every relay. *)

open Digestif_core

type ctx = {
  node : Node.t;
  fold : Fold.t;
  now : float;
  on_write : unit -> unit;  (** a new envelope of ours wants a sync *)
  upkeep_waits : bool;
      (** whether upkeep a reader can go without (the Inbox index) waits for the
          log's write lock: a GET never does, so a page never waits on
          background work (ISS-78820) *)
}

let log c = c.node.log

(* Upkeep a read can go without (the Inbox index, a note first found readable), under the write lock.
   A GET runs it only when the lock is free and otherwise answers from the store as it stands: whoever
   holds the lock may hold it for seconds, and the run loop brings the index up after every sync
   (keep_up), so a GET that skips it reads at most one pass behind. ISS-78820 *)
let upkeep c f =
  if c.upkeep_waits then Log.transaction (log c) f
  else ignore (Log.try_transaction (log c) f : unit option)

type response = { status : int; body : Yojson.Safe.t option }

let ok ?(status = 200) j = { status; body = Some j }
let no_content = { status = 204; body = None }

let errors status ?field code message =
  {
    status;
    body =
      Some
        (`List
           [
             `Assoc
               ([ ("code", `String code); ("message", `String message) ]
               @
               match field with
               | Some f -> [ ("field", `String f) ]
               | None -> []);
           ]);
  }

let not_found () = errors 404 "not_found" "Not found."
let invalid ?field code message = errors 422 ?field code message
let str s = `String s
let opt name = function Some v -> [ (name, `String v) ] | None -> []
let ( let* ) = Result.bind

(* who's who *)

let self_identity c = Log.get_config (log c) Node.k_identity

(* Where this node's UI answers, http://127.0.0.1:<port>, recorded by Server.start for the port it
   bound. *)
let k_ui_url = "ui_url"
let ui_url c = Log.get_config (log c) k_ui_url

let identity_of c key =
  match Fold.identity_of c.fold key with
  | Some id -> Some id
  | None ->
      (* Our own keys, before the fold has admitted them. *)
      if List.mem key (Node.own_keys c.node) then self_identity c else None

let card c identity = Option.map fst (Hashtbl.find_opt c.fold.cards identity)

let short key =
  match String.index_opt key ':' with
  | Some i when String.length key > i + 8 -> String.sub key (i + 1) 8
  | _ -> key

(* The identity whose join spent [invite_key], once one has. *)
let joined_by c invite_key =
  match Hashtbl.find_opt c.fold.invites invite_key with
  | Some { spent_by = Some join; _ } -> (
      match Log.find (log c) join with
      | Some { signed = { body = Some jb; _ }; _ } -> (
          match Bodies.parse_join jb with
          | Ok j -> Some j.identity_key
          | Error _ -> None)
      | _ -> None)
  | _ -> None

let dinner_bodies c =
  Hashtbl.fold (fun h _ acc -> h :: acc) c.fold.dinners []
  |> List.filter_map (fun h ->
      match Log.find (log c) h with
      | Some { signed = { body = Some b; _ }; _ } -> (
          match Bodies.parse_dinner b with
          | Ok d -> Some (h, d)
          | Error _ -> None)
      | _ -> None)

(* The name a host gave this member as a guest of the dinner that admitted them. *)
let invited_name c identity =
  List.find_map
    (fun (_, (d : Bodies.dinner)) ->
      List.find_map
        (fun (g : Bodies.guest) ->
          if joined_by c g.invite_key = Some identity then Some g.name else None)
        d.guests)
    (dinner_bodies c)

(* A member's name: their card's, else the name their invite gave them, else a short key. *)
(* The name and agent name a member goes by: their card's, else their invite's. *)
let names c identity =
  match card c identity with
  | Some k -> (k.card_name, k.agent_name)
  | None -> (
      match invited_name c identity with
      | Some n -> (n, "Agent")
      | None -> ("Member " ^ short identity, "Agent"))

(* A status note's fixed words, from the one table (Status_note) and the names [identity] goes by:
   the UI shows them as they come. ISS-53999 *)
let status_note_words c identity status =
  let name, agent_name = names c identity in
  Status_note.of_card ~status ~name ~agent_name

let member_ref c identity : Yojson.Safe.t =
  let name, agent = names c identity in
  `Assoc
    [
      ("identity", str identity); ("name", str name); ("agent_name", str agent);
    ]

let encryption c =
  match Node.encryption_key c.node with Ok k -> Some k | Error _ -> None

let circle_names c =
  Hashtbl.fold
    (fun _ ((k : Bodies.card), _) acc -> k.card_name :: k.agent_name :: acc)
    c.fold.cards []

let unix s = Option.value (Time_fmt.to_unix s) ~default:0.0

(* Messages: an envelope in the log, or an outbound row that never became one. *)

type msg = {
  hash : string;
  kind : string;
  voice : string;
  author : string;  (** identity *)
  created_at : string;
  status : string;
  text : string option;
  reply_to : string option;
  refused_rule : string option;
  held_reason : string option;
}

let own_unsent c (r : Log.row) =
  let ours = List.mem r.signed.envelope.author (Node.own_keys c.node) in
  ours
  && Log.sightings (log c) r.hash = []
  && List.exists
       (fun (x : Log.relay_row) -> x.last_error <> None)
       (Log.relays (log c))

let of_row c (r : Log.row) =
  let e = r.signed.envelope in
  let read = Content.read r.signed.body in
  let retracted = r.retracted_by <> None in
  {
    hash = r.hash;
    kind = e.kind;
    voice = read.voice;
    author = Option.value (identity_of c e.author) ~default:e.author;
    created_at = e.created_at;
    status =
      (if retracted then "retracted"
       else if own_unsent c r then "failed"
       else "posted");
    text = (if retracted then None else read.text);
    reply_to = read.reply_to;
    refused_rule = None;
    held_reason = None;
  }

let of_outbound c (o : Store.outbound) =
  {
    hash = o.o_id;
    kind = o.o_kind;
    voice = o.voice;
    author = Option.value (self_identity c) ~default:"";
    created_at = o.o_created_at;
    status = o.status;
    text = (if o.status = "retracted" then None else o.o_text);
    reply_to = o.reply_to;
    refused_rule = o.refused_rule;
    held_reason = o.held_reason;
  }

let preview m =
  match m.text with
  | Some t -> Note_preview.of_text t
  | None -> (
      match m.status with
      | "refused" -> "Refused before signing"
      | "retracted" -> "Retracted"
      | _ -> "Sealed")

(* What the member's Inbox agent did with a message (ISS-52611): Reviewed and its review line. *)
let review_fields c hash =
  match Store.Reviews.find (log c) hash with
  | Some (at, review) -> ("reviewed_at", str at) :: opt "review" review
  | None -> []

let item_json c m : Yojson.Safe.t =
  `Assoc
    ([
       ("hash", str m.hash);
       ("kind", str m.kind);
       ("voice", str m.voice);
       ("author", member_ref c m.author);
       ("created_at", str m.created_at);
       ("status", str m.status);
       ("preview", str (preview m));
     ]
    @ opt "reply_to" m.reply_to @ review_fields c m.hash)

let newest_first l = List.sort (fun a b -> compare b.created_at a.created_at) l

(* Our outbound rows refused before signing, which the feed shows beside what the log holds. The
   outbox is this member's own unsent writes, so it is read whole. *)
let refused c =
  Store.outbox (log c)
  |> List.filter (fun (o : Store.outbound) -> o.status = "refused")
  |> List.map (of_outbound c)

let find_msg c hash =
  match Log.find (log c) hash with
  | Some r when List.mem r.signed.envelope.kind Content.feed_kinds ->
      Some (of_row c r)
  | _ -> (
      match Store.outbound (log c) hash with
      | Some o -> (
          match o.posted_hash with
          | Some h -> Option.map (of_row c) (Log.find (log c) h)
          | None -> Some (of_outbound c o))
      | None -> None)

(* ISS-83154: a reply the member's agent drafts to a note (docs/design.md, The Inbox agent). The
   note [hash] takes one when it is another member's note that still holds its text. *)
let reply_note c hash =
  match Log.find (log c) hash with
  | Some r when r.signed.envelope.kind = "summary" && r.retracted_by = None -> (
      let m = of_row c r in
      match m.text with
      | Some t when String.trim t <> "" && Some m.author <> self_identity c ->
          Some m
      | _ -> None)
  | _ -> None

(* A draft reply asked for and not answered by then reads as failed: a read run already running
   ends first, and the one handed the draft has its own deadline (Behaviors.timeout). *)
let draft_deadline = 1_900.0

let agent_answer_json (a : Store.Reviews.agent_answer) : Yojson.Safe.t =
  `Assoc
    ([ ("text", str a.text) ]
    @ opt "reason" a.reason
    @ [ ("created_at", str a.at) ])

(* Where a draft reply the member asked for to [hash] stands: asked until the agent's answer is
   kept, or failed, saying why. *)
let draft_reply_json c hash : Yojson.Safe.t option =
  Option.map
    (fun (d : Store.Reviews.draft_request) ->
      let stale =
        d.d_status <> "failed" && c.now -. unix d.d_at > draft_deadline
      in
      let status =
        if d.d_status = "failed" || stale then "failed" else "asked"
      in
      let why =
        if stale then Some "Your agent did not answer in time." else d.d_why
      in
      `Assoc
        ([ ("status", str status); ("at", str d.d_at) ]
        @ if status = "failed" then opt "why" why else []))
    (Store.Reviews.draft_request (log c) hash)

(* The fields a page reading the note [hash] shows its draft reply with. *)
let reply_fields c hash =
  (match Store.Reviews.agent_answer (log c) hash with
    | Some a -> [ ("agent_answer", agent_answer_json a) ]
    | None -> [])
  @
  match draft_reply_json c hash with
  | Some j -> [ ("draft_reply", j) ]
  | None -> []

(* POST /messages/:hash/draft-reply: the member asks their Inbox agent for a draft reply to one
   note now. The next pass hands it to a read run, which writes the draft and never sends it; the
   page reads draft_reply until the draft is there. *)
let draft_reply c hash =
  match reply_note c hash with
  | None -> (
      match find_msg c hash with
      | None -> not_found ()
      | Some _ ->
          invalid "not_draftable"
            "Only another member's note is given a draft reply.")
  | Some m -> (
      match Log.get_config (log c) (Store.k_behavior "read") with
      | None ->
          invalid "no_reader"
            "No read behavior is set, so no agent can draft a reply."
      | Some _ ->
          (match draft_reply_json c m.hash with
          | Some (`Assoc f)
            when List.assoc_opt "status" f = Some (`String "asked") ->
              ()
          | _ -> Store.Reviews.ask_draft (log c) m.hash ~at:(Time_fmt.now ()));
          c.on_write ();
          ok ~status:202
            (Option.value (draft_reply_json c m.hash) ~default:`Null))

let message_json ?note_id c m : Yojson.Safe.t =
  let replies =
    List.map (of_row c)
      (View.replies ~kinds:Content.feed_kinds (log c) c.fold m.hash)
    @ List.filter (fun r -> r.reply_to = Some m.hash) (refused c)
    |> List.stable_sort (fun a b -> compare a.created_at b.created_at)
    |> List.map (item_json c)
  in
  `Assoc
    ([
       ("hash", str m.hash);
       ("kind", str m.kind);
       ("voice", str m.voice);
       ("author", member_ref c m.author);
       ("created_at", str m.created_at);
       ("status", str m.status);
     ]
    @ opt "text" m.text @ opt "reply_to" m.reply_to
    @ opt "refused_rule" m.refused_rule
    @ opt "held_reason" m.held_reason
    @ opt "note_id" note_id @ review_fields c m.hash
    @ (if reply_note c m.hash = None then []
       else ("can_draft_reply", `Bool true) :: reply_fields c m.hash)
    @ [ ("replies", `List replies) ])

(* body fields *)

let field name (b : Yojson.Safe.t option) =
  match b with Some (`Assoc f) -> List.assoc_opt name f | _ -> None

let string_field name b =
  match field name b with Some (`String s) -> Some s | _ -> None

let strings_field name b =
  match field name b with
  | Some (`List l) ->
      List.fold_right
        (fun x acc ->
          match (x, acc) with
          | `String s, Some acc -> Some (s :: acc)
          | _ -> None)
        l (Some [])
  | _ -> None

(* The deny layer over one outbound text; a trip counts against the entry that tripped. *)
let deny_check c ?(count = true) text =
  match
    Deny.check ~entries:(Store.deny_list (log c)) ~allowed:(circle_names c) text
  with
  | Deny.Pass -> None
  | Tripped { rule; entry } ->
      if count then Option.iter (Store.deny_tripped (log c)) entry;
      Some rule

let sign c ~kind body =
  match Node.write c.node ~kind body with
  | Ok (hash, _) ->
      c.on_write ();
      Ok hash
  | Error e -> Error e

let own_card_key c =
  match self_identity c with
  | None -> None
  | Some id ->
      Option.map (fun (k : Bodies.card) -> k.encryption_key) (card c id)

(* status *)

(* members *)

let identities c =
  Hashtbl.fold
    (fun _ (k : Fold.key_state) acc ->
      if k.role = Bodies.Identity then k :: acc else acc)
    c.fold.keys []

let envelope_time c hash =
  Option.map
    (fun (r : Log.row) -> r.signed.envelope.created_at)
    (Log.find (log c) hash)

(* What every member's summaries say of them (docs/design.md, Stages and the status note): the
   stage their newest summary carried, and their newest note, the summaries in the agent's voice,
   a status note included. A member with no summary yet sends nothing: they are Onboarding. *)
type heard = {
  stage_at : string;
  stage : string;
  note_at : string option;
  status_note : string option;
}

(* Every key that writes as [identity]: its own and its devices', and ours before the fold admits
   them (identity_of). *)
let keys_of c identity =
  let admitted =
    Hashtbl.fold
      (fun _ (k : Fold.key_state) acc ->
        if k.identity = identity then k.key :: acc else acc)
      c.fold.keys []
  in
  let own =
    if self_identity c = Some identity then Node.own_keys c.node else []
  in
  List.sort_uniq compare (admitted @ own)

(* What one member's summaries said, read newest first by each of their keys' own index and only
   as far back as that key's newest note in the agent's voice: a circle's age costs nothing here. *)
let heard_of c identity =
  let newest_of a b =
    match (a, b) with
    | Some (x : Log.row), Some (y : Log.row) ->
        if View.newest x y <= 0 then a else b
    | None, r | r, None -> r
  in
  let stage, note =
    List.fold_left
      (fun (stage, note) key ->
        let first = ref None and agent = ref None in
        Log.newest_first (log c) ~author:key ~where:"kind = 'summary'" []
          (fun (r : Log.row) ->
            if !first = None then first := Some r;
            (match r.signed.body with
            | Some b when Content.voice_of b = "agent" -> agent := Some r
            | _ -> ());
            if !agent <> None then `Stop else `Continue);
        (newest_of stage !first, newest_of note !agent))
      (None, None) (keys_of c identity)
  in
  Option.map
    (fun (s : Log.row) ->
      {
        stage_at = s.signed.envelope.created_at;
        stage = Content.stage_of s.signed.body;
        note_at =
          Option.map (fun (r : Log.row) -> r.signed.envelope.created_at) note;
        status_note =
          Option.bind note (fun (r : Log.row) ->
              Content.status_of r.signed.body);
      })
    stage

let heard c (identities : Fold.key_state list) =
  let t = Hashtbl.create 16 in
  List.iter
    (fun (k : Fold.key_state) ->
      Option.iter (Hashtbl.replace t k.key) (heard_of c k.key))
    identities;
  t

(* This member's own stage is the one they hold; everyone else's is what their summaries said. *)
let stage_of_member c heard (k : Fold.key_state) =
  if self_identity c = Some k.key then Store.Stages.stage (log c)
  else
    match Hashtbl.find_opt heard k.key with
    | Some h -> h.stage
    | None -> "onboarding"

let summary_fields c heard (k : Fold.key_state) =
  let me = self_identity c = Some k.key in
  let h = Hashtbl.find_opt heard k.key in
  (match member_ref c k.key with `Assoc f -> f | _ -> [])
  @ [
      ("status", str (if k.revoked_by <> None then "revoked" else "active"));
      ("stage", str (stage_of_member c heard k));
    ]
  @ opt "last_note_at" (Option.bind h (fun h -> h.note_at))
  @ opt "last_status_note" (Option.bind h (fun h -> h.status_note))
  @ opt "last_status_note_words"
      (Option.bind h (fun h ->
           Option.bind h.status_note (status_note_words c k.key)))
  @ opt "encryption_key"
      (Option.map (fun (b : Bodies.card) -> b.encryption_key) (card c k.key))
  @ [ ("muted", `Bool (Store.muted (log c) k.key)); ("is_self", `Bool me) ]

let stage_rank = function "active" -> 0 | "paused" -> 1 | _ -> 2

(* Members: everyone in the circle, Active first, then Paused, then Onboarding, the newest note
   first within each. A revoked identity has left and is not a row. *)
let members_ordered c =
  let current =
    List.filter (fun (k : Fold.key_state) -> k.revoked_by = None) (identities c)
  in
  let heard = heard c current in
  let note_at (k : Fold.key_state) =
    Option.bind (Hashtbl.find_opt heard k.key) (fun h -> h.note_at)
  in
  current
  |> List.sort (fun (a : Fold.key_state) b ->
      match
        compare
          (stage_rank (stage_of_member c heard a))
          (stage_rank (stage_of_member c heard b))
      with
      | 0 -> (
          match (note_at a, note_at b) with
          | Some x, Some y when x <> y -> compare y x
          | Some _, None -> -1
          | None, Some _ -> 1
          | _ -> compare a.key b.key)
      | n -> n)
  |> fun l -> (heard, l)

(* A phone is a device key whose device body carries an enrollment (docs/protocol.md, The phone):
   this machine's own device key and the mail key carry none. *)
let is_phone c (d : Fold.key_state) =
  d.role = Bodies.Device
  &&
  match Log.find (log c) d.admitted_by with
  | Some { signed = { body = Some (`Assoc f); _ }; _ } ->
      List.mem_assoc "enrollment" f
  | _ -> false

let device_json ?revoked_at c (d : Fold.key_state) : Yojson.Safe.t =
  let revoked_at =
    match revoked_at with
    | Some _ -> revoked_at
    | None -> Option.bind d.revoked_by (envelope_time c)
  in
  `Assoc
    ([
       ("key", str d.key);
       ("role", str (Bodies.role_to_string d.role));
       ( "admitted_at",
         str (Option.value (envelope_time c d.admitted_by) ~default:"") );
     ]
    @ opt "revoked_at" revoked_at
    @ [ ("phone", `Bool (is_phone c d)) ])

let member_json c (k : Fold.key_state) : Yojson.Safe.t =
  let heard = heard c [ k ] in
  let devices =
    Hashtbl.fold
      (fun _ (d : Fold.key_state) acc ->
        if d.identity = k.key && d.role <> Bodies.Identity then d :: acc
        else acc)
      c.fold.keys []
    |> List.sort (fun (a : Fold.key_state) b -> compare a.key b.key)
    |> List.map (device_json c)
  in
  let recent =
    let logged =
      View.page ~authors:(keys_of c k.key) ~kinds:Content.feed_kinds ~limit:20
        (log c) c.fold
      |> List.map (of_row c)
    in
    let held = if self_identity c = Some k.key then refused c else [] in
    newest_first (logged @ held)
    |> List.filteri (fun i _ -> i < 20)
    |> List.map (item_json c)
  in
  `Assoc
    (summary_fields c heard k
    @ [
        ( "joined_at",
          str (Option.value (envelope_time c k.admitted_by) ~default:"") );
        ("devices", `List devices);
        ("recent", `List recent);
      ])

let find_identity c id =
  match Fold.find c.fold id with
  | Some ({ role = Bodies.Identity; _ } as k) -> Some k
  | _ -> None

(* sources *)

(* What this machine offers, from the stored scan (Machine_scan): the list is rediscovered by the
   node's pass, or in the background by a read once the scan is a day old, and keeps the member's
   choice. *)
let refresh_sources c = Machine_scan.ensure ~now:c.now c.node

let source_json (s : Store.source) : Yojson.Safe.t =
  `Assoc
    [
      ("id", str s.id);
      ("kind", str s.kind);
      ("label", str s.label);
      ("paths", `List (List.map str s.paths));
      ("yields", `List (List.map str s.yields));
      ("selected", `Bool s.selected);
    ]

let sources_json c = `List (List.map source_json (Store.sources (log c)))

(* ISS-41944: a list's page size, from the query's limit, or 422 naming it. *)
let limit_param query ~default =
  match List.assoc_opt "limit" query with
  | None | Some "" -> Ok default
  | Some v -> (
      match int_of_string_opt v with
      | Some n when n >= 1 && n <= 200 -> Ok n
      | _ -> Error (invalid ~field:"limit" "limit" "Not a valid limit."))

(* A list's cursor, the id of the last row of the page before, when the store holds that row
   ([known]); 422 naming it when it does not, since a page after nothing is no page at all. *)
let cursor_param query ~known =
  match List.assoc_opt "cursor" query with
  | None | Some "" -> Ok None
  | Some id when known id -> Ok (Some id)
  | Some _ -> Error (invalid ~field:"cursor" "cursor" "Not a valid cursor.")

(* One page of sources, in the order Settings lists them. *)
let source_page c query =
  let known id =
    Log.rows (log c) "SELECT 1 FROM ui_sources WHERE id = ?" [ Log.s id ] <> []
  in
  match
    let* limit = limit_param query ~default:100 in
    let* after = cursor_param query ~known in
    Ok (limit, after)
  with
  | Error e -> e
  | Ok (limit, after) ->
      refresh_sources c;
      ok (`List (List.map source_json (Store.sources (log c) ?after ~limit)))

(* ISS-41988: one page of members, in the order Members lists them. The order is the fold's, read
   from the circle's summaries, so the page is cut from it; a circle is the people a member knows,
   not a list that grows with the node's age. *)
let member_page c query =
  let ordered = lazy (members_ordered c) in
  let known id =
    List.exists
      (fun (k : Fold.key_state) -> k.key = id)
      (snd (Lazy.force ordered))
  in
  match
    let* limit = limit_param query ~default:100 in
    let* after = cursor_param query ~known in
    Ok (limit, after)
  with
  | Error e -> e
  | Ok (limit, after) ->
      let heard, members = Lazy.force ordered in
      let rec after_ id = function
        | [] -> []
        | (k : Fold.key_state) :: rest ->
            if k.key = id then rest else after_ id rest
      in
      let rows =
        match after with None -> members | Some id -> after_ id members
      in
      ok
        (`List
           (List.filteri (fun i _ -> i < limit) rows
           |> List.map (fun k -> `Assoc (summary_fields c heard k))))

let selection c body =
  if Store.sources (log c) = [] then refresh_sources c;
  match strings_field "selected" body with
  | None -> Error (invalid ~field:"selected" "unknown_source" "Unknown source.")
  | Some ids ->
      let known =
        List.map (fun (s : Store.source) -> s.id) (Store.sources (log c))
      in
      if List.for_all (fun id -> List.mem id known) ids then Ok ids
      else Error (invalid ~field:"selected" "unknown_source" "Unknown source.")

(* brief *)

let brief_json c =
  let b = Store.brief (log c) in
  `Assoc
    ([ ("text", str b.text) ]
    @ opt "updated_at" b.updated_at
    @ [ ("can_draft", `Bool (Sources.writer (log c) <> None)) ])

(* A first brief from the member's card and the chosen sources, for the edit form. Saves nothing:
   the brief is the member's own words once they save it. *)
let draft_brief c =
  let name, agent_name =
    match Option.bind (self_identity c) (card c) with
    | Some k -> (k.card_name, k.agent_name)
    | None -> ("", "")
  in
  let chosen =
    List.filter (fun (s : Store.source) -> s.selected) (Store.sources (log c))
  in
  let reading = Sources.extract_reading ~now:c.now chosen in
  (* What the reading skipped is told in the Inbox on this machine, never handed to the writer. *)
  Skipped.record (log c) (Skipped.of_reading reading);
  match Sources.draft_brief (log c) ~name ~agent_name reading.lines with
  | Ok text -> ok (`Assoc [ ("text", str text) ])
  | Error e -> invalid "writer" e

(* A command source the member adds (docs/behaviors.md, Command sources). *)
let add_source c body =
  let label =
    String.trim (Option.value (string_field "label" body) ~default:"")
  in
  let command =
    Option.value (strings_field "command" body) ~default:[]
    |> List.map String.trim
    |> List.filter (fun a -> a <> "")
  in
  if Store.sources (log c) = [] then refresh_sources c;
  let id = Sources.command_id label in
  let taken (s : Store.source) =
    s.id = id || String.lowercase_ascii s.label = String.lowercase_ascii label
  in
  if label = "" then invalid ~field:"label" "empty" "Name the source."
  else if List.exists taken (Store.sources (log c)) then
    invalid ~field:"label" "taken" "Another source has that name."
  else
    match Sources.test_command ~now:c.now command with
    | Error m -> invalid ~field:"command" "program" m
    | Ok _lines ->
        Store.add_command_source (log c) ~id ~label ~command;
        ok ~status:201 (sources_json c)

let remove_source c id =
  match
    List.find_opt (fun (s : Store.source) -> s.id = id) (Store.sources (log c))
  with
  | None -> not_found ()
  | Some s when s.kind <> Store.k_command ->
      invalid "discovered"
        "This machine offers that source; leave it unselected instead."
  | Some _ ->
      Store.remove_source (log c) id;
      ok (sources_json c)

(* rules *)

let deny_json (e : Store.deny_entry) : Yojson.Safe.t =
  `Assoc
    [
      ("id", str e.d_id);
      ("kind", str e.d_kind);
      ("value", str e.value);
      ("created_at", str e.created_at);
      ("trips", `Int e.trips);
    ]

(* What a behavior reads before it reaches the person outside the digest: the span, whether it holds
   now, and when it ends. *)
let quiet_hours_json c (q : Quiet_hours.t) : Yojson.Safe.t =
  let active = Quiet_hours.active q ~now:c.now in
  `Assoc
    ([
       ("start", str (Quiet_hours.start_string q));
       ("end", str (Quiet_hours.stop_string q));
       ("active", `Bool active);
     ]
    @
    if active then
      [ ("ends_at", str (Time_fmt.of_unix (Quiet_hours.ends_at q ~now:c.now))) ]
    else [])

let set_quiet_hours c body =
  let start = Option.value (string_field "start" body) ~default:"" in
  let stop = Option.value (string_field "end" body) ~default:"" in
  match Quiet_hours.make ~start ~stop with
  | Error `Start -> invalid ~field:"start" "time" "Start is a time like 22:00."
  | Error `Stop -> invalid ~field:"end" "time" "End is a time like 07:00."
  | Error `Empty -> invalid ~field:"end" "empty" "Start and end are the same."
  | Ok q ->
      Quiet_hours.set (log c) q;
      ok (quiet_hours_json c q)

let rules_json c : Yojson.Safe.t =
  let r = Store.rules (log c) in
  `Assoc
    ([ ("text", str r.text) ]
    @ opt "updated_at" r.updated_at
    @ (match Quiet_hours.get (log c) with
      | Some q -> [ ("quiet_hours", quiet_hours_json c q) ]
      | None -> [])
    @ [
        ("deny", `List (List.map deny_json (Store.deny_list (log c))));
        ( "detectors",
          `List
            (List.map
               (fun (d : Deny.detector) ->
                 `Assoc
                   [ ("name", str d.name); ("description", str d.description) ])
               Deny.detectors) );
      ])

(* The check at signing (note_checks.ml): the deny layer over the exact bytes to be signed. A trip
   counts against the entry that tripped and names the part it tripped in; it never edits. *)
let signing_backstop c text =
  let r =
    Note_checks.backstop
      ~entries:(Store.deny_list (log c))
      ~allowed:(circle_names c) text
  in
  Option.iter
    (fun (r : Note_checks.refusal) ->
      Option.iter (Store.deny_tripped (log c)) r.entry)
    r;
  r

(* A note's Questions part goes out as it does (DES-51007, What replaces what): each question an
   item addressed to the circle, from the agent, about the note's envelope [note_hash], signed
   through the deny layer as every circle item is. A question the deny layer refuses is not sent;
   the note itself already passed the check at signing, so that is a backstop that should never
   fire. *)
let send_note_questions c ~note_hash text =
  match self_identity c with
  | None -> ()
  | Some me ->
      let module I = Store.Items in
      List.iter
        (fun question ->
          let item : Item.t =
            {
              kind = "question";
              subject = Some "note_question";
              voice = "agent";
              title = question;
              detail = "";
              about = Some note_hash;
              options = [];
              default = None;
              deadline = None;
              adopted = None;
            }
          in
          if deny_check c (Item.words item) = None then (
            let id = "item-" ^ Store.random_id () in
            I.add (log c) ~id ~author:me ~item ~to_:Circle
              ~created_at:(Time_fmt.now ()) ();
            match
              sign c ~kind:"item" (Item.item_body ~to_:Circle ~keys:[] item)
            with
            | Error _ -> I.discard (log c) id
            | Ok hash ->
                let at =
                  Option.value (envelope_time c hash) ~default:(Time_fmt.now ())
                in
                I.sent (log c) id ~hash ~at
                  ~closes_unix:
                    (Item.closes_at ~kind:"question" ~sent:(unix at)
                       ~deadline:None ~answered:false)))
        (Note_checks.questions text)

let add_log c ~note_id entries =
  List.iter
    (fun e -> Store.Checks.add (log c) ~note_id (Yojson.Safe.to_string e))
    entries

(* One way a failure is reported (docs/design.md): every job's failure is a problem in one record,
   which the header of Notes reads while it is open, a note's Log reads for a problem in writing,
   checking or sending that note, and the status note is could_not_run. *)
module Problems = struct
  module P = Store.Problems

  let json (p : P.problem) : Yojson.Safe.t =
    `Assoc
      ([ ("id", str p.p_id); ("job", str p.job); ("kind", str p.kind) ]
      @ opt "source" p.p_source @ opt "detail" p.p_detail
      @ [
          ("first_seen_at", str p.first_seen_at);
          ("last_seen_at", str p.last_seen_at);
          ("count", `Int p.count);
        ]
      @ opt "closed_at" p.closed_at)

  let limit = 100

  let list c query =
    let open_only =
      match List.assoc_opt "open" query with
      | Some ("true" | "1") -> true
      | _ -> false
    in
    ok (`List (List.map json (P.list (log c) ~open_only ~limit ())))

  (* The member's own words for a problem, where a page says why something did not happen. *)
  let sentence (p : P.problem) =
    match p.kind with
    | "signed_out" -> "Your coding agent is signed out."
    | "model_unavailable" -> "The model was unavailable."
    | "out_of_budget" -> "Your agent is out of budget."
    | "source_failed" -> (
        let why = match p.p_detail with Some d -> ": " ^ d | None -> "" in
        match p.p_source with
        | Some s -> s ^ " could not be read" ^ why ^ "."
        | None -> "A source could not be read" ^ why ^ ".")
    | "relay_unreachable" -> "The relay could not be reached."
    | "signing_refused" -> "The check at signing refused the note."
    | _ -> "The note could not be written."

  (* The one function every job calls. A problem in writing, checking or sending a note is also an
     entry of that note's Log, unless [logged] says the job wrote a more particular entry itself. *)
  let report c ?note_id ?(logged = false) ?source ~job ~kind () =
    let p = P.report (log c) ?source ~job ~kind () in
    (match note_id with
    | Some note_id when not logged ->
        add_log c ~note_id
          [
            Note_checks.entry ~at:(Time_fmt.now ()) "problem"
              [ ("problem", str kind) ];
          ]
    | _ -> ());
    p

  let resolve c ?source ~job () = P.resolve (log c) ?source ~job ()
end

(* writing as the person *)

let post c body =
  let text =
    String.trim (Option.value (string_field "text" body) ~default:"")
  in
  let reply_to = string_field "reply_to" body in
  let parent = Option.bind reply_to (find_msg c) in
  match self_identity c with
  | _ when text = "" -> invalid ~field:"text" "empty" "Write something first."
  | _ when reply_to <> None && parent = None ->
      invalid ~field:"reply_to" "unknown_reply_to" "That message is gone."
  | None -> invalid "not_joined" "This node has not joined a circle yet."
  | Some _ -> (
      let kind = "summary" in
      let refused rule =
        let o : Store.outbound =
          {
            o_id = Store.local_hash ();
            o_kind = kind;
            voice = "person";
            reply_to;
            o_text = None;
            status = "refused";
            refused_rule = Some rule;
            o_created_at = Time_fmt.now ();
            posted_hash = None;
            held_reason = None;
          }
        in
        Store.add_outbound (log c) o;
        ok ~status:201 (message_json c (of_outbound c o))
      in
      match deny_check c text with
      | Some rule -> refused rule
      | None -> (
          let body =
            Content.summary_body ~text ~voice:"person" ?reply_to
              ~stage:(Store.Stages.stage (log c))
              ()
          in
          match sign c ~kind body with
          | Error e -> invalid "not_signed" e
          | Ok hash -> (
              (* A reply sent answers the draft the member's agent kept for them. *)
              Option.iter
                (fun h ->
                  Store.Reviews.clear_agent_answer (log c) h;
                  Store.Reviews.end_draft (log c) h)
                reply_to;
              match find_msg c hash with
              | Some m -> ok ~status:201 (message_json c m)
              | None -> invalid "not_signed" "The message was not stored.")))

(* routing *)

let limit_of q =
  match List.assoc_opt "limit" q with
  | None -> Ok 50
  | Some v -> (
      match int_of_string_opt v with
      | Some n when n >= 1 && n <= 200 -> Ok n
      | _ ->
          Error (invalid ~field:"limit" "limit" "limit is between 1 and 200."))

let feed ?(extra = fun _ ~before:_ ~limit:_ -> []) c q =
  match limit_of q with
  | Error e -> e
  | Ok limit ->
      (* The cursor in the protocol's form, so the log compares it as it stores created_at. *)
      let before =
        Option.map
          (fun b -> Time_fmt.of_unix (unix b))
          (List.assoc_opt "before" q)
      in
      let logged =
        View.page ?before ~kinds:Content.feed_kinds ~limit (log c) c.fold
        |> List.map (of_row c)
      in
      let held =
        List.filter
          (fun m ->
            match before with
            | Some b -> unix m.created_at < unix b
            | None -> true)
          (refused c @ extra c ~before ~limit)
      in
      newest_first (logged @ held)
      |> List.filteri (fun i _ -> i < limit)
      |> List.map (item_json c)
      |> fun l -> ok (`List l)

(* The phone web app the mailing relay serves under /app/ (docs/protocol.md, The phone): one of
   this node's own relays when it mails, else the first mailing relay the circle names. *)
let phone_app_url c =
  let ours = List.map (fun (r : Log.relay_row) -> r.url) (Log.relays (log c)) in
  let mailing =
    Hashtbl.fold
      (fun _ (r : Bodies.relay) acc -> if r.mailer then r.url :: acc else acc)
      c.fold.relays []
    |> List.sort compare
  in
  let pick =
    match List.find_opt (fun u -> List.mem u ours) mailing with
    | Some u -> Some u
    | None -> List.nth_opt mailing 0
  in
  Option.map
    (fun u ->
      let n = String.length u in
      (if n > 0 && u.[n - 1] = '/' then String.sub u 0 (n - 1) else u) ^ "/app/")
    pick

(* The first note, from the moment the setup chat starts it until it goes out (docs/design.md, The
   setup chat and the first note). The chat makes its row (Store.Notes.start), so it is a note page
   from the start: until the run hands its first version over the page shows how far it has got,
   the steps of the run or why there is no note yet. The newest tick since the start says the run
   had nothing to say; an open problem in the work run says why it could not write one; and with
   neither, no run in flight and none asked for, nothing is writing it (ISS-48141). *)
module First_note = struct
  let progress_file c =
    Filename.concat c.node.dir "behaviors/nightly/progress.json"

  let steps c =
    match Yojson.Safe.from_file (progress_file c) with
    | `Assoc f ->
        let step =
          match List.assoc_opt "step" f with
          | Some (`String s)
            when List.mem s [ "reading"; "writing"; "checking" ] ->
              [ ("step", str s) ]
          | _ -> []
        in
        let sources =
          match List.assoc_opt "sources" f with Some (`List l) -> l | _ -> []
        in
        step @ [ ("sources", `List sources) ]
    | _ | (exception (Yojson.Json_error _ | Sys_error _)) ->
        [ ("sources", `List []) ]

  (* Whether this member's first summary has gone out, asked of the log by their keys. *)
  let shared c =
    match Option.map (keys_of c) (self_identity c) with
    | None | Some [] -> false
    | Some keys ->
        Log.exists (log c)
          ~where:
            ("kind = 'summary' AND author IN (" ^ Log.placeholders keys ^ ")")
          (List.map Log.s keys)

  let state c ~started =
    let tick =
      match Store.ticks (log c) ~limit:1 with
      | [ t ] when t.t_at >= started -> Some t
      | _ -> None
    in
    (* A problem in writing seen since the start, and after the newest tick, says why. *)
    let problem =
      List.find_opt
        (fun (p : Store.Problems.problem) ->
          p.job = "write_version" && p.last_seen_at >= started
          && match tick with Some t -> p.last_seen_at >= t.t_at | None -> true)
        (Store.Problems.open_ (log c))
    in
    match (problem, tick) with
    | Some p, _ -> `Failed (Problems.sentence p)
    | None, Some { outcome = Store.Quiet; _ } -> `No_activity
    | None, _ when not (Store.nightly_run_in_progress (log c)) -> `Stopped
    | None, _ -> `Writing

  (* The first note's row while the run has not handed it over, with when the chat started it. *)
  let pending c =
    match
      (Store.Notes.pending (log c), Store.Setup.first_note_started (log c))
    with
    | Some n, Some started -> Some (n, started)
    | _ -> None

  (* note.progress: present on the first note's page until the run hands it over. *)
  let progress c (n : Store.Notes.note) : Yojson.Safe.t option =
    match pending c with
    | Some (p, started) when p.n_id = n.n_id ->
        Some
          (`Assoc
             (match state c ~started with
             | `No_activity ->
                 [ ("state", str "no_activity"); ("sources", `List []) ]
             | `Failed m ->
                 [
                   ("state", str "failed");
                   ("sources", `List []);
                   ("message", str m);
                 ]
             | `Stopped -> [ ("state", str "stopped"); ("sources", `List []) ]
             | `Writing -> ("state", str "writing") :: steps c))
    | _ -> None

  (* status.first_note: absent before the chat starts the note and after it goes out. *)
  let ref_ c : Yojson.Safe.t option =
    if shared c then None
    else
      match
        Option.bind (Store.Notes.first_id (log c)) (Store.Notes.find (log c))
      with
      | Some n ->
          Some (`Assoc [ ("id", str n.n_id); ("written_at", str n.written_at) ])
      | None -> None

  let no_activity c =
    match pending c with
    | Some (_, started) -> state c ~started = `No_activity
    | None -> false

  (* The navigation is hidden while setup is open, and only then (Store.Setup.finished): a member
     whose setup is done is never locked out of the app for want of a summary that has gone out.
     ISS-47299 *)
  let hides_navigation c = not (Store.Setup.finished (log c))
end

let status c =
  let me = self_identity c in
  let names =
    match Option.bind me (card c) with
    | Some k ->
        [ ("member_name", str k.card_name); ("agent_name", str k.agent_name) ]
    | None -> []
  in
  ok
    (`Assoc
       (names
       @ [
           ("first_run", `Bool (First_note.hides_navigation c));
           ( "notes_awaiting_approval",
             `Int (List.length (Store.Notes.waiting (log c))) );
         ]
       @ (match First_note.ref_ c with
         | Some j -> [ ("first_note", j) ]
         | None -> [])
       @
       match phone_app_url c with
       | Some u -> [ ("phone_app_url", str u) ]
       | None -> []))

(* The deny list changed: write it for the member's phone, which the next sync posts. A list the
   node cannot write yet (not admitted, a keystore that will not answer) is written by a later pass. *)
let share_deny c =
  match Deny_share.publish c.node with
  | Ok (Some _) -> c.on_write ()
  | Ok None | Error _ -> ()

let add_deny c body =
  let kind = string_field "kind" body in
  let value =
    String.trim (Option.value (string_field "value" body) ~default:"")
  in
  match kind with
  | None -> invalid ~field:"kind" "kind" "Choose a kind."
  | Some k when not (List.mem k Deny.kinds) ->
      invalid ~field:"kind" "kind" "Choose a kind."
  | Some _ when value = "" -> invalid ~field:"value" "empty" "Enter a value."
  | Some k -> (
      match
        if k = "pattern" then Result.map ignore (Deny.compile_pattern value)
        else Ok ()
      with
      | Error m -> invalid ~field:"value" "pattern" m
      | Ok () ->
          if
            List.exists
              (fun (e : Store.deny_entry) -> e.d_kind = k && e.value = value)
              (Store.deny_list (log c))
          then invalid ~field:"value" "duplicate" "Already on the list."
          else
            let e = Store.add_deny (log c) ~kind:k ~value () in
            share_deny c;
            ok ~status:201 (deny_json e))

(* phones: the phrase signs one device body and is dropped; it is never logged or echoed. *)

let add_phone c body =
  let code = Option.value (string_field "pairing_code" body) ~default:"" in
  let phrase = Option.value (string_field "recovery_phrase" body) ~default:"" in
  match Digestif_daily.Phones.add c.node ~phrase ~code with
  | Error (Pairing_code m) -> invalid ~field:"pairing_code" "invalid" m
  | Error (Recovery_phrase m) -> invalid ~field:"recovery_phrase" "invalid" m
  | Error (Not_signed m) -> invalid "not_signed" m
  | Ok (hash, key) ->
      c.on_write ();
      ok ~status:201
        (`Assoc
           [
             ("key", str key);
             ("role", str (Bodies.role_to_string Bodies.Device));
             ( "admitted_at",
               str (Option.value (envelope_time c hash) ~default:"") );
             ("phone", `Bool true);
           ])

(* The member experience (DES-37265, docs/design.md): one section per row that builds it, each a
   module of its own, so the rows edit disjoint lines. Every operation the spec adds for them is
   routed below; a section not yet built answers 501 not_built, naming its issue. A section that
   adds fields to a response the node already serves returns them from a function `route` folds
   in, so no row edits another row's function. *)

let with_found v f = match v with Some x -> f x | None -> not_found ()
let not_built issue = errors 501 "not_built" ("Not built yet: " ^ issue ^ ".")

(* Fields a section adds to an object, or to every object of a list. *)
let extend_json extra = function `Assoc f -> `Assoc (f @ extra) | j -> j

let extend (r : response) extra =
  match r.body with
  | Some j -> { r with body = Some (extend_json extra j) }
  | None -> r

let extend_each f (r : response) =
  match r.body with
  | Some (`List l) ->
      { r with body = Some (`List (List.map (fun j -> extend_json (f j) j) l)) }
  | _ -> r

let with_found_opt v f = match v with Some x -> f x | None -> not_found ()

let string_of name = function
  | `Assoc f -> (
      match List.assoc_opt name f with Some (`String s) -> s | _ -> "")
  | _ -> ""

(* ISS-38781: the record and where each note starts (DES-37265, The record and where each
   note starts). The work run reads it; no operation of the local API does. *)
module Record = struct end

(* ISS-38777: checks find and fix (DES-37265, Checks find and fix): the note's Log. Each entry
   names a part and what a check removed from it, never text (note_checks.ml). A note is named by its
   held row or, once signed, by its envelope hash. *)
module Checks = struct
  let log c id =
    match Store.Checks.entries (log c) ~note_id:id with
    | [] when Store.Notes.find (log c) id = None -> not_found ()
    | entries -> ok (`List (List.map Yojson.Safe.from_string entries))
end

(* ISS-38778: repositories and commit authors (DES-37265, Repositories). *)
module Repositories = struct
  module R = Store.Repositories

  (* The page reads the stored scan (Machine_scan), which the node's pass retakes, so a clone made
     since shows up within Machine_scan.max_age (within Machine_scan.read_max_age on a node running
     only digestif ui); a node whose sources were set by hand (the demo circle) is never scanned. *)
  let scanned c = not (Machine_scan.fixed (log c))
  let refresh c = Machine_scan.ensure ~now:c.now c.node

  let organization_json (o : R.organization) : Yojson.Safe.t =
    `Assoc
      [
        ("id", str o.o_id);
        ("name", str o.o_name);
        ("choice", str o.choice);
        ("repositories", `Int o.repositories);
      ]

  (* [path] is one clone's, as the scan stored it (with ~ for the home directory); the Undecided
     view names it beside how many others there are (DES-37153, The new-repositories ask). *)
  let repository_json (r : R.repository) : Yojson.Safe.t =
    `Assoc
      ([
         ("id", str r.r_id);
         ("organization_id", str r.organization_id);
         ("name", str r.r_name);
         ("status", str r.status);
         ("found_at", str r.found_at);
         ("clone_count", `Int (List.length r.r_paths));
       ]
      @ opt "path" (match r.r_paths with p :: _ -> Some p | [] -> None)
      (* ISS-42314: how a repository found after setup turned up, and its last own commit; each
         absent when there is none. *)
      @ List.filter_map
          (fun (k, v) -> Option.map (fun v -> (k, str v)) v)
          [
            ("found_by", r.found_by);
            ("last_own_commit_at", r.last_own_commit_at);
          ])

  let author_json (a : R.author) : Yojson.Safe.t =
    `Assoc
      ([ ("id", str a.a_id); ("email", str a.email) ]
      @ opt "name" a.a_name
      @ [ ("label", str a.label); ("member_set", `Bool a.member_set) ])

  (* One of an enum's values from a body field, or 422 naming the field. *)
  let enum_field name values body =
    match string_field name body with
    | Some v when List.mem v values -> Ok v
    | _ ->
        Error
          (invalid ~field:name name
             ("Choose one of: " ^ String.concat ", " values ^ "."))

  (* ISS-41944: one page of organizations, by name. *)
  let organizations c q =
    let known id = R.organization (log c) id <> None in
    match
      let* limit = limit_param q ~default:100 in
      let* after = cursor_param q ~known in
      Ok (limit, after)
    with
    | Error e -> e
    | Ok (limit, after) ->
        refresh c;
        ok
          (`List
             (List.map organization_json
                (R.organizations (log c) ?after ~limit)))

  let set_organization c id body =
    with_found_opt
      (R.organization (log c) id)
      (fun _ ->
        match enum_field "choice" R.choices body with
        | Error e -> e
        | Ok choice ->
            R.set_choice (log c) id choice;
            with_found_opt
              (R.organization (log c) id)
              (fun o -> ok (organization_json o)))

  let int_param q name ~default ~min ?max () =
    match List.assoc_opt name q with
    | None | Some "" -> Ok default
    | Some v -> (
        match int_of_string_opt v with
        | Some n
          when n >= min && Option.fold ~none:true ~some:(fun m -> n <= m) max ->
            Ok n
        | _ -> Error (invalid ~field:name name ("Not a valid " ^ name ^ ".")))

  let nonempty q k =
    match List.assoc_opt k q with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None

  let repositories c q =
    let nonempty = nonempty q in
    let result =
      let* limit = int_param q "limit" ~default:50 ~min:1 ~max:200 () in
      let* offset = int_param q "offset" ~default:0 ~min:0 () in
      let* status =
        match nonempty "status" with
        | Some s when not (List.mem s R.statuses) ->
            Error (invalid ~field:"status" "status" "Unknown status.")
        | s -> Ok s
      in
      let* after =
        cursor_param q ~known:(fun id -> R.repository (log c) id <> None)
      in
      (* ISS-41944: a cursor reads the page from the index; an offset still reads its rows in. *)
      let offset = if after = None then offset else 0 in
      Ok (limit, offset, status, after)
    in
    match result with
    | Error e -> e
    | Ok (limit, offset, status, after) ->
        refresh c;
        R.repositories (log c) ?q:(nonempty "q") ?status
          ?organization_id:(nonempty "organization_id")
          ?after ~limit ~offset
        |> List.map repository_json
        |> fun l -> ok (`List l)

  (* ISS-38823: the status chips' counts, under the list's own search and organization. *)
  let counts c q =
    refresh c;
    R.counts (log c) ?q:(nonempty q "q")
      ?organization_id:(nonempty q "organization_id")
    |> List.map (fun (s, n) -> `Assoc [ ("status", str s); ("count", `Int n) ])
    |> fun l -> ok (`List l)

  let set_repository c id body =
    with_found_opt
      (R.repository (log c) id)
      (fun _ ->
        match enum_field "status" R.statuses body with
        | Error e -> e
        | Ok status ->
            R.set_status (log c) id status;
            with_found_opt
              (R.repository (log c) id)
              (fun r -> ok (repository_json r)))

  (* The scan's proposal enters the list the first time it is read. *)
  let authors c =
    if scanned c && not (R.authors_proposed (log c)) then begin
      refresh c;
      Machine_scan.propose_authors ~now:c.now (log c)
    end;
    ok (`List (List.map author_json (R.authors (log c))))

  let add_author c body =
    let email =
      String.trim (Option.value (string_field "email" body) ~default:"")
    in
    let name =
      match string_field "name" body with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> None
    in
    if email = "" then invalid ~field:"email" "empty" "Enter an email."
    else
      match enum_field "label" R.labels body with
      | Error e -> e
      | Ok label -> (
          match R.add_author (log c) ~email ~name ~label with
          | Error `Duplicate ->
              invalid ~field:"email" "duplicate"
                "That email is already an author."
          | Ok id ->
              with_found_opt
                (R.author (log c) id)
                (fun a -> ok ~status:201 (author_json a)))

  let label_author c id body =
    with_found_opt
      (R.author (log c) id)
      (fun _ ->
        match enum_field "label" R.labels body with
        | Error e -> e
        | Ok label ->
            R.label_author (log c) id label;
            with_found_opt (R.author (log c) id) (fun a -> ok (author_json a)))

  let remove_author c id =
    with_found_opt
      (R.author (log c) id)
      (fun _ ->
        R.remove_author (log c) id;
        no_content)
end

(* ISS-38782: Notes and the note page (DES-37265, Approve and Edit, Rules and Learnings,
   Status and Shared, Approval and sending are two small jobs).

   A note is written once and waits. The agent hands it over checked, and approves it in the same
   act when auto approval is saved (`digestif note --approve`); the node never reads the setting
   for it. The member approves exactly the version on the page, or edits it: an edit is a new
   version, both checks run on it in the check behavior, and Save & approve goes out only if they
   removed nothing. Sending is a job of its own: every pass signs each approved note not yet
   signed, whoever approved it, and the sync posts it to every relay and retries; Shared is when a
   relay took it. *)
module Notes = struct
  module N = Store.Notes

  let with_version_id (v : N.version) (e : Yojson.Safe.t) =
    match e with
    | `Assoc f -> `Assoc (f @ [ ("version_id", str v.v_id) ])
    | j -> j

  (* When the send reached the circle: the first relay that took the envelope. *)
  let shared_at c (n : N.note) =
    match n.n_posted_hash with
    | None -> None
    | Some h -> (
        match Log.sightings (log c) h with
        | [] -> None
        | l -> (
            match
              List.sort compare (List.filter_map (fun (_, _, at) -> at) l)
            with
            | at :: _ -> Some at
            | [] -> n.approved_at))

  let newest c (n : N.note) =
    match List.rev (N.versions (log c) ~note_id:n.n_id) with
    | v :: _ -> Some v
    | [] -> None

  let shown_by_default c (n : N.note) =
    List.find_opt N.passed (List.rev (N.versions (log c) ~note_id:n.n_id))

  let version_json (v : N.version) : Yojson.Safe.t =
    `Assoc
      ([
         ("id", str v.v_id);
         ("number", `Int v.number);
         ("voice", str v.v_voice);
         ("created_at", str v.v_created_at);
         ("checks", `Assoc [ ("pii", str v.pii); ("rules", str v.rules) ]);
       ]
      @ (if N.passed v then opt "text" v.v_text else [])
      @ [ ("removed", `Bool v.removed) ])

  (* The version on the page may be approved: it is the newest, or one of the pair a note written
     in two versions still offers (ISS-51009). [pair] is that pair, when there is one. *)
  let approvable ?pair (n : N.note) ~(newest : N.version option) (v : N.version)
      =
    let of_pair =
      match pair with
      | Some ((a : N.version), (b : N.version)) ->
          a.v_id = v.v_id || b.v_id = v.v_id
      | None -> false
    in
    n.n_status = "waiting" && N.passed v
    && (of_pair
       || Option.map (fun (x : N.version) -> x.v_id) newest = Some v.v_id)
    && Option.value v.v_text ~default:"" <> ""

  let note_json c ?shown (n : N.note) : Yojson.Safe.t =
    let newest = newest c n in
    let pair = if n.n_status = "waiting" then N.pair (log c) n else None in
    let shown =
      match shown with Some v -> Some v | None -> shown_by_default c n
    in
    let newer =
      match (shown, newest) with
      | Some s, Some x when x.number > s.number ->
          [ ("newer_version_id", str x.v_id) ]
      | _ -> []
    in
    `Assoc
      ([
         ("id", str n.n_id);
         ("written_at", str n.written_at);
         ("status", str n.n_status);
       ]
      @ opt "shared_at" (shared_at c n)
      @ (match shown with
        | Some v -> [ ("version", version_json v) ]
        | None -> [])
      @ newer
      @ (match First_note.progress c n with
        | Some p -> [ ("progress", p) ]
        | None -> [])
      @ (match pair with
        | Some (a, b) -> [ ("pair", `List [ version_json a; version_json b ]) ]
        | None -> [])
      @ [
          ( "can_approve",
            `Bool
              (match shown with
              | Some v -> approvable ?pair n ~newest v
              | None -> false) );
          ("can_edit", `Bool (n.n_status = "waiting" && newest <> None));
        ]
      @ opt "not_sent" n.n_held_reason)

  let summary_json c (n : N.note) : Yojson.Safe.t =
    `Assoc
      ([
         ("id", str n.n_id);
         ("written_at", str n.written_at);
         ("status", str n.n_status);
       ]
      @ opt "shared_at" (shared_at c n)
      @
      match Option.bind (shown_by_default c n) (fun v -> v.v_text) with
      | Some t -> [ ("preview", str (Note_preview.of_text t)) ]
      | None -> [])

  (* Notes, one page at a time, the newest first (ISS-41988), beside the auto approval suggestion. *)
  let list c query =
    let known id = N.find (log c) id <> None in
    match
      let* limit = limit_param query ~default:100 in
      let* after = cursor_param query ~known in
      Ok (limit, after)
    with
    | Error e -> e
    | Ok (limit, after) ->
        ok
          (`Assoc
             [
               ( "notes",
                 `List (List.map (summary_json c) (N.all (log c) ?after ~limit))
               );
               ("suggest_auto_approval", `Bool (N.suggest (log c)));
               ("no_activity", `Bool (First_note.no_activity c));
             ])

  let note c id query =
    with_found
      (N.find (log c) id)
      (fun n ->
        match List.assoc_opt "version" query with
        | None -> ok (note_json c n)
        | Some vid -> (
            match N.version (log c) vid with
            | Some v when v.v_note = n.n_id -> ok (note_json c ~shown:v n)
            | _ -> not_found ()))

  (* The member approved [v]: the note is theirs to send. An approval of the agent's own words
     counts toward the suggestion; one of an edited note restarts it. *)
  let approve_as_member c (n : N.note) (v : N.version) =
    N.approve (log c) ~note_id:n.n_id ~version_id:v.v_id ~status:"approved";
    let edited =
      List.exists
        (fun (x : N.version) -> x.v_voice = "person")
        (N.versions (log c) ~note_id:n.n_id)
    in
    if edited then N.restart_count (log c)
    else N.set_unchanged (log c) (N.unchanged (log c) + 1);
    add_log c ~note_id:n.n_id
      [
        with_version_id v
          (Note_checks.entry ~at:(Time_fmt.now ()) "approved" []);
      ];
    c.on_write ()

  let bool_field name body ~default =
    match field name body with
    | Some (`Bool b) -> Ok b
    | None | Some `Null -> Ok default
    | Some _ -> Error (invalid ~field:name name (name ^ " is true or false."))

  let add_version c id body =
    with_found
      (N.find (log c) id)
      (fun n ->
        let text =
          String.trim (Option.value (string_field "text" body) ~default:"")
        in
        let edited = string_field "edited_version_id" body in
        match bool_field "approve" body ~default:false with
        | Error e -> e
        | Ok approve -> (
            match
              Option.bind edited (fun e ->
                  match N.version (log c) e with
                  | Some v when v.v_note = n.n_id -> Some v
                  | _ -> None)
            with
            | _ when n.n_status <> "waiting" ->
                invalid "not_waiting" "This note is not waiting."
            | _ when text = "" ->
                invalid ~field:"text" "empty" "Write the note."
            | None ->
                invalid ~field:"edited_version_id" "edited_version_id"
                  "Name the version you edited."
            | Some reading ->
                let v =
                  N.add_edit (log c) ~note_id:n.n_id ~edited:reading.v_id
                    ~approve text
                in
                N.restart_count (log c);
                add_log c ~note_id:n.n_id
                  [
                    with_version_id v
                      (Note_checks.entry ~at:v.v_created_at "edited" []);
                  ];
                c.on_write ();
                with_found
                  (N.find (log c) id)
                  (fun n -> ok ~status:201 (note_json c ~shown:reading n))))

  let approve c id body =
    with_found
      (N.find (log c) id)
      (fun n ->
        let newest = newest c n in
        let pair = N.pair (log c) n in
        match
          Option.bind (string_field "version_id" body) (N.version (log c))
        with
        | _ when n.n_status <> "waiting" ->
            invalid "not_waiting" "This note is not waiting."
        | Some v when v.v_note = n.n_id && approvable ?pair n ~newest v ->
            approve_as_member c n v;
            with_found
              (N.find (log c) id)
              (fun n -> ok (note_json c ~shown:v n))
        | Some v when v.v_note = n.n_id ->
            invalid ~field:"version_id" "not_approvable"
              "There is nothing to approve until the newest version's checks \
               pass."
        | _ ->
            invalid ~field:"version_id" "version_id"
              "No such version of this note.")

  let dismiss_suggestion c =
    N.restart_count (log c);
    no_content

  (* Dismiss: the member discards a waiting note before approving it. ISS-47299 *)
  let dismiss c id =
    with_found
      (N.find (log c) id)
      (fun n ->
        if not (N.dismiss (log c) ~note_id:n.n_id) then
          invalid "not_waiting" "This note is not waiting."
        else begin
          add_log c ~note_id:n.n_id
            [ Note_checks.entry ~at:(Time_fmt.now ()) "dismissed" [] ];
          with_found (N.find (log c) id) (fun n -> ok (note_json c n))
        end)

  let versions c id =
    with_found
      (N.find (log c) id)
      (fun n ->
        ok (`List (List.map version_json (N.versions (log c) ~note_id:n.n_id))))

  (* Write a note now: the note writer runs on the next pass rather than at Note time. *)
  let run_now c =
    Store.request_nightly_run (log c);
    c.on_write ();
    { status = 202; body = None }

  (* A note as the feed shows it: its own message until it is signed, at the note's id, and the
     signed summary once it is. ISS-47299 *)
  let message_of c (n : N.note) : msg =
    match Option.bind n.n_posted_hash (Log.find (log c)) with
    | Some r -> of_row c r
    | None ->
        let shown = shown_by_default c n in
        {
          hash = n.n_id;
          kind = "summary";
          voice =
            (match newest c n with Some v -> v.v_voice | None -> "agent");
          author = Option.value (self_identity c) ~default:"";
          created_at = n.written_at;
          status =
            (match n.n_status with
            | "waiting" -> "awaiting_approval"
            | "dismissed" -> "dismissed"
            | _ -> "sending");
          text = Option.bind shown (fun v -> v.v_text);
          reply_to = None;
          refused_rule = None;
          held_reason = n.n_held_reason;
        }

  (* The feed's notes not yet signed, beside the messages the log holds. *)
  let in_feed c ~before ~limit =
    List.map (message_of c) (N.in_feed (log c) ?before ~limit)

  (* GET /messages/:hash: a message, carrying the note it was sent as; or a note by its id. *)
  let message c hash =
    match find_msg c hash with
    | Some m ->
        ok
          (message_json c m
             ?note_id:
               (Option.map
                  (fun (n : N.note) -> n.n_id)
                  (N.of_posted (log c) m.hash)))
    | None ->
        with_found
          (N.find (log c) hash)
          (fun n -> ok (message_json c ~note_id:n.n_id (message_of c n)))

  let approval_json c : Yojson.Safe.t =
    `Assoc
      ([ ("setting", str (N.approval (log c))) ]
      @ opt "updated_at" (N.approval_updated_at (log c)))

  let approval c = ok (approval_json c)

  let set_approval c body =
    match string_field "setting" body with
    | Some s when List.mem s N.settings ->
        N.set_approval (log c) s;
        ok (approval_json c)
    | _ ->
        invalid ~field:"setting" "setting"
          "Choose Every note waits for me or Auto approve every note."

  let learnings_json c : Yojson.Safe.t =
    let d = N.learnings (log c) in
    `Assoc ([ ("text", str d.text) ] @ opt "updated_at" d.updated_at)

  let learnings c = ok (learnings_json c)

  let set_learnings c body =
    N.set_learnings (log c)
      (String.trim (Option.value (string_field "text" body) ~default:""));
    ok (learnings_json c)

  let check_job check = check ^ "_check"

  (* The problem kind a check that could not finish is reported as: the agent signed out, out of
     budget, or anything else the model did not answer. *)
  let problem_kind = function
    | ("signed_out" | "out_of_budget") as kind -> kind
    | _ -> "model_unavailable"

  (* A check could not finish on [v]: it stays unseen and unapproved, its Log says so and when the
     checks alone run again, and the check's problem stays open until they pass. *)
  let could_not_finish c ?(runs = []) (v : N.version) ~check ~problem ~retry =
    let kind = problem_kind problem in
    add_log c ~note_id:v.v_note
      (List.map (with_version_id v)
         (runs
         @ [
             Note_checks.entry ~at:(Time_fmt.now ()) "could_not_finish"
               [
                 ("check", str check);
                 ("problem", str kind);
                 ("retry_at", str (Time_fmt.of_unix retry));
               ];
           ]));
    ignore
      (Problems.report c ~note_id:v.v_note ~logged:true ~job:(check_job check)
         ~kind ())

  let checks_passed c =
    Problems.resolve c ~job:"pii_check" ();
    Problems.resolve c ~job:"rules_check" ()

  (* `digestif note`: the agent hands over a checked note, approving it when auto approval is
     saved. With [could_not_finish] a check could not finish on what it wrote: the note is kept
     with that version unseen, and the check behavior runs the checks alone again in an hour.
     Answers the note's id, which names its page and its Log. *)
  let submit ?(runs = []) ?could_not_finish:cnf ?(ends = []) ?prompt ?pair
      ~approve c text =
    let at = Time_fmt.now () in
    (* A note written in two versions waits for its member whatever the approval setting: the
       pick is theirs (ISS-51009). *)
    let pair = if cnf = None then pair else None in
    let approve = approve && cnf = None && pair = None in
    let status = if approve then "auto_approved" else "waiting" in
    let retry = c.now +. N.retry_hour in
    let id, written =
      N.add (log c) ~at
        ?could_not_finish:(Option.map (fun (check, _) -> (check, retry)) cnf)
        ?prompt
        ?pair:
          (Option.map
             (fun (suggestion, sprompt, stext, _) ->
               (suggestion, (sprompt, stext)))
             pair)
        ~status text
    in
    let v, others =
      match (written, pair) with
      | [ a; b ], Some (_, sprompt, _, sruns) ->
          let current, suggested =
            if a.prompt_id = Some sprompt then (b, a) else (a, b)
          in
          (current, [ (suggested, sruns) ])
      | v :: _, _ -> (v, [])
      | [], _ -> assert false
    in
    (* Where the note ends moves each source's start once it is approved: now, when the agent
       approved it, else when the member does (Store.Notes.approve). *)
    Store.Record.set_ends (log c) ~note_id:id ends;
    if approve then Store.Record.approve (log c) ~note_id:id;
    add_log c ~note_id:id
      (List.map (with_version_id v)
         ((Note_checks.written ~at :: (if cnf = None then runs else []))
         @ if approve then [ Note_checks.entry ~at "auto_approved" [] ] else []
         ));
    List.iter
      (fun (o, oruns) ->
        add_log c ~note_id:id
          (List.map (with_version_id o) (Note_checks.written ~at :: oruns)))
      others;
    Problems.resolve c ~job:"write_version" ();
    (match cnf with
    | Some (check, problem) -> could_not_finish c ~runs v ~check ~problem ~retry
    | None -> checks_passed c);
    Store.add_tick (log c) ~at:(Time_fmt.of_unix c.now)
      (if approve then Store.Posted else Store.Held);
    c.on_write ();
    Ok id

  (* What the checks removed from an edit, in the page's words: why Save & approve did not go out. *)
  let removed_reason (runs : Yojson.Safe.t list) =
    let get k = function `Assoc f -> List.assoc_opt k f | _ -> None in
    let count check =
      List.fold_left
        (fun acc r ->
          if get "check" r = Some (`String check) then
            match get "removals" r with
            | Some (`List l) ->
                List.fold_left
                  (fun acc x ->
                    match get "count" x with
                    | Some (`Int n) -> acc + n
                    | _ -> acc)
                  acc l
            | _ -> acc
          else acc)
        0 runs
    in
    let parts =
      List.fold_left
        (fun acc r ->
          match get "removals" r with
          | Some (`List l) ->
              List.fold_left
                (fun acc x ->
                  match get "part" x with
                  | Some (`String p) when not (List.mem p acc) -> acc @ [ p ]
                  | _ -> acc)
                acc l
          | _ -> acc)
        [] runs
    in
    let said =
      List.filter_map
        (fun (check, name) ->
          match count check with
          | 0 -> None
          | n -> Some (Printf.sprintf "the %s check removed %d" name n))
        [ ("pii", "PII"); ("rules", "Rules") ]
    in
    let and_ = function
      | [] -> ""
      | [ x ] -> x
      | l ->
          String.concat ", " (List.filteri (fun i _ -> i < List.length l - 1) l)
          ^ " and "
          ^ List.nth l (List.length l - 1)
    in
    let who =
      match said with [] -> "the checks removed something" | l -> and_ l
    in
    Printf.sprintf
      "Not sent. %s from your edit%s. Approve sends the text below."
      (String.capitalize_ascii who)
      (match parts with [] -> "" | l -> ", in " ^ and_ l)

  type checked =
    | Passed of { text : string; removed : bool }
    | Could_not_finish of { check : string; problem : string }
        (** [problem]: signed_out, out_of_budget or model_unavailable. *)

  (* The agent's own version, whose checks could not finish when it was written, passed them on a
     later run: it waits for the member, or the agent approves it when auto approval is saved. A
     version the checks emptied is no note, so nothing is written and the day has nothing to share. *)
  let agent_checked c (n : N.note) (v : N.version) ~runs ~text ~removed ~approve
      =
    if text = "" then begin
      N.delete (log c) ~note_id:n.n_id;
      Store.add_tick (log c) ~at:(Time_fmt.of_unix c.now) Store.Quiet
    end
    else begin
      N.checked (log c) v.v_id ~text ~removed;
      add_log c ~note_id:n.n_id (List.map (with_version_id v) runs);
      if approve && n.n_status = "waiting" then begin
        let at = Time_fmt.now () in
        N.approve (log c) ~note_id:n.n_id ~version_id:v.v_id
          ~status:"auto_approved";
        add_log c ~note_id:n.n_id
          [ with_version_id v (Note_checks.entry ~at "auto_approved" []) ]
      end
    end;
    c.on_write ()

  (* `digestif note checked`: the check behavior hands back a version's checks: an edit's, or the
     agent's own when they could not finish as it was written. Save & approve goes out when they
     removed nothing; otherwise the note stays Waiting and the member sees why. *)
  let checked ?(approve = false) ~runs c vid result =
    match N.version (log c) vid with
    | None -> Error "no such version"
    | Some v when N.passed v -> Error "this version's checks already passed"
    | Some v -> (
        let n = Option.get (N.find (log c) v.v_note) in
        match result with
        | Could_not_finish { check; problem } ->
            let retry = c.now +. N.retry_hour in
            N.could_not_finish (log c) vid ~check ~retry_at:retry;
            could_not_finish c ~runs v ~check ~problem ~retry;
            Ok ()
        | Passed { text; removed } when v.v_voice = "agent" ->
            checks_passed c;
            agent_checked c n v ~runs ~text ~removed ~approve;
            Ok ()
        | Passed { text; removed } ->
            checks_passed c;
            N.checked (log c) vid ~text ~removed;
            add_log c ~note_id:n.n_id (List.map (with_version_id v) runs);
            let v = Option.get (N.version (log c) vid) in
            let newest = newest c n in
            if v.approve && n.n_status = "waiting" then
              if (not removed) && approvable n ~newest v then
                approve_as_member c n v
              else if
                Option.map (fun (x : N.version) -> x.v_id) newest = Some vid
              then
                Log.exec (log c)
                  "UPDATE ui_notes SET held_reason = ? WHERE id = ?"
                  [ Log.s (removed_reason runs); Log.s n.n_id ];
            c.on_write ();
            Ok ())

  (* `digestif learnings set VERSION`: the agent's update of Learnings from an edit's diff. *)
  let learned c vid text =
    match N.version (log c) vid with
    | Some v when v.v_voice = "person" && N.passed v && not v.learned ->
        N.set_learnings (log c) (String.trim text);
        N.set_learned (log c) vid;
        Problems.resolve c ~job:"learnings" ();
        add_log c ~note_id:v.v_note
          [
            with_version_id v
              (Note_checks.entry ~at:(Time_fmt.now ()) "learnings_updated" []);
          ];
        Ok ()
    | Some _ -> Error "this version owes no Learnings update"
    | None -> Error "no such version"

  (* The send job: on every pass, sign each approved note not yet signed, whoever approved it; the
     sync posts it to every relay and retries. The check at signing reads the exact bytes: a trip
     returns the note to Waiting with the reason on its page and never edits. Shared is logged
     once a relay has taken it. *)
  (* One send at a time in the process. Each request runs on its own thread (Http.serve_one), and
     the demo plays this job before every one: two passes reading the same note as unsent would
     sign it twice. Nothing inside calls on_write, so it never re-enters. ISS-47299 *)
  let sending = Mutex.create ()

  let send_locked c =
    List.iter
      (fun (n : N.note) ->
        match Option.bind n.approved_version (N.version (log c)) with
        | None -> ()
        | Some v -> (
            let text = Option.value v.v_text ~default:"" in
            match signing_backstop c text with
            | Some r ->
                N.not_sent (log c) ~note_id:n.n_id r.reason;
                add_log c ~note_id:n.n_id
                  [
                    with_version_id v
                      (Note_checks.signing_refused ~at:(Time_fmt.now ()));
                  ];
                ignore
                  (Problems.report c ~note_id:n.n_id ~logged:true ~job:"send"
                     ~kind:"signing_refused" ())
            | None -> (
                let stage = Store.Stages.going_out (log c) in
                match
                  sign c ~kind:"summary"
                    (Content.summary_body ~text ~voice:"agent" ~stage
                       ?prompt:v.prompt_id ?suggestion:n.n_suggestion ())
                with
                | Ok hash ->
                    N.posted (log c) ~note_id:n.n_id ~hash;
                    send_note_questions c ~note_hash:hash text;
                    Store.Stages.reset_clock ~now:c.now (log c);
                    Problems.resolve c ~job:"send" ()
                | Error _ ->
                    ignore
                      (Problems.report c ~note_id:n.n_id ~job:"send"
                         ~kind:"failed" ()))))
      (N.unsent (log c));
    List.iter
      (fun (n : N.note) ->
        match shared_at c n with
        | Some at
          when not
                 (List.exists
                    (fun e ->
                      match Yojson.Safe.from_string e with
                      | `Assoc f ->
                          List.assoc_opt "event" f = Some (`String "shared")
                      | _ -> false)
                    (Store.Checks.entries (log c) ~note_id:n.n_id)) ->
            add_log c ~note_id:n.n_id [ Note_checks.entry ~at "shared" [] ]
        | _ -> ())
      (N.all (log c))

  let send c = Mutex.protect sending (fun () -> send_locked c)
end

(* ISS-38780: Settings is one tab (DES-37265, Settings is one tab). *)
module Settings = struct
  (* The machine's IANA time zone: TZ when it names one, else what /etc/localtime links to. *)
  let time_zone () =
    let after_zoneinfo p =
      match Re.exec_opt (Re.compile (Re.str "zoneinfo/")) p with
      | Some g ->
          let i = Re.Group.stop g 0 in
          Some (String.sub p i (String.length p - i))
      | None -> None
    in
    let from_tz =
      match Sys.getenv_opt "TZ" with
      | Some tz ->
          let tz =
            if String.length tz > 0 && tz.[0] = ':' then
              String.sub tz 1 (String.length tz - 1)
            else tz
          in
          if String.contains tz '/' then
            Some (Option.value (after_zoneinfo tz) ~default:tz)
          else if tz = "UTC" then Some tz
          else None
      | None -> None
    in
    match from_tz with
    | Some tz -> tz
    | None -> (
        match Unix.readlink "/etc/localtime" with
        | p -> Option.value (after_zoneinfo p) ~default:"UTC"
        | exception Unix.Unix_error _ -> "UTC")

  let note_time_json t =
    `Assoc [ ("time", str t); ("time_zone", str (time_zone ())) ]

  let note_time c = ok (note_time_json (Store.Settings.note_time (log c)))

  let set_note_time c body =
    match
      Option.bind (string_field "time" body) Store.Settings.parse_note_time
    with
    | None ->
        invalid ~field:"time" "invalid" "Enter a time of day, such as 07:00."
    | Some t ->
        Store.Settings.set_note_time (log c) t;
        ok (note_time_json t)

  (* Digest: where and when the daily digest is mailed (ISS-50743). The member who joined without
     an email supplies one here; until then no digest is written. *)
  let digest_json c =
    let module D = Digestif_daily.Daily_digest in
    `Assoc (opt "email" (D.email c.node) @ [ ("hour", `Int (D.hour c.node)) ])

  let digest c = ok (digest_json c)

  let set_digest c body =
    let module D = Digestif_daily.Daily_digest in
    match
      ( Option.bind (string_field "email" body) D.parse_email,
        match field "hour" body with
        | Some (`Int h) when h >= 0 && h < 24 -> Some h
        | _ -> None )
    with
    | None, _ ->
        invalid ~field:"email" "invalid"
          "Enter an email address, such as you@example.com."
    | _, None -> invalid ~field:"hour" "invalid" "The hour is 0 to 23."
    | Some email, Some hour ->
        ignore (D.set_email c.node email);
        ignore (D.set_hour c.node hour);
        ok (digest_json c)

  (* The deny list's own section of Settings, one page at a time, oldest first (ISS-41988). *)
  let deny_list c query =
    let known id = Store.deny_entry (log c) id <> None in
    match
      let* limit = limit_param query ~default:100 in
      let* after = cursor_param query ~known in
      Ok (limit, after)
    with
    | Error e -> e
    | Ok (limit, after) ->
        ok (`List (List.map deny_json (Store.deny_list (log c) ?after ~limit)))
end

(* ISS-38822: Names, the agent and removing a phone, on Settings (DES-37265, Settings is one tab). *)

(* Names are the member's signed card, as `digestif card` and the setup chat write it. With no card
   yet this is the first, which every other member then reads them by, and setup's names step is
   done: a setup chat that skipped Names is finished here. *)
module Names = struct
  let publish (node : Node.t) ~member_name ~agent_name =
    let member_name = String.trim member_name
    and agent_name = String.trim agent_name in
    if member_name = "" then Error (Some "member_name", "Enter your name.")
    else if agent_name = "" then Error (Some "agent_name", "Name your agent.")
    else if Log.get_config node.log Node.k_identity = None then
      Error (None, "This machine has not joined a circle: run digestif setup.")
    else
      let card =
        Result.bind (Node.encryption_key node) (fun enc ->
            Node.write node ~kind:"card"
              (Bodies.make_card ~name:member_name ~agent_name
                 ~encryption_key:(Keys.encryption_public enc)))
      in
      match card with
      | Error e -> Error (None, e)
      | Ok _ ->
          Store.Setup.names_saved node.log;
          Ok ()

  let json ?member_name ?agent_name ~published () =
    `Assoc
      (opt "member_name" member_name
      @ opt "agent_name" agent_name
      @ [ ("published", `Bool published) ])

  let get c =
    let me = self_identity c in
    match Option.bind me (card c) with
    | Some k ->
        ok
          (json ~member_name:k.card_name ~agent_name:k.agent_name
             ~published:true ())
    | None ->
        ok
          (json
             ?member_name:(Option.bind me (invited_name c))
             ~published:false ())

  let set c body =
    let member_name = Option.value (string_field "member_name" body) ~default:""
    and agent_name =
      Option.value (string_field "agent_name" body) ~default:""
    in
    match publish c.node ~member_name ~agent_name with
    | Error (field, m) -> invalid ?field "invalid" m
    | Ok () ->
        c.on_write ();
        ok
          (json ~member_name:(String.trim member_name)
             ~agent_name:(String.trim agent_name) ~published:true ())
end

(* The agent is the program setup checked and saved as the node's agent config: the setup chat's,
   and the note writer's harness, whatever its kind. A change passes the same check setup runs
   first (Agents.check), so a program that does not answer is never saved. The check runs the agent
   twice and can take minutes; Save answers with its verdict, and every other page answers meanwhile,
   each on a thread of its own (Http.run). *)
module Agent = struct
  module A = Digestif_invite.Agents

  let k_agent = "agent"

  (* How the check is run: a test replaces it, since the real one runs the agent. *)
  let check =
    ref (fun ~dir (a : A.t) ->
        let e = Sys.executable_name in
        let exe =
          if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e
          else e
        in
        A.check ~exe ~dir a)

  let saved (node : Node.t) =
    Option.bind (Log.get_config node.log k_agent) (fun p ->
        Result.to_option (A.of_path p))

  let json (a : A.t) = `Assoc [ ("name", str a.name); ("path", str a.path) ]

  (* The note writer runs the member's agent as its harness, with that kind's flags
     (behaviors/src/hook.ts reads config.json): the harness and its kind are written together, and
     every other field is kept. *)
  let set_harness ~(dir : string) (a : A.t) =
    let dir = Filename.concat dir "behaviors/nightly" in
    let file = Filename.concat dir "config.json" in
    let others =
      match Yojson.Safe.from_file file with
      | `Assoc f -> List.remove_assoc "agent" (List.remove_assoc "harness" f)
      | _ -> []
      | exception (Sys_error _ | Yojson.Json_error _) -> []
    in
    Node.mkdir_p dir;
    Yojson.Safe.to_file file
      (`Assoc
         (("harness", str a.path)
         :: ("agent", str (A.kind_key a.kind))
         :: others))

  (* The newest check this process started, and where it stands. It is not kept across a restart,
     which ends a running check with the process. *)
  type status = Checking | Passed | Failed of string
  type checked = { agent : A.t; status : status }

  let last : checked option Atomic.t = Atomic.make None
  let checking = Atomic.make false

  let check_json { agent; status } =
    let s, message =
      match status with
      | Checking -> ("checking", None)
      | Passed -> ("passed", None)
      | Failed m -> ("failed", Some m)
    in
    `Assoc
      ([ ("name", str agent.name); ("path", str agent.path); ("status", str s) ]
      @ opt "message" message)

  let failed (a : A.t) why =
    Failed (Printf.sprintf "%s %s. Not saved." a.name why)

  (* The check: saved only when it passes. *)
  let run ~dir (a : A.t) (log : Log.t) =
    let status =
      match !check ~dir a with
      | A.Fails why -> failed a why
      | A.Works ->
          Log.set_config log k_agent a.path;
          set_harness ~dir a;
          Passed
      | exception e ->
          failed a ("could not be checked (" ^ Printexc.to_string e ^ ")")
    in
    Atomic.set last (Some { agent = a; status })

  let get c = with_found (saved c.node) (fun a -> ok (json a))
  let get_check _c = with_found (Atomic.get last) (fun k -> ok (check_json k))

  let set c body =
    match A.of_path (Option.value (string_field "path" body) ~default:"") with
    | Error m -> invalid ~field:"path" "not_a_program" (m ^ ".")
    | Ok a ->
        let busy () =
          invalid "checking"
            (match Atomic.get last with
            | Some { agent; status = Checking } ->
                agent.name ^ " is still being checked."
            | _ -> "A check is still running.")
        in
        if not (Atomic.compare_and_set checking false true) then busy ()
        else
          (* The check runs inside the request: each request has a thread of its own (Http.run), so
             every other page answers while it runs, and the answer is the check's verdict. *)
          Fun.protect
            ~finally:(fun () -> Atomic.set checking false)
            (fun () ->
              Atomic.set last (Some { agent = a; status = Checking });
              run ~dir:c.node.dir a (log c);
              match Atomic.get last with
              | Some k -> ok (check_json k)
              | None -> busy ())
end

(* Removing a phone: the identity re-derived from the phrase signs a revoke of the phone's key, as
   `digestif revoke` does, and the phrase is dropped. Every relay is read first, so the revoke keeps
   everything the phone wrote before it. *)
module Phones = struct
  let sync_first =
    ref (fun (node : Node.t) -> ignore (Sync.sync node : _ result))

  let revoke c key body =
    let phrase =
      Option.value (string_field "recovery_phrase" body) ~default:""
    in
    match Fold.find c.fold key with
    | Some d when Some d.identity = self_identity c && is_phone c d -> (
        if d.revoked_by <> None then
          invalid "revoked" "This phone is already removed."
        else
          match Node.identity_from_phrase c.node phrase with
          | Error m -> invalid ~field:"recovery_phrase" "invalid" m
          | Ok by -> (
              !sync_first c.node;
              match
                Result.bind
                  (Node.revoke_body c.node ~by ~target:key)
                  (Node.write c.node ~kind:"revoke")
              with
              | Error m -> invalid "not_signed" m
              | Ok (hash, _) ->
                  c.on_write ();
                  ok (device_json ?revoked_at:(envelope_time c hash) c d)))
    | _ -> not_found ()
end

(* ISS-38784: stages, the clock, the status note and Members (DES-37265, Onboarding, Active
   and Paused, The clock, The status note, Members is one table). *)
module Stages = struct
  module S = Store.Stages

  (* node_status: stage. *)
  let status_fields c : (string * Yojson.Safe.t) list =
    [ ("stage", str (S.stage (log c))) ]

  (* feed_item, by hash: status_note and its words. A status note is one muted line under the
     author's agent. *)
  let feed_fields c hash : (string * Yojson.Safe.t) list =
    match Log.find (log c) hash with
    | Some r when r.signed.envelope.kind = "summary" -> (
        match Content.status_of r.signed.body with
        | None -> []
        | Some s ->
            let e = r.signed.envelope in
            let identity =
              Option.value (identity_of c e.author) ~default:e.author
            in
            [ ("status_note", str s) ]
            @ opt "status_note_words" (status_note_words c identity s))
    | _ -> []

  (* Invites not yet used: a guest no join has spent, whose invite has not expired. Each is an
     Invited row of Members, its expiry in the last-note cell, until the join makes it Onboarding. *)
  let invitees c =
    let spent key =
      match Hashtbl.find_opt c.fold.invites key with
      | Some { spent_by = Some _; _ } -> true
      | _ -> false
    in
    dinner_bodies c
    |> List.concat_map (fun (_, (d : Bodies.dinner)) ->
        List.filter_map
          (fun (g : Bodies.guest) ->
            if spent g.invite_key || c.now >= unix g.expires_at then None
            else
              Some
                ( g.expires_at,
                  `Assoc
                    [
                      ("name", str g.name);
                      ("expires_at", str g.expires_at);
                      ("invited_by", member_ref c d.host);
                    ] ))
          d.guests)
    |> List.sort compare |> List.map snd
    |> fun l -> ok (`List l)

  (* The fixed words the clock sends, the first row that holds (docs/protocol.md, Content bodies);
     Paused is Pause's own, sent as part of the act. A reason never travels: the kind of a failure
     stays a problem on this machine. *)
  let clock_status c =
    let l = log c in
    let waiting = Store.Notes.waiting l in
    if
      List.exists
        (fun (n : Store.Notes.note) -> Store.Notes.readable l ~note_id:n.n_id)
        waiting
    then "waiting_for_approval"
    else if Store.Problems.work_run_failed l || waiting <> [] then
      "could_not_run"
    else "nothing_to_share"

  (* A status note goes out with no check and no approval: it carries no words, only their name.
     Like any note going out it sets the clock. *)
  let send_status c status =
    match
      sign c ~kind:"summary"
        (Content.status_body ~status ~stage:(S.stage (log c)))
    with
    | Ok hash ->
        S.reset_clock ~now:c.now (log c);
        Problems.resolve c ~job:"send" ();
        Ok hash
    | Error e ->
        ignore (Problems.report c ~job:"send" ~kind:"failed" ());
        Error e

  (* The clock, on every pass: run out for an Active member, it sends the status note. A clock
     that runs out while a work run is going waits for that run to end. *)
  let clock c ~working =
    if working || not (S.clock_out (log c) ~now:c.now) then None
    else
      let status = clock_status c in
      Some (status, send_status c status)

  (* Post to the circle (/feed/new, POST /api/v0/messages) opens at Active. *)
  let compose c f =
    if S.active (log c) then f ()
    else
      invalid "not_active"
        "Nothing is posted in your name until your first note goes out."
end

(* ISS-38785: Pause (DES-37265, Pause). Paused is Digestif as a whole: the work run writes nothing
   (Behaviors.after_pass) and the agent answers nobody (post_body), while sync, sending and reading
   the circle go on. *)
module Pause = struct
  module P = Store.Pause

  let iso t = str (Time_fmt.of_unix t)

  let note_ref (n : Store.Notes.note) =
    `Assoc [ ("id", str n.n_id); ("written_at", str n.written_at) ]

  (* The member's Note time, HH:MM local, for the next-note sentence. *)
  let note_time c = Printf.sprintf "%02d:%02d" 3 (Store.note_minute (log c))

  (* node_status: pause_warning, the banner three days before a pause. *)
  let status_fields c : (string * Yojson.Safe.t) list =
    match P.warning ~upkeep:(upkeep c) (log c) ~now:c.now with
    | None -> []
    | Some (n, from, at) ->
        [
          ( "pause_warning",
            `Assoc
              [
                ("note", note_ref n);
                ("waited_days", `Int (int_of_float ((c.now -. from) /. P.day)));
                ("pauses_at", iso at);
              ] );
        ]

  (* The Paused page: since when, why, the Note time, and a note still waiting, the oldest. *)
  let page c =
    let l = log c in
    let waiting =
      match List.rev (Store.Notes.waiting l) with
      | n :: _ -> [ ("waiting_note", note_ref n) ]
      | [] -> []
    in
    `Assoc
      ([
         ("since", iso (Option.value (P.since l) ~default:c.now));
         ("reason", str (P.reason l));
         ("note_time", str (note_time c));
       ]
      @ waiting)

  let paused c = if P.paused (log c) then ok (page c) else not_found ()

  (* ISS-42315: the Paused ask (DES-37153, The Paused ask). A pause the node made asks the member
     whether to unpause: Unpause recommended, Stay paused standing with no answer, and no deadline.
     It names the stage and two dates the circle's Paused note already told everyone, so it is an
     ordinary ask, reaching the phone and the mail with answer links. *)
  module Ask = struct
    let key = "paused"
    let unpause = "unpause"
    let stay = "stay_paused"

    let months =
      [|
        "Jan";
        "Feb";
        "Mar";
        "Apr";
        "May";
        "Jun";
        "Jul";
        "Aug";
        "Sep";
        "Oct";
        "Nov";
        "Dec";
      |]

    let day t =
      let g = Unix.localtime t in
      Printf.sprintf "%s %d" months.(g.tm_mon) g.tm_mday

    let clock t =
      let g = Unix.localtime t in
      let h = match g.tm_hour mod 12 with 0 -> 12 | h -> h in
      Printf.sprintf "%d:%02d %s" h g.tm_min
        (if g.tm_hour < 12 then "AM" else "PM")

    (* Its words: Your Nov 1 note waited 30 days, so Digestif paused on Dec 1 at 8:07 AM. *)
    let body ~(note : Store.Notes.note) ~now : Digestif_mail.Ask.t =
      {
        kind = Some "paused";
        title = "Digestif paused. Unpause?";
        detail =
          Printf.sprintf
            "Your %s note waited 30 days, so Digestif paused on %s at %s. No \
             notes are written while it stays paused."
            (day (unix note.written_at))
            (day now) (clock now);
        about = None;
        options =
          [
            { id = unpause; label = "Unpause"; recommended = true };
            { id = stay; label = "Stay paused"; recommended = false };
          ];
        on_no_answer = stay;
        lapses_at = None;
      }

    (* Raised at the moment of the pause and appended at once; the next pass mails it, after quiet
       hours. *)
    let raise_ c ~note =
      match
        Digestif_daily.Daily_digest.ask_now c.node ~key (body ~note ~now:c.now)
      with
      | Ok _ -> c.on_write ()
      | Error e ->
          Printf.eprintf "%s pause: the Paused ask: %s\n" (Time_fmt.now ()) e

    let open_ c =
      match Asks.find (log c) key with
      | Some ({ answer = None; _ } as a) -> Some a
      | _ -> None

    (* An unpause on the machine closes the open ask by writing its Unpause pick on the node's
       paused choice with the device key, so the Inbox and its answer links read it as answered
       (docs/protocol.md, Items, Picks). An ask no digest appended yet has no envelope to answer and is recorded
       answered here. *)
    let close c =
      match open_ c with
      | None -> ()
      | Some a -> (
          let via =
            match (a.envelope, Node.encryption_key c.node) with
            | Some ask, Ok enc -> (
                match
                  sign c ~kind:"decision"
                    (Digestif_mail.Ask.pick_body ~keys:[ enc.public ] ~item:ask
                       ~option:unpause)
                with
                | Ok d -> Some (Asks.Decision d)
                | Error e ->
                    Printf.eprintf "%s unpause: the Paused ask's decision: %s\n"
                      (Time_fmt.now ()) e;
                    None)
            | None, _ -> Some Asks.Person
            | Some _, Error e ->
                Printf.eprintf "%s unpause: the Paused ask's decision: %s\n"
                  (Time_fmt.now ()) e;
                None
          in
          match via with
          | None -> ()
          | Some via ->
              ignore
                (Asks.record_answer (log c)
                   ~answered_at:(Time_fmt.of_unix c.now) ~via ~key unpause))

    (* The Paused ask answered Unpause from the phone, the mail or the Asks page, settled at this
       pass's sync for the pause it was raised for: an answer older than the pause belongs to an
       earlier one. *)
    let answered_unpause c =
      match (Asks.find (log c) key, P.since (log c)) with
      | ( Some
            {
              answer = Some o;
              answered_via = Some (Decision _);
              answered_at;
              _;
            },
          Some since )
        when o = unpause ->
          Option.bind answered_at Time_fmt.to_unix
          |> Option.fold ~none:false ~some:(fun at -> at > since)
      | _ -> false
  end

  (* Pausing sends the Paused status note at once, as part of the act. A note still waiting stays
     waiting and does not go out with it. A pause the node made, because [note] waited 30 days, also
     raises the Paused ask. *)
  let enter ?note c ~reason =
    if not (P.pause (log c) ~now:c.now ~reason) then None
    else
      let sent = Stages.send_status c "paused" in
      Option.iter (fun note -> Ask.raise_ c ~note) note;
      Some sent

  let pause c =
    match enter c ~reason:"pressed_pause" with
    | None ->
        invalid "not_active"
          "Only an Active member pauses: your first note has not gone out yet."
    | Some _ ->
        c.on_write ();
        ok ~status:201 (page c)

  (* Unpause: Active at once, the clock set to 24 hours, no note written and nothing sent but the
     Paused ask's own decision, which closes it. *)
  let unpause c =
    if P.unpause (log c) ~now:c.now then begin
      Ask.close c;
      no_content
    end
    else not_found ()

  (* On every pass: a note that has waited 30 days pauses an Active member. *)
  let due c =
    match P.due (log c) ~now:c.now with
    | None -> None
    | Some note ->
        Option.map
          (fun r -> ("paused", r))
          (enter ~note c ~reason:"note_waited")

  (* On every pass, after the sync settled the asks: the Paused ask answered Unpause unpauses, as the
     Paused page's Unpause does. Answers whether it did. *)
  let answered c = Ask.answered_unpause c && P.unpause (log c) ~now:c.now
end

(* ISS-52609: the Inbox (docs/protocol.md, Items; spec/digestif-node.json, /items). A draft stays
   in the store until it is sent; sending signs a circle item as plaintext through the deny layer,
   and seals an item to named members and its author. Every item that reaches the member is
   indexed from the log once, with its answers, closes and picks, and each one's status is the
   member's own: Draft, New, Read, Done. A choice closes on its picks or its default at its
   deadline, and a question with no answer after a week, by the same rules on every node. *)
module Inbox = struct
  module I = Store.Items

  let statuses = I.statuses

  (* Whether [identity] reads the item: its author, everyone it names, and on a circle item every
     member of the circle. *)
  let is_reader c (r : I.row) identity =
    identity = r.author
    ||
    match r.to_ with
    | Item.Circle ->
        List.exists
          (fun (k : Fold.key_state) -> k.key = identity)
          (identities c)
    | Members l -> List.mem identity l

  (* The raw X25519 keys a named body is sealed to: those of [readers], deduplicated; the first
     identity with no published card when one has none. *)
  let keys_for c readers =
    List.fold_right
      (fun id acc ->
        let* acc = acc in
        match
          Option.bind (card c id) (fun (k : Bodies.card) ->
              Content.raw_x25519 k.encryption_key)
        with
        | Some k -> Ok (k :: acc)
        | None -> Error id)
      (List.sort_uniq compare readers)
      (Ok [])

  let readers (r : I.row) = r.author :: Item.to_list r.to_

  let no_card _ =
    invalid "no_card"
      "Everyone it is addressed to needs a published card before it can be \
       sealed."

  (* The answers a reader of the question wrote, oldest first. *)
  let answers c (r : I.row) =
    match r.hash with
    | None -> []
    | Some h ->
        List.filter
          (fun (a : I.answer) -> is_reader c r a.a_author)
          (I.answers (log c) h)

  (* Every close and reopen by the item's author, newest first. *)
  let closes c (r : I.row) =
    match r.hash with
    | None -> []
    | Some h ->
        List.filter
          (fun (x : I.close) -> x.c_author = r.author)
          (I.closes (log c) h)

  let standing closes =
    Option.map
      (fun (_, _, _, x) -> x)
      (Item.standing
         (List.map
            (fun (x : I.close) -> (x.c_voice, x.c_at, x.c_hash, x))
            closes))

  (* The picks that count: each reader's first, of an option the choice offers, before its
     deadline. *)
  let picks c (r : I.row) =
    match r.hash with
    | None -> []
    | Some h ->
        let deadline = Option.map unix r.item.deadline in
        let offered o =
          List.exists (fun (x : Item.option_) -> x.id = o) r.item.options
        in
        List.fold_left
          (fun acc (p : I.pick) ->
            if List.exists (fun (q : I.pick) -> q.p_author = p.p_author) acc
            then acc
            else if
              is_reader c r p.p_author && offered p.option
              && match deadline with None -> true | Some d -> p.p_unix < d
            then acc @ [ p ]
            else acc)
          []
          (I.picks (log c) h)

  (* Settle whether the item is closed from what the node holds of it: the close that stands, or,
     with none, its picks and the clock. A prompt suggestion closes as its rounds decide, which
     Prompts.sync settles from the circle's notes. *)
  let refresh c (r : I.row) =
    if r.hash <> None && r.item.subject <> Some "suggestion" then
      match standing (closes c r) with
      | Some x -> I.set_closed (log c) r.id ~closed:x.closed ~closes_unix:None
      | None ->
          let answered =
            List.exists
              (fun (a : I.answer) -> a.a_author <> r.author)
              (answers c r)
          in
          let picked = List.map (fun (p : I.pick) -> p.p_author) (picks c r) in
          I.set_closed (log c) r.id
            ~closed:
              (r.item.kind = "choice"
              && Item.closed_by_picks ~subject:r.item.subject ~to_:r.to_ ~picked
              )
            ~closes_unix:
              (Item.closes_at ~kind:r.item.kind ~sent:(unix r.created_at)
                 ~deadline:(Option.map unix r.item.deadline)
                 ~answered)

  (* ISS-52614: what the member did from their digest, or on a phone, reaches the node as a
     decision under one of their keys: a pick on a choice settles it Picked for them, and an
     Acknowledge (Digestif_mail.Ask.acknowledge) on a notice settles it Acknowledged. *)
  let settle_from_decisions c (r : I.row) =
    match (r.hash, self_identity c, r.done_) with
    | Some h, Some me, None -> (
        let mine =
          List.filter (fun (p : I.pick) -> p.p_author = me) (I.picks (log c) h)
        in
        match r.item.kind with
        | "notice" -> (
            match
              List.find_opt
                (fun (p : I.pick) -> p.option = Digestif_mail.Ask.acknowledge)
                mine
            with
            | Some p -> I.settle (log c) r.id ~why:"acknowledged" ~at:p.p_at
            | None -> ())
        | "choice" -> (
            match
              List.find_opt (fun (p : I.pick) -> p.p_author = me) (picks c r)
            with
            | Some p -> I.settle (log c) r.id ~why:"picked" ~at:p.p_at
            | None -> ())
        | _ -> ())
    | _ -> ()

  (* One envelope of each kind, read with the member's key [priv] and its author's identity:
     each answers the item hashes it touches. *)
  let index_item c ~priv (r : Log.row) author at body =
    let l = log c in
    match (author, Option.bind body (Item.read_item ~priv)) with
    | Some author, Some (to_, item) when not (Item.local_subject item.subject)
      ->
        (* ISS-52614: the node's own items reach the member New, though signed as theirs. *)
        let read_at =
          if Some author = self_identity c && item.voice <> "node" then Some at
          else None
        in
        I.add l ~id:r.hash ~hash:r.hash ~author ~item ~to_ ~created_at:at
          ~sent_at:at ?read_at ();
        [ r.hash ]
    | _ ->
        I.add_unreadable l ~hash:r.hash ~created_at:at;
        []

  let index_answer c ~priv (r : Log.row) author at body =
    let l = log c in
    match (author, Option.bind body (Item.read_answer ~priv)) with
    | Some author, Some a ->
        I.put_answer l ~hash:r.hash ~created_at:at
          (Some (a.a_item, author, a.a_voice, a.text));
        let me = self_identity c in
        if Some author <> me then I.freshen_own l a.a_item ~author:me;
        [ a.a_item ]
    | _ ->
        I.put_answer l ~hash:r.hash ~created_at:at None;
        []

  let index_close c ~priv (r : Log.row) author at body =
    match (author, Option.bind body (Item.read_close ~priv)) with
    | Some author, Some x ->
        I.put_close (log c) ~hash:r.hash ~created_at:at
          (Some (x.c_item, author, x.closed, x.answer, x.c_voice));
        [ x.c_item ]
    | _ ->
        I.put_close (log c) ~hash:r.hash ~created_at:at None;
        []

  let index_pick c ~priv (r : Log.row) author at body =
    let pick =
      match (author, Option.bind body (Item.read_pick ~priv)) with
      | Some author, Some (item, option) -> Some (item, author, option)
      | _ -> None
    in
    I.put_pick (log c) ~hash:r.hash ~created_at:at ~created_unix:(unix at) pick;
    match pick with
    | Some (item, author, _) ->
        let me = self_identity c in
        if Some author <> me then I.freshen_own (log c) item ~author:me;
        [ item ]
    | None -> []

  (* Bring the index up to the log: every item, answer, close and pick not opened yet, then each
     item they touch settled again. An envelope whose body has not arrived is left for the next
     read; one this node cannot read, or retracted, is kept as unreadable. index_now runs inside a
     transaction the caller holds (the daily digest's); index holds its own. *)
  let index_now c =
    match encryption c with
    | None -> ()
    | Some enc ->
        let l = log c in
        let priv = enc.secret in
        let each kind f =
          I.unindexed l kind
          |> List.concat_map (fun hash ->
              match Log.find l hash with
              | Some r when r.signed.body <> None || r.retracted_by <> None ->
                  let body =
                    if r.retracted_by = None then r.signed.body else None
                  in
                  f c ~priv r
                    (identity_of c r.signed.envelope.author)
                    r.signed.envelope.created_at body
              | _ -> [])
        in
        let touched =
          each "item" index_item
          @ each "item_answer" index_answer
          @ each "item_close" index_close
          @ each "decision" index_pick
        in
        List.sort_uniq compare touched
        |> List.iter (fun h ->
            Option.iter
              (fun r ->
                refresh c r;
                settle_from_decisions c r)
              (I.by_hash l ~now:c.now h))

  let index c = upkeep c (fun () -> index_now c)

  let find c id =
    index c;
    I.find (log c) ~now:c.now id

  let to_json c (to_ : Item.to_) : Yojson.Safe.t =
    `Assoc
      [
        ("circle", `Bool (to_ = Circle));
        ("members", `List (List.map (member_ref c) (Item.to_list to_)));
      ]

  let own c (r : I.row) = self_identity c = Some r.author

  let closed c (r : I.row) =
    r.closed_flag
    || match r.closes_unix with Some t -> t <= c.now | None -> false

  let summary_fields c (r : I.row) =
    [ ("id", str r.id); ("kind", str r.item.kind) ]
    @ opt "subject" r.item.subject
    @ [
        ("voice", str r.item.voice);
        ("author", member_ref c r.author);
        ("to", to_json c r.to_);
        ("title", str r.item.title);
        ("status", str r.status);
        ("closed", `Bool (closed c r));
      ]
    @ (if r.item.kind = "choice" then opt "deadline_at" r.item.deadline else [])
    @ [ ("created_at", str r.created_at) ]
    @ opt "about" r.item.about
    @ if own c r then [] else opt "reviewed_at" r.reviewed_at

  let summary c r = `Assoc (summary_fields c r)

  let close_json (x : I.close) : Yojson.Safe.t =
    `Assoc
      ([ ("closed", `Bool x.closed) ]
      @ opt "answer" x.answer
      @ [ ("voice", str x.c_voice); ("at", str x.c_at) ])

  (* Where on this node the member acts on the item: a prompt suggestion is picked on the note
     waiting in two versions for it, and read on its own page until one waits. *)
  let path c (r : I.row) =
    match (r.item.subject, r.hash) with
    | Some "suggestion", Some h when not (closed c r) -> (
        match
          List.find_opt
            (fun (n : Store.Notes.note) -> n.n_suggestion = Some h)
            (Store.Notes.waiting (log c))
        with
        | Some n -> Some ("/feed/" ^ n.n_id)
        | None -> Some ("/settings/note-prompt/" ^ h))
    | Some "suggestion", Some h -> Some ("/settings/note-prompt/" ^ h)
    | Some subject, _ when r.item.voice = "node" && own c r ->
        Item.notice_page subject
    | _ -> None

  (* The member's own node notice: the address to type for its page on the node's machine, the
     node's own URL so its port is the one it bound, and the one line of what to do there. A notice
     raised before it carried a line reads the line its subject fixes (ISS-74093). *)
  let own_notice c (r : I.row) = r.item.voice = "node" && own c r

  let address c r =
    match (path c r, ui_url c) with
    | Some p, Some u when own_notice c r -> Some (u ^ p)
    | _ -> None

  let detail c (r : I.row) =
    match r.item.subject with
    | Some subject when r.item.detail = "" && own_notice c r ->
        Option.value (Item.notice_instruction subject) ~default:""
    | _ -> r.item.detail

  (* DIG-378: a notice from the member's own node that has a page is the one thing Ask your agent
     takes: the agent is handed where the member would act, never what the notice says. *)
  let askable c (r : I.row) =
    r.item.kind = "notice" && own_notice c r && r.done_ = None
    && (not (closed c r))
    && path c r <> None

  (* Where an Ask your agent on the item stands, kept in the node's config on this machine: the
     status, when it changed and the agent's reply. It is never signed, sent or mailed. *)
  let k_ask id = "agent_ask:" ^ id

  (* [pgid] is the agent's process group while it runs, kept so a later start can kill what a crash
     left behind. It is never shown on the item. *)
  let ask_record ~status ~at ?reply ?pgid () =
    Yojson.Safe.to_string
      (`Assoc
         ([ ("status", str status); ("at", str at) ]
         @ opt "reply" reply
         @ match pgid with Some g -> [ ("pgid", `Int g) ] | None -> []))

  (* The words for an ask that did not answer. *)
  let ask_failure why = Printf.sprintf "Your agent did not answer (%s)." why

  (* An ask left asked past its run's deadline and a margin never finished: its worker died with the
     process or could not write. It reads as failed, so the page never waits on it for good. *)
  let ask_deadline = 600.0
  let ask_margin = 120.0

  (* The read says failed at 720 s while the run's own deadline is 600 s. A late write can still turn
     failed into answered, and that is fine: the worker's own write is authoritative, and the margin
     only covers a slow write after the deadline, so the page is never left waiting on a worker that
     has died. *)
  let ask_json c id =
    match Log.get_config (log c) (k_ask id) with
    | None -> None
    | Some s -> (
        match Yojson.Safe.from_string s with
        | exception Yojson.Json_error _ -> None
        | `Assoc f0 ->
            let f = List.remove_assoc "pgid" f0 in
            let j = `Assoc f in
            let field name =
              match List.assoc_opt name f with Some (`String v) -> v | _ -> ""
            in
            let late =
              match Time_fmt.to_unix (field "at") with
              | Some at -> c.now -. at > ask_deadline +. ask_margin
              | None -> true
            in
            if field "status" = "asked" && late then
              Some
                (`Assoc
                   [
                     ("status", str "failed");
                     ("at", str (field "at"));
                     ("reply", str (ask_failure "it ran past ten minutes"));
                   ])
            else Some j
        | j -> Some j)

  let item_json c (r : I.row) : Yojson.Safe.t =
    let closes = closes c r in
    let done_ =
      match r.done_ with
      | Some d -> Some d
      | None when closed c r -> Some "closed"
      | None -> None
    in
    `Assoc
      (summary_fields c r @ opt "hash" r.hash
      @ [ ("detail", str (detail c r)); ("local", `Bool r.local) ]
      @ opt "done" done_
      @ opt "adopted" (Item.adopted_of r.item)
      @ [ ("options", `List (List.map Item.option_json r.item.options)) ]
      @ opt "default_option" r.item.default
      @ [
          ( "answers",
            `List
              (List.map
                 (fun (a : I.answer) ->
                   `Assoc
                     [
                       ("hash", str a.a_hash);
                       ("author", member_ref c a.a_author);
                       ("voice", str a.a_voice);
                       ("text", str a.text);
                       ("created_at", str a.a_at);
                     ])
                 (answers c r)) );
          ( "picks",
            `List
              (List.map
                 (fun (p : I.pick) ->
                   `Assoc
                     [
                       ("member", member_ref c p.p_author);
                       ("option_id", str p.option);
                       ("picked_at", str p.p_at);
                     ])
                 (picks c r)) );
        ]
      @ (match standing closes with
        | Some x -> [ ("close", close_json x) ]
        | None -> [])
      @ [ ("closes", `List (List.map close_json closes)) ]
      @ (match r.drafted with
        | Some (t, d) ->
            [ ("drafted", `Assoc [ ("title", str t); ("detail", str d) ]) ]
        | None -> [])
      @ opt "path" (path c r)
      @ opt "address" (address c r)
      @ (if askable c r then
           [ ("agent_connected", `Bool (Agent.saved c.node <> None)) ]
         else [])
      @ (match ask_json c r.id with
        | Some j -> [ ("agent_ask", j) ]
        | None -> [])
      @ opt "sent_at" r.sent_at @ opt "read_at" r.read_at
      @ (if own c r then [] else opt "review" r.review)
      @
      match (r.item.kind, r.item.subject, r.item.about) with
      | "question", _, _ -> (
          match Store.Reviews.agent_answer (log c) r.id with
          | Some a -> [ ("agent_answer", agent_answer_json a) ]
          | None -> [])
      (* A work notice about another member's note: the reply the member's agent drafted to that
         note waits here, and one is asked for here (ISS-83154). *)
      | "notice", Some "work", Some h when reply_note c h <> None ->
          ("reply_to", str h) :: reply_fields c h
      | _ -> [])

  (* The item [id] as it stands now, the answer of a write that changed it. *)
  let answer_with ?(status = 200) c id =
    match find c id with
    | Some r ->
        refresh c r;
        with_found
          (I.find (log c) ~now:c.now id)
          (fun r -> ok ~status (item_json c r))
    | None -> not_found ()

  (* GET /items: one page of the member's Inbox, Draft and New first and then the newest; [status]
     given more than once reads the items in any of them. *)
  let list c query =
    index c;
    let known id = I.find (log c) ~now:c.now id <> None in
    let enum name values =
      match List.assoc_opt name query with
      | None | Some "" -> Ok None
      | Some v when List.mem v values -> Ok (Some v)
      | Some _ -> Error (invalid ~field:name name ("Unknown " ^ name ^ "."))
    in
    let status =
      match
        List.filter_map
          (fun (k, v) -> if k = "status" && v <> "" then Some v else None)
          query
      with
      | [] -> Ok None
      | l when List.for_all (fun v -> List.mem v statuses) l -> Ok (Some l)
      | _ -> Error (invalid ~field:"status" "status" "Unknown status.")
    in
    match
      let* status = status in
      let* kind = enum "kind" Item.kinds in
      let* limit = limit_param query ~default:100 in
      let* after = cursor_param query ~known in
      Ok (status, kind, limit, after)
    with
    | Error e -> e
    | Ok (status, kind, limit, after) ->
        ok
          (`List
             (List.map (summary c)
                (I.page (log c) ~now:c.now ?inbox:(self_identity c) ?status
                   ?kind ?after ~limit ())))

  (* Whom a form addresses: the circle, or the members it names, each in the circle and none the
     member. A prompt suggestion's ([judges]) is always the members it names, the member taken out
     because they judge it anyway, and the member alone when it names nobody else. *)
  let to_of ?(judges = false) c ~me ~circle ~members =
    if circle && not judges then Ok Item.Circle
    else
      let members = List.sort_uniq compare members in
      let members =
        if judges then List.filter (( <> ) me) members else members
      in
      let in_circle id =
        List.exists (fun (k : Fold.key_state) -> k.key = id) (identities c)
      in
      match members with
      | [] when judges -> Ok (Suggestions.to_of ~author:me [])
      | [] ->
          Error
            (invalid ~field:"members" "no_members"
               "Name who it is for, or send it to the circle.")
      | l when List.mem me l ->
          Error
            (invalid ~field:"members" "self" "You are not one of its readers.")
      | l when not (List.for_all in_circle l) ->
          Error
            (invalid ~field:"members" "not_in_circle"
               "Everyone it names must be in the circle.")
      | l -> Ok (Item.Members l)

  let bool_field name body ~default =
    match field name body with Some (`Bool b) -> b | _ -> default

  (* Sign the draft [r]: the deny layer reads every word first, and a named item is sealed to
     everyone it names and its author. *)
  let send c (r : I.row) =
    match deny_check c (Item.words r.item) with
    | Some rule -> invalid "refused" ("Refused before signing: " ^ rule ^ ".")
    | None -> (
        let body =
          match r.to_ with
          | Circle -> Ok (Item.item_body ~to_:Circle ~keys:[] r.item)
          | Members _ ->
              Result.map
                (fun keys -> Item.item_body ~to_:r.to_ ~keys r.item)
                (keys_for c (readers r))
        in
        match body with
        | Error id -> no_card id
        | Ok body -> (
            (* The draft is stamped with its envelope before anything is told of the write: a pass
               on_write runs (the demo's send_notes) indexes the Inbox, and would open the new
               envelope as a second row with the same hash. *)
            match sign { c with on_write = ignore } ~kind:"item" body with
            | Error e -> invalid "not_signed" e
            | Ok hash ->
                let at =
                  Option.value (envelope_time c hash) ~default:(Time_fmt.now ())
                in
                I.sent (log c) r.id ~hash ~at
                  ~closes_unix:
                    (Item.closes_at ~kind:r.item.kind ~sent:(unix at)
                       ~deadline:(Option.map unix r.item.deadline)
                       ~answered:false);
                c.on_write ();
                answer_with ~status:201 c r.id))

  (* A draft for the member: theirs from New item, or one their agent wrote (ISS-52611), which
     waits for them to send, edit or discard it. *)
  let add_draft c ~author ~(item : Item.t) ~to_ =
    let id = "item-" ^ Store.random_id () in
    I.add (log c) ~id ~author ~item ~to_ ~created_at:(Time_fmt.now ()) ();
    id

  (* What a member may write on New item, or why not: a question or a notice of their own, or an
     intro naming the two people it introduces. A share, a behavior and work come only from an
     agent, and a prompt suggestion is written by Prompts.create, which builds its choice. *)
  let member_kind ~kind ~subject ~circle ~members ~title =
    let fail ?(field = "kind") code m = Error (invalid ~field code m) in
    match (kind, subject) with
    | None, _ -> fail "kind" "Choose a question or a notice."
    | Some k, _ when not (List.mem k Item.kinds) ->
        fail "kind" "Choose a question or a notice."
    | _, Some s when not (List.mem s Item.member_subjects) ->
        fail ~field:"subject" "subject"
          "A share, a behavior and work come only from an agent."
    | _, Some "suggestion" ->
        fail ~field:"subject" "subject"
          "A prompt suggestion is written with its prompt and judges."
    | Some "choice", None ->
        fail "kind"
          "A choice's options come from what it is for; ask a question instead."
    | Some k, Some "intro" when k <> "notice" ->
        fail "kind" "An intro is a notice."
    | _, Some "intro"
      when circle || List.length (List.sort_uniq compare members) <> 2 ->
        fail ~field:"members" "intro"
          "An intro names the two people it introduces."
    | _ when title = "" -> fail ~field:"title" "empty" "Give it a title."
    | Some k, _ -> Ok k

  (* POST /items: New item, saved as a Draft or sent at once; one the deny layer refuses is not
     kept. *)
  let create c body =
    let text name =
      String.trim (Option.value (string_field name body) ~default:"")
    in
    let subject = string_field "subject" body and title = text "title" in
    let members = Option.value (strings_field "members" body) ~default:[] in
    let circle = bool_field "circle" body ~default:true in
    match self_identity c with
    | None -> invalid "not_joined" "This node has not joined a circle yet."
    | Some me -> (
        match
          let* kind =
            member_kind ~kind:(string_field "kind" body) ~subject ~circle
              ~members ~title
          in
          let* to_ = to_of c ~me ~circle ~members in
          Ok (kind, to_)
        with
        | Error e -> e
        | Ok (kind, to_) -> (
            let item : Item.t =
              {
                kind;
                subject;
                voice = "person";
                title;
                detail = text "detail";
                about = None;
                options = [];
                default = None;
                deadline = None;
                adopted = None;
              }
            in
            let id = add_draft c ~author:me ~item ~to_ in
            if not (bool_field "send" body ~default:false) then
              answer_with ~status:201 c id
            else
              match I.find (log c) ~now:c.now id with
              | None -> not_found ()
              | Some r ->
                  let res = Stages.compose c (fun () -> send c r) in
                  if res.status <> 201 then I.discard (log c) id;
                  res))

  let draft_only (r : I.row) f =
    if r.status <> "draft" then invalid "not_draft" "This item has been sent."
    else f ()

  (* PUT /items/:id: edit a draft. The member's first change to their agent's words keeps the
     agent's beside them, and the words are the member's from then on. *)
  let edit c (r : I.row) body =
    draft_only r (fun () ->
        let title =
          String.trim (Option.value (string_field "title" body) ~default:"")
        in
        let detail =
          String.trim (Option.value (string_field "detail" body) ~default:"")
        in
        if title = "" then invalid ~field:"title" "empty" "Give it a title."
        else
          let to_ =
            match (field "circle" body, strings_field "members" body) with
            | None, None -> Ok r.to_
            | circle, members ->
                to_of c ~me:r.author
                  ~judges:(r.item.subject = Some "suggestion")
                  ~circle:(circle = Some (`Bool true))
                  ~members:(Option.value members ~default:[])
          in
          match to_ with
          | Error e -> e
          | Ok to_ ->
              let changed = title <> r.item.title || detail <> r.item.detail in
              let by_agent = r.item.voice = "agent" in
              I.edit (log c) r.id ~title ~detail ~to_
                ~voice:(if by_agent && changed then "person" else r.item.voice)
                ~drafted:
                  (if by_agent && changed then Some (r.item.title, r.item.detail)
                   else None);
              answer_with c r.id)

  let sent_only (r : I.row) f =
    match r.hash with
    | Some h -> f h
    | None when r.status = "draft" -> invalid "not_sent" "This item is a draft."
    | None -> invalid "local" "This item stays on this machine."

  (* Sign an answer to the sent question [r] (hash [h]) in [voice], through the deny layer: in the
     clear on a circle question, sealed to every reader of a named one. *)
  let sign_answer c (r : I.row) h ~text ~voice =
    match deny_check c text with
    | Some rule -> Error (`Refused rule)
    | None -> (
        let body =
          match r.to_ with
          | Circle ->
              Ok (Item.answer_body ~item:h ~to_:Circle ~keys:[] ~text ~voice)
          | Members _ ->
              Result.map
                (fun keys ->
                  Item.answer_body ~item:h ~to_:r.to_ ~keys ~text ~voice)
                (keys_for c (readers r))
        in
        match body with
        | Error id -> Error (`No_card id)
        | Ok body -> (
            match sign c ~kind:"item_answer" body with
            | Error e -> Error (`Not_signed e)
            | Ok hash -> Ok hash))

  (* POST /items/:id/answers: the member's answer, in the clear on a circle question through the
     deny layer, sealed to every reader of a named one. *)
  let answer c (r : I.row) body =
    let text =
      String.trim (Option.value (string_field "text" body) ~default:"")
    in
    if r.item.kind <> "question" then
      invalid "not_question" "Only a question takes an answer."
    else if text = "" then
      invalid ~field:"text" "empty" "Write an answer first."
    else
      sent_only r (fun h ->
          match sign_answer c r h ~text ~voice:"person" with
          | Error (`Refused rule) ->
              invalid ~field:"text" "refused"
                ("Refused before signing: " ^ rule ^ ".")
          | Error (`No_card id) -> no_card id
          | Error (`Not_signed e) -> invalid "not_signed" e
          | Ok _ ->
              if not (own c r) then
                I.settle (log c) r.id ~why:"answered" ~at:(Time_fmt.now ());
              answer_with ~status:201 c r.id)

  (* POST /items/:id/picks: a decision naming the choice, sealed to the member and its author. *)
  let pick c (r : I.row) body =
    let me = Option.value (self_identity c) ~default:"" in
    let option = string_field "option_id" body in
    if r.item.kind <> "choice" then
      invalid "not_choice" "Only a choice takes a pick."
    else if r.item.subject = Some "suggestion" then
      invalid "suggestion" "A suggestion is picked on the note's approval page."
    else if
      r.done_ = Some "picked"
      || List.exists (fun (p : I.pick) -> p.p_author = me) (picks c r)
    then invalid "picked" "You have picked already."
    else if closed c r then invalid "closed" "This choice is closed."
    else
      match option with
      | Some o
        when List.exists (fun (x : Item.option_) -> x.id = o) r.item.options ->
          sent_only r (fun h ->
              match keys_for c [ me; r.author ] with
              | Error id -> no_card id
              | Ok keys -> (
                  match
                    sign c ~kind:"decision"
                      (Item.pick_body ~item:h ~keys ~option:o)
                  with
                  | Error e -> invalid "not_signed" e
                  | Ok _ ->
                      I.settle (log c) r.id ~why:"picked" ~at:(Time_fmt.now ());
                      answer_with ~status:201 c r.id))
      | _ -> invalid ~field:"option_id" "unknown_option" "No such option."

  let settle c (r : I.row) why =
    if r.status = "draft" then invalid "not_sent" "This item is a draft."
    else (
      I.settle (log c) r.id ~why ~at:(Time_fmt.now ());
      answer_with c r.id)

  (* PUT /items/:id/close: the author closes or reopens it, naming the answer that unblocked a
     question; theirs stands over their agent's. A local item closes on this machine alone. The
     agent's close is the same act in its [voice] (Questions). *)
  let close ?(voice = "person") c (r : I.row) body =
    let answer = string_field "answer" body in
    match field "closed" body with
    | _ when not (own c r) ->
        invalid "not_yours" "Only its author closes an item."
    | _ when r.status = "draft" -> invalid "not_sent" "This item is a draft."
    | None
    | Some
        (`Null | `Assoc _ | `List _ | `String _ | `Int _ | `Intlit _ | `Float _)
      ->
        invalid ~field:"closed" "closed" "closed is true or false."
    | Some (`Bool closed) -> (
        match answer with
        | Some a
          when not
                 (List.exists
                    (fun (x : I.answer) -> x.a_hash = a)
                    (answers c r)) ->
            invalid ~field:"answer" "unknown_answer"
              "That is not one of its answers."
        | _ -> (
            match r.hash with
            | None ->
                I.set_closed (log c) r.id ~closed ~closes_unix:None;
                answer_with c r.id
            | Some h -> (
                let fields = Item.close_body ~item:h ~closed ?answer ~voice in
                let body =
                  match r.to_ with
                  | Circle -> Ok (fields ~to_:Circle ~keys:[] ())
                  | Members _ ->
                      Result.map
                        (fun keys -> fields ~to_:r.to_ ~keys ())
                        (keys_for c (readers r))
                in
                match Result.map_error no_card body with
                | Error e -> e
                | Ok body -> (
                    match sign c ~kind:"item_close" body with
                    | Error e -> invalid "not_signed" e
                    | Ok _ -> answer_with c r.id))))

  let route c ~meth ~rest ~body =
    match (meth, rest) with
    | "POST", [] -> create c body
    | meth, id :: rest ->
        with_found (find c id) (fun r ->
            match (meth, rest) with
            | "GET", [] -> ok (item_json c r)
            | "PUT", [] -> edit c r body
            | "DELETE", [] ->
                draft_only r (fun () ->
                    I.discard (log c) r.id;
                    no_content)
            | "POST", [ "send" ] ->
                draft_only r (fun () -> Stages.compose c (fun () -> send c r))
            | "POST", [ "read" ] ->
                I.read (log c) r.id ~at:(Time_fmt.now ());
                answer_with c r.id
            | "POST", [ "answers" ] -> answer c r body
            | "POST", [ "picks" ] -> pick c r body
            | "POST", [ "acknowledge" ] ->
                if r.item.kind <> "notice" then
                  invalid "not_notice" "Only a notice is acknowledged."
                else settle c r "acknowledged"
            | "POST", [ "not_for_me" ] ->
                if r.item.kind <> "question" then
                  invalid "not_question" "Only a question is set aside."
                else if own c r then invalid "own" "You asked this question."
                else settle c r "not_for_me"
            | "PUT", [ "close" ] -> close c r body
            | _ -> not_found ())
    | _ -> not_found ()

  (* The node's own item to the member alone, sealed to their own key, or kept on this machine
     when its subject is local: a notice (raise_notice), or a choice of the node's (ISS-85004: the
     offer of a practice). Answers the item's id. *)
  let raise_item c (item : Item.t) =
    match (self_identity c, encryption c) with
    | None, _ | _, None -> Error "This node has not joined a circle yet."
    | Some me, Some enc -> (
        let to_ = Item.Members [ me ] in
        let l = log c in
        if Item.local_subject item.subject then (
          let id = "item-" ^ Store.random_id () in
          let at = Time_fmt.of_unix c.now in
          I.add l ~id ~author:me ~item ~to_ ~created_at:at ~sent_at:at ();
          Ok id)
        else
          match
            sign c ~kind:"item" (Item.item_body ~to_ ~keys:[ enc.public ] item)
          with
          | Error e -> Error e
          | Ok hash ->
              let at =
                Option.value (envelope_time c hash)
                  ~default:(Time_fmt.of_unix c.now)
              in
              I.add l ~id:hash ~hash ~author:me ~item ~to_ ~created_at:at
                ~sent_at:at
                ?closes_unix:
                  (Item.closes_at ~kind:item.kind ~sent:(unix at)
                     ~deadline:(Option.map unix item.deadline)
                     ~answered:false)
                ();
              Ok hash)

  (* ISS-52614 (docs/protocol.md, Items): a notice from the member's node, addressed to them alone
     and sealed to their own key, New until they open or acknowledge it. A local subject
     (Item.local_subject) is kept on this machine and never signed. Answers the item's id. *)
  let raise_notice c ~subject ~title ?(detail = "") () =
    raise_item c
      {
        kind = "notice";
        subject = Some subject;
        voice = "node";
        title;
        detail;
        about = None;
        options = [];
        default = None;
        deadline = None;
        adopted = None;
      }

  (* The words a member is shown for who wrote an item. *)
  let name c identity =
    match member_ref c identity with
    | `Assoc f -> (
        match List.assoc_opt "name" f with
        | Some (`String n) -> n
        | _ -> "A member")
    | _ -> "A member"

  let to_words c (r : I.row) =
    match r.to_ with
    | Item.Circle -> "the circle"
    | Members l when own c r && l = [ r.author ] -> "you"
    | Members l ->
        let me = self_identity c in
        String.concat " and "
          (List.map (fun id -> if Some id = me then "you" else name c id) l)

  (* An entry's line: who wrote it, to whom, and where a question stands. *)
  let digest_line c (r : I.row) =
    let kind = String.capitalize_ascii r.item.kind in
    let from =
      match r.item.voice with
      | "node" -> "your node"
      | _ when own c r && r.item.voice = "agent" -> "your agent"
      | _ when own c r -> "you"
      | "agent" -> name c r.author ^ "'s agent"
      | _ -> name c r.author
    in
    if r.status = "draft" then
      Printf.sprintf "Draft by %s to %s" from (to_words c r)
    else if r.item.voice = "node" then kind ^ " from your node"
    else
      let answers =
        if r.item.kind <> "question" then ""
        else
          match List.length (answers c r) with
          | 0 -> " \xc2\xb7 no answers yet"
          | 1 -> " \xc2\xb7 1 answer"
          | n -> Printf.sprintf " \xc2\xb7 %d answers" n
      in
      Printf.sprintf "%s from %s to %s%s" kind from (to_words c r) answers

  (* ISS-52614 (docs/protocol.md, The digest): the digest's Inbox part, every Draft and New item
     of the member's, Draft first and then the newest, with what the digest's reader does with
     each. [page] is the item's page on this machine's UI. *)
  let digest_entries c ~page : Digestif_mail.Digest.entry list =
    index_now c;
    let me = Option.value (self_identity c) ~default:"" in
    let rows =
      let inbox = self_identity c in
      I.page (log c) ~now:c.now ?inbox ~status:[ "draft" ] ~limit:1000 ()
      @ I.page (log c) ~now:c.now ?inbox ~status:[ "new" ] ~limit:1000 ()
    in
    List.map
      (fun (r : I.row) ->
        let open_page label =
          Digestif_mail.Digest.Page { label; url = page r.id }
        in
        let keys () =
          match r.hash with
          | None -> None
          | Some _ -> (
              match keys_for c [ me; r.author ] with
              | Ok k -> Some k
              | Error _ -> (
                  (* An own item, the node's included: the member's own key alone. *)
                  match encryption c with
                  | Some enc when r.author = me -> Some [ enc.public ]
                  | _ -> None))
        in
        let action =
          match (r.status, r.item.kind) with
          | "draft", _ -> open_page "Read the draft"
          | _, "question" -> open_page "Answer"
          | _, "choice" when r.item.subject = Some "suggestion" ->
              open_page "Pick on your machine"
          | _, "choice" -> (
              match keys () with
              | Some keys ->
                  Pick
                    {
                      keys;
                      options =
                        List.map
                          (fun (o : Item.option_) ->
                            {
                              Digestif_mail.Ask.id = o.id;
                              label = o.label;
                              recommended = o.recommended;
                            })
                          r.item.options;
                      default = r.item.default;
                      deadline = r.item.deadline;
                    }
              | None -> open_page "Pick")
          | _ -> (
              match keys () with
              | Some keys when not r.local -> Acknowledge { keys }
              | _ -> open_page "Open")
        in
        {
          Digestif_mail.Digest.item = r.id;
          hash = r.hash;
          kind = r.item.kind;
          subject = r.item.subject;
          title =
            Option.value
              (Item.off_machine_title r.item.subject)
              ~default:r.item.title;
          line = digest_line c r;
          action;
        })
      rows

  (* ISS-52614, ISS-52683 (docs/design.md, The Inbox agent): Your agent did, the review lines the
     member's agent's reading runs wrote since [since], on items that reached them and on other
     members' notes (Store.Reviews, by envelope hash), oldest first. Each line comes with the path
     of what it reviewed on this machine, the item's Inbox page or the note's Feed page, where what
     the run drafted is read. ISS-78222 *)
  let agent_did c ~since =
    let item id =
      match I.find (log c) ~now:c.now id with
      | Some r when not (own c r) ->
          Option.map
            (fun review ->
              ( Printf.sprintf "%s's %s: %s" (name c r.author) r.item.kind review,
                "/inbox/" ^ r.id ))
            r.review
      | _ -> None
    in
    let note hash =
      match Log.find (log c) hash with
      | Some row when row.signed.envelope.kind = "summary" -> (
          match
            ( identity_of c row.signed.envelope.author,
              Store.Reviews.find (log c) hash )
          with
          | Some author, Some (_, Some review)
            when Some author <> self_identity c ->
              Some
                ( Printf.sprintf "%s's note: %s" (name c author) review,
                  "/feed/" ^ hash )
          | _ -> None)
      | _ -> None
    in
    Log.rows (log c)
      "SELECT 'item', id, reviewed_at FROM ui_items WHERE review IS NOT NULL \
       AND review <> '' AND reviewed_at IS NOT NULL AND (? IS NULL OR \
       reviewed_at > ?) UNION ALL SELECT 'note', hash, reviewed_at FROM \
       ui_reviews WHERE review IS NOT NULL AND review <> '' AND (? IS NULL OR \
       reviewed_at > ?) ORDER BY 3, 2"
      [ Log.opt since; Log.opt since; Log.opt since; Log.opt since ]
    |> List.filter_map (fun row ->
        match Log.text row.(0) with
        | "note" -> note (Log.text row.(1))
        | _ -> item (Log.text row.(1)))

  (* node_status.inbox: the member's Draft and New items, counted from the index as it stands. The
     status route brings the index up once, through Prompts.sync, before it reads this: a second pass
     here would run the whole index again, keystore read included, on every status call. ISS-83181 *)
  let status_fields c : (string * Yojson.Safe.t) list =
    [
      ("inbox", `Int (I.inbox_count (log c) ~now:c.now ?me:(self_identity c) ()));
    ]
end

(* ISS-51009: suggesting a change to the nightly note prompt (docs/design.md, Suggesting a change to
   the note prompt). A suggestion is an item, a choice whose subject is `suggestion`, addressed to its
   judges and sealed to them (docs/protocol.md, Items, Prompt suggestions); the rounds are read out
   of the summaries the judges approve. Once every judge has picked the
   suggested version in a round, the suggestion's author's node writes a `prompt` envelope, circle
   state every member reads, a newcomer included: from then on it is the circle's live prompt, and
   every member's note is written with it. The author's nightly behavior then opens the pull
   request proposing it as the release's default, and records it here. *)
module Prompts = struct
  module S = Suggestions
  module I = Store.Items

  (* Every suggestion this node can read, folded, after the Inbox index is brought up to the log;
     each suggestion item's close is settled from its fold as it goes: closed once its rounds
     decide it, open while its judges judge it (ISS-52613). *)
  let all c =
    Inbox.index c;
    let l = log c in
    let judged = S.read l ~identity_of:(identity_of c) in
    let settle =
      List.filter_map
        (fun (j : S.judged) ->
          match I.by_hash l ~now:c.now j.s.hash with
          | Some r ->
              let closed = j.status <> S.Judging in
              if r.closed_flag <> closed || r.closes_unix <> None then
                Some (r.id, closed)
              else None
          | None -> None)
        judged
    in
    if settle <> [] then
      upkeep c (fun () ->
          List.iter
            (fun (id, closed) -> I.set_closed l id ~closed ~closes_unix:None)
            settle);
    judged

  (* Settle every suggestion item before the Inbox is read. *)
  let sync c = ignore (all c)
  let me c = Option.value (self_identity c) ~default:""
  let k_pull_request hash = "prompt_pull_request:" ^ hash
  let pull_request c hash = Store.config (log c) (k_pull_request hash)

  let name_of c id =
    match member_ref c id with
    | `Assoc f -> (
        match List.assoc_opt "name" f with Some (`String n) -> n | _ -> id)
    | _ -> id

  (* The circle's live prompt: the newest `prompt` envelope this node can stand behind. One that
     names a suggestion this node holds must match it: its author, its text, and an adoption this
     node's own fold reached. One naming a suggestion this node cannot read (it was written before
     this member joined) stands on its signature, as every circle-state envelope does. *)
  type live = {
    l_suggestion : string;
    l_text : string;
    l_change : string;
    l_author : string;
    l_at : string;
  }

  let live c (judged : S.judged list) =
    Log.of_kind (log c) "prompt"
    |> List.filter_map (fun (r : Log.row) ->
        match (r.signed.body, identity_of c r.signed.envelope.author) with
        | Some b, Some author -> (
            match
              ( Content.str_field "suggestion" b,
                Content.str_field "text" b,
                Content.str_field "change" b )
            with
            | Some sh, Some text, change ->
                let stands =
                  match S.find judged sh with
                  | None -> true
                  | Some j ->
                      j.status = S.Adopted_status
                      && j.s.text = text && j.s.author = author
                in
                if stands then
                  Some
                    {
                      l_suggestion = sh;
                      l_text = text;
                      l_change = Option.value change ~default:"";
                      l_author = author;
                      l_at = r.signed.envelope.created_at;
                    }
                else None
            | _ -> None)
        | _ -> None)
    |> List.fold_left
         (fun acc l ->
           match acc with Some a when a.l_at >= l.l_at -> acc | _ -> Some l)
         None

  let summary_json c ~me (j : S.judged) : Yojson.Safe.t =
    let running = S.running (all c) ~me in
    `Assoc
      [
        ("hash", str j.s.hash);
        ("author", member_ref c j.s.author);
        ("created_at", str j.s.created_at);
        ("change", str j.s.change);
        ("status", str (S.status_name j.status));
        ("judge", `Bool (S.judges_ j ~me));
        ( "running",
          `Bool
            (match running with Some r -> r.s.hash = j.s.hash | None -> false)
        );
      ]

  let round_json c (r : S.round) : Yojson.Safe.t =
    `Assoc
      ([
         ("number", `Int r.number);
         ( "picks",
           `List
             (List.map
                (fun (judge, p, at) ->
                  `Assoc
                    [
                      ("judge", member_ref c judge);
                      ("pick", str (S.pick_name p));
                      ("at", str at);
                    ])
                r.picks) );
       ]
      @
      match r.result with
      | Some x -> [ ("result", str (S.result_name x)) ]
      | None -> [])

  (* A pull request is owed once the author's node has written the adoption and recorded none. *)
  let written_adoption c hash =
    List.exists
      (fun (r : Log.row) ->
        Option.bind r.signed.body (Content.str_field "suggestion") = Some hash)
      (Log.of_kind (log c) "prompt")

  let owed c ~me (j : S.judged) =
    j.status = S.Adopted_status
    && j.s.author = me
    && pull_request c j.s.hash = None
    && written_adoption c j.s.hash

  let suggestion_json c (judged : S.judged list) (j : S.judged) : Yojson.Safe.t
      =
    let me = me c in
    let running = S.running judged ~me in
    let live = live c judged in
    `Assoc
      ([
         ("hash", str j.s.hash);
         ("author", member_ref c j.s.author);
         ("created_at", str j.s.created_at);
         ("change", str j.s.change);
         ("text", str j.s.text);
         ("prompt_id", str j.s.id);
         ("judges", `List (List.map (member_ref c) j.s.judges));
         ("status", str (S.status_name j.status));
         ("judge", `Bool (S.judges_ j ~me));
         ( "running",
           `Bool
             (match running with
             | Some r -> r.s.hash = j.s.hash
             | None -> false) );
         ("rounds", `List (List.map (round_json c) j.rounds));
       ]
      @ opt "decided_at" j.decided_at
      @ [
          ( "live",
            `Bool
              (match live with
              | Some l -> l.l_suggestion = j.s.hash
              | None -> false) );
          ("can_withdraw", `Bool (j.status = S.Judging && j.s.author = me));
          ("pull_request_owed", `Bool (owed c ~me j));
        ]
      @ opt "pull_request_url" (pull_request c j.s.hash))

  (* GET /note_prompt: the circle's live prompt, and the suggestion this member's notes judge. *)
  let note_prompt c =
    let judged = all c in
    let me = me c in
    let live = live c judged in
    ok
      (`Assoc
         ((match live with
            | None -> []
            | Some l ->
                [
                  ("text", str l.l_text);
                  ("id", str (S.prompt_id l.l_text));
                  ( "adoption",
                    `Assoc
                      [
                        ("suggestion", str l.l_suggestion);
                        ("change", str l.l_change);
                        ("author", member_ref c l.l_author);
                        ("at", str l.l_at);
                      ] );
                ])
         @
         match S.running judged ~me with
         | Some j -> [ ("running", suggestion_json c judged j) ]
         | None -> []))

  let list c query =
    let judged = all c in
    let newest = List.rev judged in
    let known h = List.exists (fun (j : S.judged) -> j.s.hash = h) judged in
    match
      let* limit = limit_param query ~default:100 in
      let* after = cursor_param query ~known in
      Ok (limit, after)
    with
    | Error e -> e
    | Ok (limit, after) ->
        let rec drop = function
          | [] -> []
          | (j : S.judged) :: rest when Some j.s.hash = after -> rest
          | _ :: rest -> drop rest
        in
        let page = match after with None -> newest | Some _ -> drop newest in
        let me = me c in
        ok
          (`List
             (List.filteri (fun i _ -> i < limit) page
             |> List.map (summary_json c ~me)))

  let get c hash =
    let judged = all c in
    with_found (S.find judged hash) (fun j -> ok (suggestion_json c judged j))

  let one_line s =
    String.concat " "
      (List.filter
         (fun w -> w <> "")
         (String.split_on_char ' '
            (String.map (function '\n' | '\r' | '\t' -> ' ' | ch -> ch) s)))

  (* Why a suggestion of [text], [change] and the judges [named] cannot be written, or whom it is
     addressed to. The words pass the deny layer before anything is kept, as every outbound text
     does; [unknown_code] is the code a judge who is not a member is refused with. *)
  let check c ~text ~change ~named ~unknown_code =
    match self_identity c with
    | None -> Error (invalid "not_joined" "This node has not joined a circle.")
    | Some me -> (
        let live = live c (all c) in
        match () with
        | _ when Store.Stages.stage (log c) <> "active" ->
            Error
              (invalid "not_active"
                 "Your first note has to go out before you suggest a change.")
        | _ when text = "" ->
            Error
              (invalid ~field:"text" "empty" "Write the prompt you suggest.")
        | _ when not (Re.execp (Re.compile (Re.str S.placeholder)) text) ->
            Error
              (invalid ~field:"text" "always_on"
                 ("The prompt has to include " ^ S.placeholder
                ^ ", where the always-on rule goes."))
        | _ when change = "" ->
            Error
              (invalid ~field:"change" "empty"
                 "Say in one line what it changes.")
        | _ when match live with Some l -> l.l_text = text | None -> false ->
            Error
              (invalid ~field:"text" "unchanged"
                 "This is the prompt that stands now.")
        | _
          when List.exists (fun j -> j <> me && find_identity c j = None) named
          ->
            Error
              (invalid ~field:"judges" unknown_code "A judge is not a member.")
        | _ -> (
            match (deny_check c text, deny_check c change) with
            | Some rule, _ | None, Some rule ->
                Error (invalid "deny" ("Not sent. " ^ rule))
            | None, None -> (
                match
                  Inbox.to_of ~judges:true c ~me ~circle:false ~members:named
                with
                | Error e -> Error e
                | Ok to_ -> Ok (me, to_))))

  (* Write the suggestion as a draft in its author's Inbox, and send it when [send]: the item the
     judges' Inboxes hold, a choice to them (Suggestions.item). Answers the item's id. *)
  let write c ~text ~change ~named ~send ~unknown_code =
    match check c ~text ~change ~named ~unknown_code with
    | Error e -> Error e
    | Ok (me, to_) -> (
        let id =
          Inbox.add_draft c ~author:me ~item:(S.item ~text ~change) ~to_
        in
        if not send then Ok id
        else
          match I.find (log c) ~now:c.now id with
          | None -> Error (not_found ())
          | Some r ->
              let res = Stages.compose c (fun () -> Inbox.send c r) in
              if res.status <> 201 then (
                I.discard (log c) id;
                Error res)
              else Ok id)

  let named_of = function
    | Some (`List l) ->
        Ok (List.filter_map (function `String s -> Some s | _ -> None) l)
    | None | Some `Null -> Ok []
    | Some _ -> Error ()

  (* POST /suggestions: the suggestion's own form, sent at once. *)
  let create c body =
    let text =
      String.trim (Option.value (string_field "text" body) ~default:"")
    in
    let change =
      one_line (Option.value (string_field "change" body) ~default:"")
    in
    match named_of (field "judges" body) with
    | Error () ->
        invalid ~field:"judges" "judges" "judges is a list of identities."
    | Ok named -> (
        match
          write c ~text ~change ~named ~send:true ~unknown_code:"judges"
        with
        | Error e -> e
        | Ok id -> (
            match I.find (log c) ~now:c.now id with
            | Some { hash = Some hash; _ } ->
                let judged = all c in
                with_found (S.find judged hash) (fun j ->
                    ok ~status:201 (suggestion_json c judged j))
            | _ -> not_found ()))

  (* POST /items with the subject suggestion: New item's prompt suggestion, whose title is the
     change line, whose detail is the prompt and whose members are its judges, saved as a Draft or
     sent at once. *)
  let create_item c body =
    let text =
      String.trim (Option.value (string_field "detail" body) ~default:"")
    in
    let change =
      one_line (Option.value (string_field "title" body) ~default:"")
    in
    match named_of (field "members" body) with
    | Error () ->
        invalid ~field:"members" "members" "members is a list of identities."
    | Ok named -> (
        let send =
          match field "send" body with Some (`Bool b) -> b | _ -> false
        in
        match
          write c ~text ~change ~named ~send ~unknown_code:"not_in_circle"
        with
        | Error e -> e
        | Ok id -> Inbox.answer_with ~status:201 c id)

  (* POST /items/:id/send on a suggestion's draft: checked again, since the prompt that stands may
     have changed since it was saved. *)
  let send_item c (r : I.row) =
    if r.status <> "draft" then invalid "not_draft" "This item has been sent."
    else
      match
        check c ~text:r.item.detail ~change:(one_line r.item.title)
          ~named:(Item.to_list r.to_) ~unknown_code:"not_in_circle"
      with
      | Error e -> e
      | Ok _ -> Stages.compose c (fun () -> Inbox.send c r)

  (* The suggestion's own writes on /items: creating one, and sending its draft. Every other item
     route, and every read, is the Inbox's, after the suggestions are settled. *)
  let route_items c ~meth ~rest ~body =
    sync c;
    match (meth, rest) with
    | "POST", [] when string_field "subject" body = Some "suggestion" ->
        create_item c body
    | "POST", [ id; "send" ] -> (
        match Inbox.find c id with
        | Some r when r.item.subject = Some "suggestion" -> send_item c r
        | _ -> Inbox.route c ~meth ~rest ~body)
    | _ -> Inbox.route c ~meth ~rest ~body

  (* DELETE /suggestions/:hash: its author withdraws it with a retract. *)
  let withdraw c hash =
    let judged = all c in
    with_found (S.find judged hash) (fun j ->
        if j.s.author <> me c then
          invalid "not_author" "Only its author withdraws a suggestion."
        else if j.status <> S.Judging then
          invalid "decided" "This suggestion is already decided."
        else
          match sign c ~kind:"retract" (Bodies.make_retract ~target:hash) with
          | Error e -> errors 500 "failed" e
          | Ok retract ->
              Log.drop_body (log c) ~hash ~retracted_by:retract;
              no_content)

  (* PUT /suggestions/:hash/pull_request: the nightly behavior opened it. *)
  let set_pull_request c hash body =
    let judged = all c in
    with_found (S.find judged hash) (fun j ->
        match string_field "url" body with
        | Some url when owed c ~me:(me c) j && String.trim url <> "" ->
            Store.set_config (log c) (k_pull_request hash) (String.trim url);
            Problems.resolve c ~job:"pull_request" ();
            ok (suggestion_json c judged j)
        | (Some _ | None) when not (owed c ~me:(me c) j) ->
            invalid "not_owed" "No pull request is owed for this suggestion."
        | _ -> invalid ~field:"url" "url" "Name the pull request.")

  (* On every pass: each suggestion this member wrote that its judges adopted becomes the circle's
     live prompt, by the `prompt` envelope only its author's node writes. *)
  let adopt_due c =
    match self_identity c with
    | None -> ()
    | Some me ->
        List.iter
          (fun (j : S.judged) ->
            if
              j.status = S.Adopted_status
              && j.s.author = me
              && not (written_adoption c j.s.hash)
            then
              ignore
                (sign c ~kind:"prompt"
                   (`Assoc
                      [
                        ("suggestion", str j.s.hash);
                        ("text", str j.s.text);
                        ("change", str j.s.change);
                      ])))
          (all c)
end

(* ISS-52611: the Inbox agent (docs/design.md, The Inbox agent). Every member with an agent reads
   what reaches them under an Inbox prompt, the release's default (behaviors/prompts/inbox.md) until
   they edit it; the reading behavior runs it once a sync and hands back what the run did. The guards
   are here, never in the prompt: an answer goes out in the agent's voice only while the member is
   Active and only through the deny layer, and is otherwise kept for the member; an intro, a share and
   a behavior are drafts the member sends; work is a notice to the member alone. Nothing here picks a
   choice or sends a draft. A practice the run saw working for another member's agent is adopted
   into the member's practices only while they turned adopting on, and is otherwise a notice to
   them alone (ISS-80159). *)
module Inbox_agent = struct
  module I = Store.Items

  let k_prompt = "inbox_prompt"

  (* The message of a refusal, for the run's problems. *)
  let message_of (r : response) =
    match r.body with
    | Some (`List (`Assoc f :: _)) -> (
        match List.assoc_opt "message" f with
        | Some (`String m) -> m
        | _ -> "refused")
    | _ -> "refused"

  (* A behavior choice stands on Not now a week after the agent drafted it. *)
  let behavior_deadline = 7.0 *. 86_400.0

  let default_file c =
    Filename.concat
      (Digestif_update.Layout.behaviors_in
         (Digestif_update.Layout.good_link c.node.dir))
      "prompts/inbox.md"

  (* The release's default, as its file holds it; None for a release without one. *)
  let default_text c =
    match In_channel.with_open_bin (default_file c) In_channel.input_all with
    | t when String.trim t <> "" -> Some t
    | _ -> None
    | exception Sys_error _ -> None

  let k_updated = "inbox_prompt_updated_at"

  (* Why the agent does not run now (ISS-65250): no read hook is set, or its last run failed. *)
  let cannot_run c =
    let l = log c in
    if Log.get_config l (Store.k_behavior "read") = None then
      Some "No read hook is set, so the Inbox agent does not run."
    else if
      List.exists
        (fun (p : Store.Problems.problem) -> p.job = "read_circle")
        (Store.Problems.open_ l)
    then Some "The Inbox agent's last run failed; behaviors/read.log says why."
    else None

  (* ISS-80159: practices from the circle. A practice is one line of how the member's Inbox agent
     works, which the reading run saw working for another member's agent. While the member turned
     adopting on (setup's Inbox step, or Settings, Inbox agent), one the run names is added to their
     practices, which every later reading run reads under their own prompt; otherwise it is a notice
     to them alone, for them to decide. The filing run is never handed a practice, so none can say
     where or how work is filed, and none can widen a guard: every guard is this module's code. *)
  let k_adopt = "inbox_adopt_practices"
  let k_practices = "inbox_practices"

  (* How many practices a member keeps, and how long one may be: one line. *)
  let max_practices = 20
  let max_practice_length = 300

  type practice = {
    p_id : string;
    p_text : string;
    p_author : string;  (** the identity whose message it was seen in *)
    p_about : string;  (** that message's envelope hash *)
    p_at : string;
  }

  let adopting c = Log.get_config (log c) k_adopt = Some "true"

  let set_adopting c on =
    if on then Log.set_config (log c) k_adopt "true"
    else Log.unset_config (log c) k_adopt

  let practices c =
    match
      Option.map Yojson.Safe.from_string (Log.get_config (log c) k_practices)
    with
    | Some (`List l) ->
        List.filter_map
          (function
            | `Assoc f -> (
                let s k =
                  match List.assoc_opt k f with
                  | Some (`String v) -> Some v
                  | _ -> None
                in
                match
                  (s "id", s "text", s "author", s "about", s "adopted_at")
                with
                | Some p_id, Some p_text, Some p_author, Some p_about, Some p_at
                  ->
                    Some { p_id; p_text; p_author; p_about; p_at }
                | _ -> None)
            | _ -> None)
          l
    | _ -> []
    | exception Yojson.Json_error _ -> []

  let save_practices c ps =
    Log.set_config (log c) k_practices
      (Yojson.Safe.to_string
         (`List
            (List.map
               (fun p ->
                 `Assoc
                   [
                     ("id", str p.p_id);
                     ("text", str p.p_text);
                     ("author", str p.p_author);
                     ("about", str p.p_about);
                     ("adopted_at", str p.p_at);
                   ])
               ps)))

  let practice_json c p : Yojson.Safe.t =
    `Assoc
      [
        ("id", str p.p_id);
        ("text", str p.p_text);
        ("author", member_ref c p.p_author);
        ("about", str p.p_about);
        ("adopted_at", str p.p_at);
      ]

  (* Two practices are the same when their words are, whatever the case and spacing. *)
  let same_words a b =
    let norm t =
      String.concat " "
        (List.filter (( <> ) "")
           (String.split_on_char ' ' (String.lowercase_ascii (String.trim t))))
    in
    norm a = norm b

  let json c text : Yojson.Safe.t =
    let d = default_text c in
    let reviewed, last = Store.Reviews.totals (log c) in
    `Assoc
      ([
         ("text", str text);
         ("is_default", `Bool (d = Some text));
         ("default_text", str (Option.value d ~default:""));
       ]
      @ opt "updated_at" (Log.get_config (log c) k_updated)
      @ [ ("reviewed", `Int reviewed) ]
      @ opt "last_reviewed_at" last
      @ opt "cannot_run" (cannot_run c)
      @ [
          ("adopt_practices", `Bool (adopting c));
          ("practices", `List (List.map (practice_json c) (practices c)));
        ])

  (* The member's own save; a reset is the default again, with no time of its own. *)
  let save c text ~edited =
    Log.set_config (log c) k_prompt text;
    if edited then Log.set_config (log c) k_updated (Time_fmt.now ())
    else Log.unset_config (log c) k_updated

  let no_agent () =
    errors 404 "no_agent"
      "Choose an agent first: the Inbox agent is your agent."

  let no_default () =
    errors 404 "no_default" "This release carries no default Inbox prompt."

  (* The member's prompt. A node with an agent that has none saved saves the default, so every node
     with an agent reads under one. *)
  let prompt c =
    match Log.get_config (log c) k_prompt with
    | Some t -> Some t
    | None ->
        Option.map
          (fun d ->
            Log.set_config (log c) k_prompt d;
            d)
          (default_text c)

  let with_agent c f = if Agent.saved c.node = None then no_agent () else f ()

  let get c =
    with_agent c (fun () ->
        match prompt c with Some t -> ok (json c t) | None -> no_default ())

  let put c body =
    with_agent c (fun () ->
        let text = Option.value (string_field "text" body) ~default:"" in
        if String.trim text = "" then
          invalid ~field:"text" "empty"
            "Write the prompt, or reset it to default."
        else (
          (match field "adopt_practices" body with
          | Some (`Bool on) -> set_adopting c on
          | _ -> ());
          save c text ~edited:true;
          ok (json c text)))

  (* DELETE /settings/inbox_agent/practices/:id: the member removes a practice; later runs no
     longer read it. *)
  let remove_practice c id =
    with_agent c (fun () ->
        let ps = practices c in
        if not (List.exists (fun p -> p.p_id = id) ps) then
          errors 404 "not_found" "No such practice."
        else (
          save_practices c (List.filter (fun p -> p.p_id <> id) ps);
          match prompt c with Some t -> ok (json c t) | None -> no_default ()))

  let reset c =
    with_agent c (fun () ->
        match default_text c with
        | None -> no_default ()
        | Some d ->
            save c d ~edited:false;
            ok (json c d))

  let trimmed name j =
    String.trim (Option.value (string_field name (Some j)) ~default:"")

  let list name body =
    match field name body with Some (`List l) -> l | _ -> []

  (* Reviewed and the review line on everything the run read: an item that reached the member, or
     another member's note. The member's own items and the node's are never read. *)
  let review c ~at j =
    let hash = trimmed "hash" j in
    let line = trimmed "review" j in
    let review = if line = "" then None else Some line in
    match I.by_hash (log c) ~now:c.now hash with
    | Some r when Inbox.own c r -> Error (hash ^ ": the member's own item")
    | Some r ->
        I.set_review (log c) r.id ~at ~review;
        Ok ()
    | None -> (
        match Log.find (log c) hash with
        | Some row when row.signed.envelope.kind = "summary" ->
            Store.Reviews.set (log c) hash ~at ~review;
            Ok ()
        | _ -> Error (hash ^ ": no item or note"))

  let inactive =
    "Nothing is sent in your name until your first note goes out, or while you \
     are paused."

  (* An answer to another member's note is a reply to it in the circle, in the agent's voice
     (ISS-83154), sent like an answer to a question: only while the member is Active and through
     the deny layer, and otherwise kept for the member as the note's draft reply. *)
  let reply c ~keep (m : msg) ~send ~text =
    match () with
    | _ when text = "" -> Error (m.hash ^ ": an empty answer")
    | _ when not send -> keep None
    | _ when not (Store.Stages.active (log c)) -> keep (Some inactive)
    | _ -> (
        match deny_check c text with
        | Some rule -> keep (Some ("Refused before signing: " ^ rule ^ "."))
        | None -> (
            let body =
              Content.summary_body ~text ~voice:"agent" ~reply_to:m.hash
                ~stage:(Store.Stages.stage (log c))
                ()
            in
            match sign c ~kind:"summary" body with
            | Ok _ -> Ok `Sent
            | Error e -> keep (Some e)))

  (* One answer: sent in the agent's voice when the agent may send it, else kept for the member.
     A question's answer, or a note's reply. A draft the member asked for is never sent. *)
  let answer c ~at j =
    let hash = trimmed "item" j and text = trimmed "text" j in
    let asked = Store.Reviews.draft_request (log c) hash <> None in
    let send = field "send" (Some j) <> Some (`Bool false) && not asked in
    let keep reason =
      Store.Reviews.set_agent_answer (log c) hash ~text ~reason ~at;
      Store.Reviews.end_draft (log c) hash;
      Ok `Kept
    in
    match I.by_hash (log c) ~now:c.now hash with
    | None -> (
        match reply_note c hash with
        | Some m -> reply c ~keep m ~send ~text
        | None -> Error (hash ^ ": no such item or note"))
    | Some r when r.item.kind <> "question" -> Error (hash ^ ": not a question")
    | Some r when Inbox.own c r -> Error (hash ^ ": the member's own question")
    | Some _ when text = "" -> Error (hash ^ ": an empty answer")
    | Some r when Inbox.closed c r -> Error (hash ^ ": the question is closed")
    | Some _ when not send -> keep None
    | Some _ when not (Store.Stages.active (log c)) -> keep (Some inactive)
    | Some r -> (
        match Inbox.sign_answer c r hash ~text ~voice:"agent" with
        | Ok _ ->
            I.settle (log c) r.id ~why:"answered" ~at;
            Ok `Sent
        | Error (`Refused rule) ->
            keep (Some ("Refused before signing: " ^ rule ^ "."))
        | Error (`No_card id) -> keep (Some (id ^ " has no published card."))
        | Error (`Not_signed e) -> keep (Some e))

  (* One item the agent wrote: an intro, a share or a behavior as a draft its member sends; work as
     a notice to the member alone, sent at once while they are Active; or a credit, the notice to an
     idea's author that the member's agent filed it (ISS-65274), sent at once only when the reading
     behavior says the brief, Rules and both checks allow it, the member is Active and the deny layer
     passes it, and otherwise left a draft the member sends. *)
  let item c ~me j =
    let subject = trimmed "subject" j and title = trimmed "title" j in
    let detail = trimmed "detail" j and about = trimmed "about" j in
    let members =
      List.sort_uniq compare
        (Option.value (strings_field "members" (Some j)) ~default:[])
    in
    let circle = field "circle" (Some j) = Some (`Bool true) in
    let kind = trimmed "kind" j in
    let send_asked = field "send" (Some j) = Some (`Bool true) in
    let adopted = trimmed "adopted" j in
    let base : Item.t =
      {
        kind = "notice";
        subject = Some subject;
        voice = "agent";
        title;
        detail;
        about = (if about = "" then None else Some about);
        options = [];
        default = None;
        deadline = None;
        adopted = None;
      }
    in
    let to_ () = Inbox.to_of c ~me ~circle ~members in
    let err e = Error (subject ^ ": " ^ message_of e) in
    let built =
      match subject with
      | _ when title = "" -> Error (subject ^ ": an empty title")
      | "intro" when circle || List.length members <> 2 ->
          Error "intro: an intro names the two people it introduces"
      | "intro" -> (
          match to_ () with Ok t -> Ok (base, t, false) | Error e -> err e)
      | "share" -> (
          let kind = if kind = "question" then "question" else "notice" in
          match to_ () with
          | Ok t -> Ok ({ base with kind }, t, false)
          | Error e -> err e)
      | "behavior" -> (
          match to_ () with
          | Ok t ->
              Ok
                ( {
                    base with
                    kind = "choice";
                    options =
                      [
                        {
                          id = "install";
                          label = "Install";
                          recommended = false;
                        };
                        {
                          id = "not_now";
                          label = "Not now";
                          recommended = true;
                        };
                      ];
                    default = Some "not_now";
                    deadline =
                      Some (Time_fmt.of_unix (c.now +. behavior_deadline));
                  },
                  t,
                  false )
          | Error e -> err e)
      | "work" | "practice" -> Ok (base, Item.Members [ me ], true)
      | "credit" when circle || List.length members <> 1 ->
          Error "credit: a credit names the one member who had the idea"
      | "credit" when about = "" ->
          Error "credit: a credit names the message the idea came from"
      | "credit"
        when adopted <> "" && not (List.mem adopted Item.adopted_values) ->
          Error "credit: adopted is as_work or as_how_agent_works"
      | "credit" -> (
          let adopted = if adopted = "" then "as_work" else adopted in
          match to_ () with
          | Ok t -> Ok ({ base with adopted = Some adopted }, t, send_asked)
          | Error e -> err e)
      | s -> Error (s ^ ": not a subject the Inbox agent writes")
    in
    match built with
    | Error e -> Error e
    | Ok (item, to_, send) -> (
        let id = Inbox.add_draft c ~author:me ~item ~to_ in
        if not (send && Store.Stages.active (log c)) then Ok id
        else
          match I.find (log c) ~now:c.now id with
          | None -> Ok id
          | Some r ->
              let res = Inbox.send c r in
              if res.status = 201 then Ok id
              else if subject = "credit" then
                (* The deny layer refused it: the draft waits for the member. *)
                Ok id
              else
                Error ("work: the notice could not be sent: " ^ message_of res))

  (* Who wrote the message a practice was seen in: an item that reached the member, or another
     member's note. None for a message this node does not hold. *)
  let message_author c hash =
    match I.by_hash (log c) ~now:c.now hash with
    | Some r -> Some r.author
    | None -> (
        match Log.find (log c) hash with
        | Some row when row.signed.envelope.kind = "summary" ->
            Some
              (Option.value
                 (identity_of c row.signed.envelope.author)
                 ~default:row.signed.envelope.author)
        | _ -> None)

  let has_link t =
    let has sub =
      let n = String.length sub and m = String.length t in
      let rec go i = i + n <= m && (String.sub t i n = sub || go (i + 1)) in
      go 0
    in
    has "http://" || has "https://"

  (* ISS-85004: the credit a reading run composed for a practice, held beside the line and sent to
     the practice's author only once the line is saved. Its words were checked by the behavior;
     Active and the deny layer are read again when it is sent. *)
  type credit = { cr_title : string; cr_detail : string; cr_send : bool }

  let credit_of j =
    match field "credit" (Some j) with
    | Some (`Assoc _ as cj) ->
        let title = trimmed "title" cj in
        if title = "" then None
        else
          Some
            {
              cr_title = title;
              cr_detail = trimmed "detail" cj;
              cr_send = field "send" (Some cj) = Some (`Bool true);
            }
    | _ -> None

  let credit_json cr : Yojson.Safe.t =
    `Assoc
      [
        ("title", str cr.cr_title);
        ("detail", str cr.cr_detail);
        ("send", `Bool cr.cr_send);
      ]

  (* ISS-85004: an offer of a practice to a member whose adopting is off: the node's choice of
     Adopt or Not now ([o_item]), the line, its author and message, and the credit the run
     composed. Kept until the member picks, or the offer's week runs out. *)
  let k_offers = "inbox_practice_offers"
  let adopt_option = "adopt"
  let not_now_option = "not_now"

  type offer = {
    o_item : string;
    o_text : string;
    o_author : string;
    o_about : string;
    o_credit : credit option;
  }

  let offers c =
    match
      Option.map Yojson.Safe.from_string (Log.get_config (log c) k_offers)
    with
    | Some (`List l) ->
        List.filter_map
          (fun j ->
            let s k = trimmed k j in
            match (s "item", s "text", s "author", s "about") with
            | "", _, _, _ | _, "", _, _ | _, _, "", _ | _, _, _, "" -> None
            | o_item, o_text, o_author, o_about ->
                Some
                  { o_item; o_text; o_author; o_about; o_credit = credit_of j })
          l
    | _ -> []
    | exception Yojson.Json_error _ -> []

  let save_offers c os =
    if os = [] then Log.unset_config (log c) k_offers
    else
      Log.set_config (log c) k_offers
        (Yojson.Safe.to_string
           (`List
              (List.map
                 (fun o ->
                   `Assoc
                     ([
                        ("item", str o.o_item);
                        ("text", str o.o_text);
                        ("author", str o.o_author);
                        ("about", str o.o_about);
                      ]
                     @
                     match o.o_credit with
                     | None -> []
                     | Some cr -> [ ("credit", credit_json cr) ]))
                 os)))

  let drop_offer c id =
    save_offers c (List.filter (fun o -> o.o_item <> id) (offers c))

  (* Whether [text] may be saved now: not the same words as a line already held, and fewer than
     [max_practices] held. *)
  let can_save c text =
    let ps = practices c in
    if List.exists (fun p -> same_words p.p_text text) ps then Error `Held
    else if List.length ps >= max_practices then Error `Full
    else Ok ()

  let held_already = "practice: adopted already"

  let full_message =
    Printf.sprintf
      "practice: %d practices are adopted already; the member removes one on \
       Settings, Inbox agent"
      max_practices

  let why = function `Held -> held_already | `Full -> full_message

  (* The one step that saves a practice, for a run with adopting on and for Adopt on an offer
     alike: the line saved, a notice to the member alone saying so, and the credit to its author
     sent within its guards, else kept as the member's draft (ISS-85004). Answers the notice's id,
     and the credit's id or why it could not be written. *)
  let adopt c ~me ~text ~author ~about ~credit =
    match can_save c text with
    | Error e -> Error (why e)
    | Ok () ->
        let name, _ = names c author in
        save_practices c
          (practices c
          @ [
              {
                p_id = "practice-" ^ Store.random_id ();
                p_text = text;
                p_author = author;
                p_about = about;
                p_at = Time_fmt.now ();
              };
            ]);
        let credited =
          Option.map
            (fun cr ->
              item c ~me
                (`Assoc
                   [
                     ("subject", str "credit");
                     ("members", `List [ str author ]);
                     ("title", str cr.cr_title);
                     ("detail", str cr.cr_detail);
                     ("about", str about);
                     ("send", `Bool cr.cr_send);
                     ("adopted", str "as_how_agent_works");
                   ]))
            credit
        in
        Result.map
          (fun id -> (id, credited))
          (item c ~me
             (`Assoc
                [
                  ("subject", str "practice");
                  ( "title",
                    str ("Adopted a practice from " ^ name ^ ": " ^ text) );
                  ( "detail",
                    str
                      "Your Inbox agent works this way from its next run. \
                       Settings, Inbox agent lists it, where you remove it." );
                  ("about", str about);
                ]))

  (* The offer's words: the line and its author, and what Adopt also does about the credit. *)
  let offer_detail ~name credit =
    match credit with
    | None -> "Adopt this from " ^ name ^ "?"
    | Some cr when cr.cr_send ->
        Printf.sprintf
          "Adopt this from %s? Adopting also tells %s their idea is in how \
           your agent works."
          name name
    | Some _ ->
        Printf.sprintf
          "Adopt this from %s? Adopting also keeps a credit to %s as your \
           draft to send."
          name name

  (* ISS-85004: the offer, the node's choice of Adopt or Not now to the member alone, Not now a
     week after the run. The credit waits beside it. *)
  let offer c ~text ~author ~about ~credit =
    let name, _ = names c author in
    let item : Item.t =
      {
        kind = "choice";
        subject = Some "practice";
        voice = "node";
        title = "A practice you could adopt, from " ^ name ^ ": " ^ text;
        detail = offer_detail ~name credit;
        about = Some about;
        options =
          [
            { id = adopt_option; label = "Adopt"; recommended = false };
            { id = not_now_option; label = "Not now"; recommended = false };
          ];
        default = Some not_now_option;
        deadline = Some (Time_fmt.of_unix (c.now +. behavior_deadline));
        adopted = None;
      }
    in
    match Inbox.raise_item c item with
    | Error e -> Error ("practice: the offer could not be written: " ^ e)
    | Ok id ->
        save_offers c
          (offers c
          @ [
              {
                o_item = id;
                o_text = text;
                o_author = author;
                o_about = about;
                o_credit = credit;
              };
            ]);
        Ok id

  (* One practice the run saw working for another member's agent (ISS-80159): its text checked
     here, its author read from the message it names, never from the run. Adopted, with the
     credit the run composed for its author, while the member turned adopting on; otherwise
     offered to them as a choice of Adopt or Not now (ISS-85004). Words already held are neither.
     Answers the text adopted, if any, and the ids of what it wrote. *)
  let practice c ~me j =
    let text =
      String.concat " "
        (List.filter (( <> ) "")
           (String.split_on_char ' '
              (String.map
                 (function '\n' | '\r' | '\t' -> ' ' | ch -> ch)
                 (trimmed "text" j))))
    in
    let about = trimmed "about" j in
    let credit = credit_of j in
    match message_author c about with
    | _ when text = "" -> Error "practice: an empty practice"
    | _ when String.length text > max_practice_length ->
        Error
          (Printf.sprintf "practice: longer than %d characters"
             max_practice_length)
    | _ when has_link text ->
        Error "practice: names a link; a practice says how to work, not where"
    | None -> Error "practice: names no message this node holds"
    | Some author when author = me -> Error "practice: the member's own message"
    | Some _ when can_save c text = Error `Held -> Error held_already
    | Some author when not (adopting c) ->
        Result.map
          (fun id -> (None, [ id ]))
          (offer c ~text ~author ~about ~credit)
    | Some author -> (
        match adopt c ~me ~text ~author ~about ~credit with
        | Error e -> Error e
        | Ok (id, None) -> Ok (Some text, [ id ])
        | Ok (id, Some (Ok cid)) -> Ok (Some text, [ id; cid ])
        | Ok (id, Some (Error e)) ->
            Printf.eprintf "%s inbox agent: %s\n" (Time_fmt.now ()) e;
            Ok (Some text, [ id ]))

  (* Adopt on an offer: the run's step, then the offer is settled. A full list refuses it and keeps
     the offer, so Adopt succeeds once the member removes a line; words held already drop it. *)
  let adopt_offer c ~me o =
    match
      adopt c ~me ~text:o.o_text ~author:o.o_author ~about:o.o_about
        ~credit:o.o_credit
    with
    | Ok _ ->
        drop_offer c o.o_item;
        Ok ()
    | Error e when e = held_already ->
        drop_offer c o.o_item;
        Error e
    | Error e -> Error e

  (* On every pass and every run: an offer the member picked from their digest or phone is acted
     on as Adopt on the Inbox is; one picked Not now, or past its week, is dropped with its
     credit. *)
  let settle_offers c =
    match self_identity c with
    | None -> ()
    | Some me ->
        Inbox.index c;
        List.iter
          (fun o ->
            match I.find (log c) ~now:c.now o.o_item with
            | None -> drop_offer c o.o_item
            | Some r -> (
                match
                  List.find_opt
                    (fun (p : I.pick) -> p.p_author = me)
                    (Inbox.picks c r)
                with
                | Some p when p.option = adopt_option ->
                    ignore (adopt_offer c ~me o)
                | Some _ -> drop_offer c o.o_item
                | None when Inbox.closed c r -> drop_offer c o.o_item
                | None -> ()))
          (offers c)

  (* POST /items/:id/picks on an offer: Adopt is refused before it is signed when the line could
     not be saved, and runs the adopt step once it is; every other pick is the Inbox's. *)
  let pick c id body ~otherwise =
    let held =
      match (self_identity c, Inbox.find c id) with
      | Some me, Some r ->
          Option.map
            (fun o -> (me, o))
            (List.find_opt
               (fun o -> Some o.o_item = r.hash || o.o_item = r.id)
               (offers c))
      | _ -> None
    in
    match held with
    | Some (me, o) when string_field "option_id" body = Some adopt_option -> (
        match can_save c o.o_text with
        | Error `Held ->
            drop_offer c o.o_item;
            invalid "adopted_already"
              "Your agent works this way already: Settings, Inbox agent lists \
               it."
        | Error `Full ->
            invalid "practices_full"
              (Printf.sprintf
                 "%d practices are adopted already. Remove one on Settings, \
                  Inbox agent, then Adopt."
                 max_practices)
        | Ok () ->
            let (res : response) = otherwise () in
            if res.status = 201 then ignore (adopt_offer c ~me o);
            res)
    | Some (_, o) ->
        let (res : response) = otherwise () in
        if res.status = 201 then drop_offer c o.o_item;
        res
    | None -> otherwise ()

  (* POST /inbox_agent/runs: what one reading run did. Each part is applied on its own: one that
     cannot be is named in [problems], and the rest stand. The read behavior runs the member's
     harness from its own configuration, so a run needs no agent saved here. *)
  let run c body =
    match self_identity c with
    | None -> invalid "not_joined" "This node has not joined a circle yet."
    | Some me ->
        let at = Time_fmt.now () in
        let problems = ref [] in
        let note = function
          | Ok _ -> ()
          | Error e -> problems := e :: !problems
        in
        Inbox.index c;
        settle_offers c;
        let reviewed =
          List.length
            (List.filter
               (fun j ->
                 let r = review c ~at j in
                 note r;
                 Result.is_ok r)
               (list "reviews" body))
        in
        (* A reply kept for the member reaches them in the Inbox: on the run's work notice about
           that note, or else on one written for it. One they asked for, they are reading already. *)
        let kept_replies = ref [] in
        let answers =
          List.filter_map
            (fun j ->
              let hash = trimmed "item" j in
              let asked = Store.Reviews.draft_request (log c) hash <> None in
              match answer c ~at j with
              | Ok o ->
                  if o = `Kept && (not asked) && reply_note c hash <> None then
                    kept_replies := hash :: !kept_replies;
                  Some
                    (`Assoc
                       [
                         ("item", str (trimmed "item" j));
                         ( "outcome",
                           str
                             (match o with `Sent -> "sent" | `Kept -> "kept") );
                       ])
              | Error e ->
                  note (Error e);
                  None)
            (list "answers" body)
        in
        let work_about h j =
          trimmed "subject" j = "work" && trimmed "about" j = h
        in
        let reply_notices =
          List.filter_map
            (fun h ->
              if List.exists (work_about h) (list "items" body) then None
              else
                Option.map
                  (fun (m : msg) ->
                    let name, _ = names c m.author in
                    `Assoc
                      [
                        ("subject", str "work");
                        ("title", str ("Reply to " ^ name ^ "'s note"));
                        ( "detail",
                          str
                            "Your agent drafted a reply for you to read, edit \
                             and send." );
                        ("about", str h);
                      ])
                  (reply_note c h))
            (List.rev !kept_replies)
        in
        let items =
          List.filter_map
            (fun j ->
              match item c ~me j with
              | Ok id ->
                  Option.map (Inbox.summary c) (I.find (log c) ~now:c.now id)
              | Error e ->
                  note (Error e);
                  None)
            (list "items" body @ reply_notices)
        in
        let practiced =
          List.filter_map
            (fun j ->
              match practice c ~me j with
              | Ok (a, ids) ->
                  Some (a, List.filter_map (I.find (log c) ~now:c.now) ids)
              | Error e ->
                  note (Error e);
                  None)
            (list "practices" body)
        in
        let adopted = List.filter_map fst practiced in
        let items =
          items
          @ List.concat_map
              (fun (_, rs) -> List.map (Inbox.summary c) rs)
              practiced
        in
        ok
          (`Assoc
             [
               ("reviewed", `Int reviewed);
               ("answers", `List answers);
               ("items", `List items);
               ("adopted", `List (List.map str adopted));
               ("problems", `List (List.rev_map str !problems));
             ])
end

(* DIG-378: Ask your agent. The question goes to the agent connected on Setup (Agent.saved), which
   runs on this machine as the agent check does, so nothing leaves it. It is handed the member's
   Inbox prompt and one block with the item's id, kind, title, the fixed line of what to do, its
   page and address and nothing else of the item: not its stored detail, not what it is about. The
   run is on a thread of its own with a deadline, the route answers at once, and the agent's
   answer, or why there is none, is kept with the item's status (Inbox.ask_json), where the Inbox
   item reads it. The reply is never signed, because the
   notice is addressed to the member alone and a signed reply is the circle's. What the member is
   told of a failure is in their words; the agent's own output goes to this process's stderr. *)
module Ask_agent = struct
  module A = Agent.A

  (* A run that has not answered by then did not answer. *)
  let deadline = Inbox.ask_deadline

  let has sub s =
    let n = String.length sub in
    let rec go i =
      i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
    in
    go 0

  (* The asks running in this process, so one item is never asked twice at once, and the process
     of each once it has started, so a stop can kill it. [killed] holds the asks a stop killed, so
     their worker says why instead of reading the exit code. *)
  let running : (string, unit) Hashtbl.t = Hashtbl.create 4
  let pids : (string, int) Hashtbl.t = Hashtbl.create 4
  let killed : (string, unit) Hashtbl.t = Hashtbl.create 4
  let running_lock = Mutex.create ()

  let claim id =
    Mutex.protect running_lock (fun () ->
        if Hashtbl.mem running id then false
        else (
          Hashtbl.replace running id ();
          true))

  let release id =
    Mutex.protect running_lock (fun () ->
        Hashtbl.remove running id;
        Hashtbl.remove pids id)

  (* How the agent is run: a test replaces it, since the real one runs the agent. [id] is the item,
     so a stop can find the run, and [on_spawn] is told the agent's pid once it runs. The agent
     leads a process group of its own and the deadline, like a stop, kills the group, so what it
     spawned (Codex, an Other agent's children) goes with it. An Error is the reason, in the
     member's words. *)
  let run :
      (A.t ->
      id:string ->
      on_spawn:(int -> unit) ->
      prompt:string ->
      (string, string) result)
      ref =
    ref (fun a ~id ~on_spawn ~prompt ->
        let result =
          Fun.protect
            ~finally:(fun () ->
              Mutex.protect running_lock (fun () -> Hashtbl.remove pids id))
            (fun () ->
              Proc.run ~timeout:deadline ~group:true ~on_spawn
                (A.answer_argv a ~prompt))
        in
        match result with
        | Error e ->
            Printf.eprintf "%s ask your agent: %s\n%!" (Time_fmt.now ()) e;
            Error
              (if has "still running after" e then "it ran past ten minutes"
               else "it could not be started")
        | Ok r when r.Proc.code <> 0 ->
            Printf.eprintf "%s ask your agent: exit %d: %s\n%!"
              (Time_fmt.now ()) r.Proc.code
              (if String.trim r.Proc.stderr <> "" then r.Proc.stderr
               else r.Proc.stdout);
            if r.Proc.code = 127 then Error "it could not be started"
            else Error (Printf.sprintf "it stopped with code %d" r.Proc.code)
        | Ok r -> Ok r.Proc.stdout)

  (* On stop: kill every ask's process group and fail its ask as the node stopping, so the next
     start finds nothing that may still be working. *)
  let kill_running (log : Log.t) =
    let ids =
      Mutex.protect running_lock (fun () ->
          let ids = Hashtbl.fold (fun id () acc -> id :: acc) running [] in
          List.iter
            (fun id ->
              Hashtbl.replace killed id ();
              match Hashtbl.find_opt pids id with
              | Some pid -> Proc.kill_group pid
              | None -> ())
            ids;
          Hashtbl.reset pids;
          ids)
    in
    List.iter
      (fun id ->
        try
          Log.set_config log (Inbox.k_ask id)
            (Inbox.ask_record ~status:"failed" ~at:(Time_fmt.now ())
               ~reply:(Inbox.ask_failure "the node stopped")
               ())
        with e ->
          Printf.eprintf "%s ask your agent: %s\n%!" (Time_fmt.now ())
            (Printexc.to_string e))
      ids

  (* How a recorded process group is killed: a test replaces it, so it never signals a real one. *)
  let kill_pgid : (int -> unit) ref = ref Proc.kill_pgid

  (* Whether an ask asked at [at] can still have its agent running: a run the node started is killed
     at its deadline, and one the node left behind (the agent leads its own session, so it outlives
     a crash) has had as long to finish. Past that the recorded number may lead an unrelated group
     by now, since pids wrap, so it is never signalled. An ask with no readable time is past it. *)
  let may_still_run ~now at =
    match Time_fmt.to_unix at with
    | Some t -> now -. t <= Inbox.ask_deadline +. Inbox.ask_margin
    | None -> false

  (* At startup no ask is running: one left asked by the process before is failed. *)
  let settle_leftovers ?now (log : Log.t) =
    let now = match now with Some t -> t | None -> Unix.gettimeofday () in
    (* A worker the process before left behind (it crashed, was killed or was stopped hard) is
       killed first, by the process group it recorded, so no run goes on beside a new ask, but only
       while it can still be that worker (may_still_run). *)
    List.iter
      (function
        | [| key; value |] -> (
            match Yojson.Safe.from_string (Log.text value) with
            | `Assoc f when List.assoc_opt "status" f = Some (`String "asked")
              ->
                let recorded =
                  match List.assoc_opt "at" f with
                  | Some (`String a) -> Some a
                  | _ -> None
                in
                (match (List.assoc_opt "pgid" f, recorded) with
                | Some (`Int g), Some a when may_still_run ~now a ->
                    !kill_pgid g
                | _ -> ());
                let at = Option.value recorded ~default:(Time_fmt.now ()) in
                Log.set_config log (Log.text key)
                  (Inbox.ask_record ~status:"failed" ~at
                     ~reply:(Inbox.ask_failure "the node restarted")
                     ())
            | _ -> ()
            | exception Yojson.Json_error _ -> ())
        | _ -> ())
      (Log.rows log "SELECT key, value FROM config WHERE key LIKE 'agent_ask:%'"
         [])

  (* This node's address as the page was asked for, when the node has no address of its own saved. *)
  let origin = ref "http://127.0.0.1:7420"

  (* The prompt: the member's Inbox prompt when they have one, else the release's default, which is
     read and never saved here, then the hand-off and nothing else. The agent cannot open a page
     (it runs with no tools, or read-only), so it is handed what the member sees inline: the item's
     id, kind and title, the one line of what to do there, which is fixed by the notice's subject,
     the page and the address to type for it. It is asked where and how to act, never to open
     anything. Nothing here is peer text: the title of a notice from this node and fixed strings. *)
  let prompt c (r : Inbox.I.row) page =
    let inbox =
      match
        match Log.get_config (log c) Inbox_agent.k_prompt with
        | Some p -> Some p
        | None -> Inbox_agent.default_text c
      with
      | Some p when String.trim p <> "" -> String.trim p ^ "\n\n"
      | _ -> ""
    in
    let todo =
      match Option.bind r.item.subject Item.notice_instruction with
      | Some line -> [ "What the member does there: " ^ line ]
      | None -> []
    in
    let address =
      match Inbox.address c r with Some a -> a | None -> !origin ^ page
    in
    inbox
    ^ String.concat "\n"
        ([
           "The member asks you about one notice in their Inbox.";
           "Item id: " ^ r.id;
           "Kind: " ^ r.item.kind;
           "Title: " ^ r.item.title;
         ]
        @ todo
        @ [
            "Page: " ^ page;
            "Address, on the member's machine: " ^ address;
            "Do not open anything: you cannot. Say where the member should act \
             and how, in a few short steps, or what you would do and what you \
             need from them.";
          ])

  (* The run itself, on its own connection to the log. *)
  let work ~dir ~id (agent : A.t) ~prompt =
    Fun.protect
      ~finally:(fun () -> release id)
      (fun () ->
        let status, reply =
          let failed why = ("failed", Inbox.ask_failure why) in
          (* A stop between the claim and the fork has marked the ask killed with no pid yet: the
             agent is not started, or, should it start in between, [spawned] kills it at once. *)
          let spawned pid =
            (* The check and the write are one step under the lock, so a stop cannot fail the ask
               between them and have the write bring back an asked row with a stale group. The
               agent leads its own group, so its pid is the group, kept with the ask. *)
            let stop_now =
              Mutex.protect running_lock (fun () ->
                  if Hashtbl.mem killed id then true
                  else (
                    Hashtbl.replace pids id pid;
                    (try
                       let log = Log.reopen (Node.log_path dir) in
                       Fun.protect
                         ~finally:(fun () -> Log.close log)
                         (fun () ->
                           Log.set_config log (Inbox.k_ask id)
                             (Inbox.ask_record ~status:"asked"
                                ~at:(Time_fmt.now ()) ~pgid:pid ()))
                     with e ->
                       Printf.eprintf "%s ask your agent: %s\n%!"
                         (Time_fmt.now ()) (Printexc.to_string e));
                    false))
            in
            if stop_now then Proc.kill_group pid
          in
          let result =
            if Mutex.protect running_lock (fun () -> Hashtbl.mem killed id) then
              Error "the node stopped"
            else
              try !run agent ~id ~on_spawn:spawned ~prompt
              with e ->
                Printf.eprintf "%s ask your agent: %s\n%!" (Time_fmt.now ())
                  (Printexc.to_string e);
                Error "it could not be run"
          in
          let stopped =
            Mutex.protect running_lock (fun () ->
                let k = Hashtbl.mem killed id in
                Hashtbl.remove killed id;
                k)
          in
          match result with
          | _ when stopped -> failed "the node stopped"
          | Ok text when String.trim text <> "" -> ("answered", String.trim text)
          | Ok _ -> failed "it answered nothing"
          | Error why -> failed why
        in
        try
          let log = Log.reopen (Node.log_path dir) in
          Fun.protect
            ~finally:(fun () -> Log.close log)
            (fun () ->
              Log.set_config log (Inbox.k_ask id)
                (Inbox.ask_record ~status ~at:(Time_fmt.now ()) ~reply ()))
        with e ->
          Printf.eprintf "%s ask your agent: %s\n%!" (Time_fmt.now ())
            (Printexc.to_string e))

  let not_askable () =
    errors 422 "not_askable"
      "Only an open notice from your node with a page can be asked about."

  (* POST /items/:id/ask-agent. An item that cannot be asked about is told so before an agent that
     is not connected is, so a notice with no page never reads "Connect an agent". An agent that
     cannot be started is not an error of the route: the ask is recorded failed, in the member's
     words, and answered 202 like any ask, so the item carries it. *)
  let ask c id =
    match Inbox.find c id with
    | None -> not_found ()
    | Some r -> (
        match Inbox.path c r with
        | Some page when Inbox.askable c r -> (
            match Agent.saved c.node with
            | None ->
                errors 422 "no_agent"
                  "Connect an agent on Setup first. Ask your agent goes to it."
            | Some agent ->
                if not (claim r.id) then
                  errors 422 "asking" "Your agent is already working on this."
                else
                  let record =
                    Inbox.ask_record ~status:"asked" ~at:(Time_fmt.now ()) ()
                  in
                  let record =
                    try
                      Log.set_config (log c) (Inbox.k_ask r.id) record;
                      let prompt = prompt c r page in
                      ignore
                        (Thread.create
                           (fun () ->
                             work ~dir:c.node.dir ~id:r.id agent ~prompt)
                           ());
                      record
                    with e ->
                      release r.id;
                      Printf.eprintf "%s ask your agent: %s\n%!"
                        (Time_fmt.now ()) (Printexc.to_string e);
                      let failed =
                        Inbox.ask_record ~status:"failed" ~at:(Time_fmt.now ())
                          ~reply:(Inbox.ask_failure "it could not be started")
                          ()
                      in
                      (try Log.set_config (log c) (Inbox.k_ask r.id) failed
                       with _ -> ());
                      failed
                  in
                  ok ~status:202 (Yojson.Safe.from_string record))
        | _ -> not_askable ())
end

(* The question closer (DES-51007, How a question closes): before each note the asker's agent reads
   each of its open questions that has an answer beside its person's record, and closes the ones
   whose block is gone, naming the answer that unblocked it. It runs in the note's behavior
   (behaviors/src/closer.ts), through `digestif question list` and `digestif question close`, so
   its close is the agent's and never the person's: the asker's own close or reopen on the item's
   page stands over it, and the agent's is kept beside it. *)
module Questions = struct
  module I = Store.Items

  let person_closed c r =
    List.exists (fun (x : I.close) -> x.c_voice = "person") (Inbox.closes c r)

  (* An open question this member asked, answered by someone else, that its author has not closed
     or reopened themselves: the agent never closes over the person. *)
  let to_close c (r : I.row) =
    r.item.kind = "question" && Inbox.own c r && r.hash <> None
    && (not (Inbox.closed c r))
    && (not (person_closed c r))
    && List.exists
         (fun (a : I.answer) -> a.a_author <> r.author)
         (Inbox.answers c r)

  let json c (r : I.row) : Yojson.Safe.t =
    `Assoc
      [
        ("id", str r.id);
        ("title", str r.item.title);
        ("detail", str r.item.detail);
        ("asked_at", str (Option.value r.sent_at ~default:r.created_at));
        ( "answers",
          `List
            (List.filter_map
               (fun (a : I.answer) ->
                 if a.a_author = r.author then None
                 else
                   Some
                     (`Assoc
                        [
                          ("hash", str a.a_hash);
                          ("author", member_ref c a.a_author);
                          ("text", str a.text);
                          ("created_at", str a.a_at);
                        ]))
               (Inbox.answers c r)) );
      ]

  (* Every question the closer reads, oldest first. *)
  let open_answered c =
    Inbox.index c;
    I.page (log c) ~now:c.now ~kind:"question" ~limit:max_int ()
    |> List.filter (to_close c)
    |> List.sort (fun (a : I.row) b -> compare a.created_at b.created_at)
    |> List.map (json c)

  (* The agent closes [id], naming [answer]: one of the questions the closer reads, and one of its
     answers from someone else. *)
  let close c id ~answer =
    match Inbox.find c id with
    | None -> Error "no such item"
    | Some r when not (to_close c r) ->
        Error "not an open question of this member's with an answer"
    | Some r -> (
        if
          not
            (List.exists
               (fun (a : I.answer) ->
                 a.a_hash = answer && a.a_author <> r.author)
               (Inbox.answers c r))
        then Error "that is not one of its answers"
        else
          let res =
            Inbox.close ~voice:"agent" c r
              (Some (`Assoc [ ("closed", `Bool true); ("answer", str answer) ]))
          in
          match res.status with
          | 200 -> Ok ()
          | _ -> (
              match res.body with
              | Some j -> Error (Yojson.Safe.to_string j)
              | None -> Error "the close was not signed"))
end

let route c ~meth ~path ~query ~body =
  match (meth, path) with
  | "GET", [ "status" ] ->
      extend (status c)
        (Stages.status_fields c @ Pause.status_fields c
        @
        (Prompts.sync c;
         Inbox.status_fields c))
  | "GET", [ "feed" ] ->
      extend_each
        (fun j -> Stages.feed_fields c (string_of "hash" j))
        (feed ~extra:Notes.in_feed c query)
  | "GET", [ "messages"; h ] -> Notes.message c h
  | "POST", [ "messages"; h; "draft-reply" ] -> draft_reply c h
  | "POST", [ "messages" ] -> Stages.compose c (fun () -> post c body)
  | "GET", [ "members" ] -> member_page c query
  | "GET", [ "invitees" ] -> Stages.invitees c
  | "GET", [ "paused" ] -> Pause.paused c
  | "POST", [ "paused" ] -> Pause.pause c
  | "DELETE", [ "paused" ] -> Pause.unpause c
  | "GET", [ "members"; id ] ->
      with_found (find_identity c id) (fun k -> ok (member_json c k))
  | "PUT", [ "members"; id; "mute" ] ->
      with_found (find_identity c id) (fun k ->
          if self_identity c = Some k.key then
            invalid "self" "You cannot mute yourself."
          else
            match field "muted" body with
            | Some (`Bool m) ->
                Store.set_muted (log c) k.key m;
                ok (member_json c k)
            | _ -> invalid ~field:"muted" "muted" "muted is true or false.")
  | "POST", [ "phones" ] -> add_phone c body
  | "POST", [ "phones"; key; "revocations" ] -> Phones.revoke c key body
  | "GET", [ "brief" ] -> ok (brief_json c)
  | "POST", [ "brief"; "draft" ] -> draft_brief c
  | "PUT", [ "brief" ] -> (
      match
        String.trim (Option.value (string_field "text" body) ~default:"")
      with
      | "" -> invalid ~field:"text" "empty" "Write a few lines about yourself."
      | text ->
          Store.set_brief (log c) text;
          ok (brief_json c))
  | "GET", [ "sources" ] -> source_page c query
  | "PUT", [ "sources" ] -> (
      match selection c body with
      | Error e -> e
      | Ok ids ->
          Store.select_sources (log c) ids;
          ok (sources_json c))
  | "POST", [ "sources" ] -> add_source c body
  | "DELETE", [ "sources"; id ] -> remove_source c id
  | "GET", [ "rules" ] -> ok (rules_json c)
  | "PUT", [ "rules" ] ->
      Store.set_rules (log c)
        (Option.value (string_field "text" body) ~default:"");
      ok (rules_json c)
  | "GET", [ "rules"; "quiet_hours" ] ->
      with_found (Quiet_hours.get (log c)) (fun q -> ok (quiet_hours_json c q))
  | "PUT", [ "rules"; "quiet_hours" ] -> set_quiet_hours c body
  | "DELETE", [ "rules"; "quiet_hours" ] ->
      Quiet_hours.clear (log c);
      no_content
  | "GET", [ "rules"; "deny" ] -> Settings.deny_list c query
  | "POST", [ "rules"; "deny" ] -> add_deny c body
  | "GET", [ "rules"; "deny"; id ] ->
      with_found (Store.deny_entry (log c) id) (fun e -> ok (deny_json e))
  | "DELETE", [ "rules"; "deny"; id ] ->
      with_found
        (Store.deny_entry (log c) id)
        (fun e ->
          Store.remove_deny (log c) e.d_id;
          share_deny c;
          no_content)
  | "GET", [ "note_prompt" ] -> Prompts.note_prompt c
  | "GET", [ "suggestions" ] -> Prompts.list c query
  | "POST", [ "suggestions" ] -> Prompts.create c body
  | "GET", [ "suggestions"; h ] -> Prompts.get c h
  | "DELETE", [ "suggestions"; h ] -> Prompts.withdraw c h
  | "PUT", [ "suggestions"; h; "pull_request" ] ->
      Prompts.set_pull_request c h body
  | "GET", [ "notes" ] -> Notes.list c query
  | "POST", [ "notes"; "suggestion"; "dismiss" ] -> Notes.dismiss_suggestion c
  | "POST", [ "notes"; "runs" ] -> Notes.run_now c
  | "GET", [ "notes"; id; "versions" ] -> Notes.versions c id
  | "POST", [ "notes"; id; "dismiss" ] -> Notes.dismiss c id
  | "GET", [ "notes"; id ] -> Notes.note c id query
  | "GET", [ "notes"; id; "log" ] -> Checks.log c id
  | "POST", [ "notes"; id; "versions" ] -> Notes.add_version c id body
  | "POST", [ "notes"; id; "approve" ] -> Notes.approve c id body
  | "GET", [ "settings"; "approval" ] -> Notes.approval c
  | "PUT", [ "settings"; "approval" ] -> Notes.set_approval c body
  | "GET", [ "learnings" ] -> Notes.learnings c
  | "PUT", [ "learnings" ] -> Notes.set_learnings c body
  | "GET", [ "settings"; "note_time" ] -> Settings.note_time c
  | "PUT", [ "settings"; "note_time" ] -> Settings.set_note_time c body
  | "GET", [ "settings"; "digest" ] -> Settings.digest c
  | "PUT", [ "settings"; "digest" ] -> Settings.set_digest c body
  | "GET", [ "settings"; "names" ] -> Names.get c
  | "PUT", [ "settings"; "names" ] -> Names.set c body
  | "GET", [ "settings"; "agent" ] -> Agent.get c
  | "PUT", [ "settings"; "agent" ] -> Agent.set c body
  | "GET", [ "settings"; "agent"; "check" ] -> Agent.get_check c
  | "GET", [ "problems" ] -> Problems.list c query
  | "GET", [ "organizations" ] -> Repositories.organizations c query
  | "PUT", [ "organizations"; id ] -> Repositories.set_organization c id body
  | "GET", [ "repositories" ] -> Repositories.repositories c query
  | "GET", [ "repositories"; "counts" ] -> Repositories.counts c query
  | "PUT", [ "repositories"; id ] -> Repositories.set_repository c id body
  | "GET", [ "commit_authors" ] -> Repositories.authors c
  | "POST", [ "commit_authors" ] -> Repositories.add_author c body
  | "PUT", [ "commit_authors"; id ] -> Repositories.label_author c id body
  | "DELETE", [ "commit_authors"; id ] -> Repositories.remove_author c id
  | "GET", [ "items" ] ->
      Prompts.sync c;
      Inbox.list c query
  | "POST", [ "items"; id; "ask-agent" ] -> Ask_agent.ask c id
  | "POST", [ "items"; id; "picks" ] ->
      Inbox_agent.pick c id body ~otherwise:(fun () ->
          Prompts.route_items c ~meth:"POST" ~rest:[ id; "picks" ] ~body)
  | meth, "items" :: rest -> Prompts.route_items c ~meth ~rest ~body
  | "GET", [ "settings"; "inbox_agent" ] -> Inbox_agent.get c
  | "PUT", [ "settings"; "inbox_agent" ] -> Inbox_agent.put c body
  | "DELETE", [ "settings"; "inbox_agent" ] -> Inbox_agent.reset c
  | "DELETE", [ "settings"; "inbox_agent"; "practices"; id ] ->
      Inbox_agent.remove_practice c id
  | "POST", [ "inbox_agent"; "runs" ] -> Inbox_agent.run c body
  | _ -> not_found ()

(* One request: the fold is computed once, from the log as it stands. *)
let handle ?(on_write = fun () -> ()) node ~meth ~path ~query ~body =
  let c =
    {
      node;
      fold = Node.fold node;
      now = Unix.gettimeofday ();
      on_write;
      upkeep_waits = meth <> "GET";
    }
  in
  route c ~meth ~path ~query ~body

(* The address this node is served at, from the Host the page was fetched with. *)
let note_host h =
  let port =
    match String.rindex_opt h ':' with
    | Some i ->
        let p = String.sub h (i + 1) (String.length h - i - 1) in
        if
          p <> ""
          && String.for_all (function '0' .. '9' -> true | _ -> false) p
        then Some p
        else None
    | None -> None
  in
  Ask_agent.origin := "http://127.0.0.1:" ^ Option.value port ~default:"7420"

let ctx_of ?(on_write = fun () -> ()) node =
  {
    node;
    fold = Node.fold node;
    now = Unix.gettimeofday ();
    on_write;
    upkeep_waits = true;
  }

(* The run loop's upkeep after each sync: the Inbox index and the suggestions' closes brought up to
   the log, so a page finds them current instead of doing that work while the member waits. A failure
   is the pass's to print; the next pass, or a page, tries again. ISS-78820 *)
let keep_up node =
  match Prompts.sync (ctx_of node) with
  | () -> Ok ()
  | exception Failure e -> Error e

let read_runs = function
  | None -> Ok []
  | Some j -> Note_checks.read_runs ~at:(Time_fmt.now ()) j

(* `digestif note --ends`: where the note ends, per record key (Store.Record), as the behavior
   read it: { "<key>": { "at": "<ISO 8601 UTC>", "sha": "<commit>" } }, sha optional. *)
let parse_ends text : ((string * Store.Record.point) list, string) result =
  let bad =
    Error
      "--ends must be { \"<key>\": { \"at\": \"<ISO 8601 UTC>\", \"sha\"?: \
       \"<commit>\" } }"
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> bad
  | `Assoc l -> (
      try
        Ok
          (List.map
             (fun (key, v) ->
               match v with
               | `Assoc f -> (
                   let at =
                     match List.assoc_opt "at" f with
                     | Some (`String s) -> Time_fmt.to_unix s
                     | _ -> None
                   in
                   let sha =
                     match List.assoc_opt "sha" f with
                     | Some (`String s) when s <> "" -> Some s
                     | None | Some `Null -> None
                     | _ -> raise Exit
                   in
                   match at with
                   | Some at ->
                       ( key,
                         {
                           Store.Record.at_ms =
                             int_of_float (Float.round (at *. 1000.));
                           sha;
                         } )
                   | None -> raise Exit)
               | _ -> raise Exit)
             l)
      with Exit -> bad)
  | _ -> bad

(* `digestif note --pair`: the second version of a note written for the suggestion its member
   judges (ISS-51009): { "suggestion": "sha256:...", "prompt": "sha256:...", "text": "...",
   "checks": [<runs>] }, the version checked exactly as the first. *)
let parse_pair text =
  let bad =
    Error "--pair must be { \"suggestion\", \"prompt\", \"text\", \"checks\" }"
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> bad
  | j -> (
      match
        ( Content.str_field "suggestion" j,
          Content.str_field "prompt" j,
          Content.str_field "text" j )
      with
      | Some suggestion, Some prompt, Some t when String.trim t <> "" ->
          let* runs =
            match Content.get "checks" j with
            | None | Some `Null -> Ok []
            | Some r ->
                Note_checks.read_runs ~at:(Time_fmt.now ())
                  (Yojson.Safe.to_string r)
          in
          Ok (suggestion, prompt, String.trim t, runs)
      | _ -> bad)

(* `digestif note`: the agent hands the node a checked note, and [checks], what each check run
   removed, by part, by what it broke and by the passages it removed (Note_checks.read_runs). [approve] is the agent approving
   it, which it does when auto approval is saved. *)
let submit_note_text ?checks ?could_not_finish ?(approve = false) ?ends ?prompt
    ?pair node text =
  if text = "" then Error "the note is empty"
  else
    let* runs = read_runs checks in
    let* pair =
      match pair with
      | None -> Ok None
      | Some j -> Result.map Option.some (parse_pair j)
    in
    Notes.submit ~runs ?could_not_finish ?ends ?prompt ?pair ~approve
      (ctx_of node) text

(* `digestif note checked`: the check behavior hands back an edit's checked text, or which check
   could not finish. *)
let version_checked_text ?checks ?approve node ~version result =
  let* runs = read_runs checks in
  Notes.checked ?approve ~runs (ctx_of node) version result

(* `digestif learnings set VERSION`: the agent's update of Learnings from an edit's diff. *)
let learnings_from_edit node ~version text =
  Notes.learned (ctx_of node) version text

(* The send job, once per pass of `digestif run`. *)
let send_notes node =
  let c = ctx_of node in
  Notes.send c;
  (* An adopted suggestion this member wrote becomes the circle's live prompt (Prompts). *)
  Prompts.adopt_due c;
  (* An offered practice picked from the digest or a phone is adopted, or dropped (ISS-85004). *)
  Inbox_agent.settle_offers c

(* `digestif run`: the clock, after the pass's work run was started. A note that has waited 30
   days pauses an Active member first, which sends Paused and stops the clock. *)
let clock node ~working =
  let c = ctx_of node in
  match Pause.due c with Some r -> Some r | None -> Stages.clock c ~working

(* `digestif run`: after the pass's sync settled the asks, an Unpause answered to the Paused ask
   unpauses. Answers whether it did. *)
let settled_unpause node = Pause.answered (ctx_of node)

(* `digestif post`: a behavior hands the node a body it built. A summary goes through the deny
   layer first, so no behavior carries its own copy of the rules. A refusal is kept as a refused
   outbound row, so the person sees it and the rule that tripped. Every other kind signs as it was
   given; a question to the circle is an item, which the Inbox writes (POST /items). *)
type post_error = Refused of string | Failed of string

let post_body node ?(key_name = "device") ~kind (body : Yojson.Safe.t) =
  let c =
    {
      node;
      fold = Node.fold node;
      now = Unix.gettimeofday ();
      on_write = (fun () -> ());
      upkeep_waits = true;
    }
  in
  let stage = Store.Stages.stage (log c) in
  (* The agent answers nobody in the member's name while Onboarding or Paused (docs/design.md,
     Stages and the status note), and a summary carries the stage it was written in. *)
  let body =
    match body with
    | `Assoc f when kind = "summary" ->
        `Assoc (List.remove_assoc "stage" f @ [ ("stage", `String stage) ])
    | b -> b
  in
  let sign () =
    match Node.write node ~key_name ~kind body with
    | Ok (hash, _) -> Ok hash
    | Error e -> Error (Failed e)
  in
  if not (Envelope.known kind) then
    Error (Failed (Printf.sprintf "%s is not a kind the protocol names" kind))
  else if not (List.mem kind Content.feed_kinds) then sign ()
  else if stage <> "active" then
    Error
      (Failed
         (Printf.sprintf "this member is %s: nothing is posted until Active"
            stage))
  else
    let read = Content.read (Some body) in
    let verdict = deny_check c (Option.value read.text ~default:"") in
    match verdict with
    | None -> sign ()
    | Some rule ->
        Store.add_outbound (log c)
          {
            o_id = Store.local_hash ();
            o_kind = kind;
            voice = read.voice;
            reply_to = read.reply_to;
            o_text = None;
            status = "refused";
            refused_rule = Some rule;
            o_created_at = Time_fmt.now ();
            posted_hash = None;
            held_reason = None;
          };
        Error (Refused rule)
