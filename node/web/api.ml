(* The node's local API, spec/digestif-node.json: every operation the web UI calls, answered from
   the log, the fold and the local store. Nothing here is wire format. A write that signs an envelope
   puts it in the log and asks for a sync, which pushes it to every relay. *)

open Digestif_core

type ctx = {
  node : Node.t;
  fold : Fold.t;
  now : float;
  on_write : unit -> unit;  (** a new envelope of ours wants a sync *)
}

let log c = c.node.log

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
let member_ref c identity : Yojson.Safe.t =
  let name, agent =
    match card c identity with
    | Some k -> (k.card_name, k.agent_name)
    | None -> (
        match invited_name c identity with
        | Some n -> (n, "Agent")
        | None -> ("Member " ^ short identity, "Agent"))
  in
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
  recipient : string option;
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
  let read = Content.read ~enc:(encryption c) ~kind:e.kind r.signed.body in
  let retracted = r.retracted_by <> None in
  {
    hash = r.hash;
    kind = e.kind;
    voice = read.voice;
    author = Option.value (identity_of c e.author) ~default:e.author;
    recipient = read.recipient;
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
    recipient = o.recipient;
    created_at = o.o_created_at;
    status = o.status;
    text = (if o.status = "retracted" then None else o.o_text);
    reply_to = o.reply_to;
    refused_rule = o.refused_rule;
    held_reason = o.held_reason;
  }

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

(* At most 140 characters, never cutting a UTF-8 sequence in half. *)
let clip s =
  let max = 140 in
  let rec chars i n =
    if i >= String.length s || n = max then i
    else
      let d = String.get_utf_8_uchar s i in
      chars (i + Uchar.utf_decode_length d) (n + 1)
  in
  String.sub s 0 (chars 0 0)

let preview m =
  match m.text with
  | Some t -> clip (first_line t)
  | None -> (
      match m.status with
      | "refused" -> "Refused before signing"
      | "retracted" -> "Retracted"
      | _ -> "Sealed")

let item_json c m : Yojson.Safe.t =
  `Assoc
    ([
       ("hash", str m.hash);
       ("kind", str m.kind);
       ("voice", str m.voice);
       ("author", member_ref c m.author);
     ]
    @ (match m.recipient with
      | Some r -> [ ("recipient", member_ref c r) ]
      | None -> [])
    @ [
        ("created_at", str m.created_at);
        ("status", str m.status);
        ("preview", str (preview m));
      ])

let newest_first l = List.sort (fun a b -> compare b.created_at a.created_at) l

(* Everything the feed holds: content the fold believes, plus our outbound rows still unsigned. *)
let feed_msgs c =
  let logged =
    View.feed (log c) c.fold
    |> List.filter (fun (r : Log.row) ->
        List.mem r.signed.envelope.kind Content.feed_kinds)
    |> List.map (of_row c)
  in
  let held =
    Store.outbox (log c)
    |> List.filter (fun (o : Store.outbound) -> o.status = "refused")
    |> List.map (of_outbound c)
  in
  newest_first (logged @ held)

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

let message_json c m : Yojson.Safe.t =
  let replies =
    feed_msgs c
    |> List.filter (fun r -> r.reply_to = Some m.hash)
    |> List.rev
    |> List.map (item_json c)
  in
  `Assoc
    ([
       ("hash", str m.hash);
       ("kind", str m.kind);
       ("voice", str m.voice);
       ("author", member_ref c m.author);
     ]
    @ (match m.recipient with
      | Some r -> [ ("recipient", member_ref c r) ]
      | None -> [])
    @ [ ("created_at", str m.created_at); ("status", str m.status) ]
    @ opt "text" m.text @ opt "reply_to" m.reply_to
    @ opt "refused_rule" m.refused_rule
    @ opt "held_reason" m.held_reason
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

(* asks: this member's own, sealed to their card key, answered by a decision *)

type ask = {
  a_hash : string;
  a_kind : string;
  a : Digestif_mail.Ask.t;
  from : string option;
  a_created_at : string;
  withdrawn : bool;
  decision : (string * string) option;  (** option id, decided at *)
}

let ask_kinds = [ "intro"; "meeting"; "share"; "behavior"; "join" ]
let ask_statuses = [ "open"; "answered"; "lapsed"; "withdrawn" ]

let own_rows c kind =
  match self_identity c with
  | None -> []
  | Some me ->
      Log.of_kind (log c) kind
      |> List.filter (fun (r : Log.row) ->
          identity_of c r.signed.envelope.author = Some me)

let asks c =
  match encryption c with
  | None -> []
  | Some enc ->
      let open_ (r : Log.row) =
        match r.signed.body with
        | None -> None
        | Some b -> (
            match Content.get "sealed" b with
            | None -> None
            | Some sealed -> (
                match Digestif_mail.Seal.open_ ~priv:enc.secret sealed with
                | Error _ -> None
                | Ok p -> (
                    match Digestif_mail.Ask.of_plaintext p with
                    | Error _ -> None
                    | Ok a -> Some (a, p))))
      in
      let decisions =
        own_rows c "decision"
        |> List.filter_map (fun (r : Log.row) ->
            match r.signed.body with
            | None -> None
            | Some b -> (
                match Digestif_mail.Ask.decision_of_body ~priv:enc.secret b with
                | Ok (ask, option) ->
                    Some (ask, (option, r.signed.envelope.created_at))
                | Error _ -> None))
        |> List.sort (fun (_, (_, x)) (_, (_, y)) -> compare x y)
      in
      Log.of_kind (log c) "ask"
      |> List.filter (fun (r : Log.row) ->
          identity_of c r.signed.envelope.author = self_identity c)
      |> List.filter_map (fun (r : Log.row) ->
          match open_ r with
          | None -> None
          | Some (a, p) ->
              let kind =
                match Content.str_field "kind" p with
                | Some k when List.mem k ask_kinds -> k
                | _ -> "share"
              in
              let decision =
                List.find_map
                  (fun (h, (o, at)) ->
                    if h = r.hash && unix at < unix a.lapses_at then Some (o, at)
                    else None)
                  decisions
              in
              Some
                {
                  a_hash = r.hash;
                  a_kind = kind;
                  a;
                  from = Content.str_field "from" p;
                  a_created_at = r.signed.envelope.created_at;
                  withdrawn = r.retracted_by <> None;
                  decision;
                })

let ask_status c x =
  if x.withdrawn then "withdrawn"
  else if x.decision <> None then "answered"
  else if c.now >= unix x.a.lapses_at then "lapsed"
  else "open"

let ask_summary_fields c x =
  [
    ("id", str x.a_hash);
    ("kind", str x.a_kind);
    ("title", str x.a.title);
    ("status", str (ask_status c x));
  ]
  @ (match x.from with Some f -> [ ("from", member_ref c f) ] | None -> [])
  @ [ ("deadline_at", str x.a.lapses_at); ("created_at", str x.a_created_at) ]

let ask_json c x : Yojson.Safe.t =
  let default =
    List.find_opt
      (fun (o : Digestif_mail.Ask.choice) -> o.id = x.a.on_no_answer)
      x.a.options
  in
  `Assoc
    (ask_summary_fields c x
    @ [
        ("detail", str x.a.detail);
        ( "options",
          `List
            (List.map
               (fun (o : Digestif_mail.Ask.choice) ->
                 `Assoc
                   [
                     ("id", str o.id);
                     ("label", str o.label);
                     ("recommended", `Bool o.recommended);
                   ])
               x.a.options) );
        ( "on_no_answer",
          str
            (match default with
            | Some o -> "If you do not answer by the deadline: " ^ o.label ^ "."
            | None -> "Lapses at the deadline.") );
      ]
    @ opt "message" x.a.about
    @
    match x.decision with
    | Some (o, at) ->
        [ ("answer", `Assoc [ ("option_id", str o); ("answered_at", str at) ]) ]
    | None -> [])

let open_asks c =
  List.length (List.filter (fun x -> ask_status c x = "open") (asks c))

(* members *)

let three_days = 3.0 *. 86400.0

let identities c =
  Hashtbl.fold
    (fun _ (k : Fold.key_state) acc ->
      if k.role = Bodies.Identity then k :: acc else acc)
    c.fold.keys []

let last_posted c =
  let t = Hashtbl.create 16 in
  List.iter
    (fun (r : Log.row) ->
      let e = r.signed.envelope in
      if List.mem e.kind Content.feed_kinds then
        match identity_of c e.author with
        | Some id -> (
            match Hashtbl.find_opt t id with
            | Some at when at >= e.created_at -> ()
            | _ -> Hashtbl.replace t id e.created_at)
        | None -> ())
    (Log.all (log c));
  t

let envelope_time c hash =
  Option.map
    (fun (r : Log.row) -> r.signed.envelope.created_at)
    (Log.find (log c) hash)

(* The nightly tick runs once a day; a node with no tick in a day and a half missed one. *)
let tick_window = 1.5 *. 86400.0

(* Why this node, silent for three days, has not posted: nothing to read, the nightly tick has
   stopped running, an open problem says the agent is signed out or signing refused the note, or a
   relay is rejecting what it pushes. *)
let silence_reason c =
  let l = log c in
  let ticks =
    List.filter
      (fun (t : Store.tick) -> c.now -. unix t.t_at < three_days)
      (Store.ticks l ~limit:64)
  in
  let open_kind kind =
    List.exists
      (fun (p : Store.Problems.problem) -> p.kind = kind)
      (Store.Problems.open_ l)
  in
  if not (List.exists (fun (s : Store.source) -> s.selected) (Store.sources l))
  then Some "no_sources"
  else if
    not
      (List.exists
         (fun (t : Store.tick) -> c.now -. unix t.t_at < tick_window)
         ticks)
  then Some "asleep"
  else if open_kind "signed_out" then Some "harness_signed_out"
  else if open_kind "signing_refused" then Some "deny_refusing"
  else if
    List.exists (fun (r : Log.relay_row) -> r.last_error <> None) (Log.relays l)
  then Some "relay_rejecting"
  else None

let summary_fields c posted (k : Fold.key_state) =
  let me = self_identity c = Some k.key in
  let last = Hashtbl.find_opt posted k.key in
  let status =
    if k.revoked_by <> None then "revoked"
    else
      match last with
      | Some at when c.now -. unix at < three_days -> "active"
      | _ -> "silent"
  in
  let silent_self = me && status = "silent" in
  let reason = if silent_self then silence_reason c else None in
  (match member_ref c k.key with `Assoc f -> f | _ -> [])
  @ [ ("status", str status) ]
  @ opt "last_posted_at" last
  @ opt "silence_reason" reason
  @ [ ("muted", `Bool (Store.muted (log c) k.key)); ("is_self", `Bool me) ]

let members_json c =
  let posted = last_posted c in
  identities c
  |> List.map (fun k -> (Hashtbl.find_opt posted k.Fold.key, k))
  |> List.sort (fun (a, ka) (b, kb) ->
      match (a, b) with
      | Some x, Some y when x <> y -> compare y x
      | Some _, None -> -1
      | None, Some _ -> 1
      | _ -> compare ka.Fold.key kb.Fold.key)
  |> List.map (fun (_, k) -> `Assoc (summary_fields c posted k))

let member_json c (k : Fold.key_state) : Yojson.Safe.t =
  let posted = last_posted c in
  let devices =
    Hashtbl.fold
      (fun _ (d : Fold.key_state) acc ->
        if d.identity = k.key && d.role <> Bodies.Identity then d :: acc
        else acc)
      c.fold.keys []
    |> List.sort (fun (a : Fold.key_state) b -> compare a.key b.key)
    |> List.map (fun (d : Fold.key_state) ->
        `Assoc
          ([
             ("key", str d.key);
             ("role", str (Bodies.role_to_string d.role));
             ( "admitted_at",
               str (Option.value (envelope_time c d.admitted_by) ~default:"") );
           ]
          @ opt "revoked_at" (Option.bind d.revoked_by (envelope_time c))))
  in
  let recent =
    feed_msgs c
    |> List.filter (fun m -> m.author = k.key)
    |> List.filteri (fun i _ -> i < 20)
    |> List.map (item_json c)
  in
  `Assoc
    (summary_fields c posted k
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

(* dinners *)

type dinner = {
  d_hash : string;
  body : Bodies.dinner;
  d_guests : Yojson.Safe.t list;
}

let dinners c =
  dinner_bodies c
  |> List.map (fun (h, (d : Bodies.dinner)) ->
      let guest (g : Bodies.guest) =
        let joined = joined_by c g.invite_key in
        let status =
          match joined with
          | Some id -> (
              match Fold.find c.fold id with
              | Some { revoked_by = Some _; _ } -> "revoked"
              | _ -> "joined")
          | None -> if c.now >= unix g.expires_at then "expired" else "invited"
        in
        `Assoc
          ([
             ("name", str g.name);
             ("status", str status);
             ("expires_at", str g.expires_at);
           ]
          @ opt "identity" joined)
      in
      { d_hash = h; body = d; d_guests = List.map guest d.guests })
  |> List.sort (fun a b ->
      match compare b.body.date a.body.date with
      | 0 -> compare a.d_hash b.d_hash
      | n -> n)

let joined_count d =
  List.length
    (List.filter
       (fun g -> Content.str_field "status" g = Some "joined")
       d.d_guests)

let dinner_head c d =
  [
    ("hash", str d.d_hash);
    ("date", str d.body.date);
    ("label", str d.body.label);
    ("host", member_ref c d.body.host);
  ]

(* sources *)

(* Rediscover what this machine offers on every read of the list, keeping the member's choice. *)
let refresh_sources c =
  if Log.get_config (log c) Sources.k_fixed = None then
    Store.set_offered (log c) (Sources.discover ())

let sources_json c =
  `List
    (List.map
       (fun (s : Store.source) ->
         `Assoc
           [
             ("id", str s.id);
             ("kind", str s.kind);
             ("label", str s.label);
             ("paths", `List (List.map str s.paths));
             ("yields", `List (List.map str s.yields));
             ("selected", `Bool s.selected);
           ])
       (Store.sources (log c)))

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
  match
    Sources.draft_brief (log c) ~name ~agent_name
      (Sources.extract ~now:c.now chosen)
  with
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

let add_log c ~note_id entries =
  List.iter
    (fun e -> Store.Checks.add (log c) ~note_id (Yojson.Safe.to_string e))
    entries

(* One way a failure is reported (docs/design.md): every job's failure is a problem in one record,
   which the header of Notes reads while it is open, a note's Log reads for a problem in writing,
   checking or sending that note, and the status note reads as Could not run today. *)
module Problems = struct
  module P = Store.Problems

  let json (p : P.problem) : Yojson.Safe.t =
    `Assoc
      ([ ("id", str p.p_id); ("job", str p.job); ("kind", str p.kind) ]
      @ opt "source" p.p_source
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
        match p.p_source with
        | Some s -> s ^ " could not be read."
        | None -> "A source could not be read.")
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

let silence_reason_line = function
  | "no_sources" ->
      "No source is chosen, so the nightly run has nothing to read."
  | "asleep" -> "The nightly run has not run in a day and a half."
  | "harness_signed_out" ->
      "The last run could not use your agent harness; it may be signed out."
  | "deny_refusing" -> "The deny layer refused the last note."
  | "relay_rejecting" -> "A relay rejected this node's last sync."
  | r -> r

(* The digest's silence report. While this node has not posted in three days: since when, and the
   fixed reason. *)
let silence_report c ~since:_ =
  let me = self_identity c in
  let last = Option.bind me (Hashtbl.find_opt (last_posted c)) in
  let silent =
    match last with Some at -> c.now -. unix at >= three_days | None -> true
  in
  let head =
    if not silent then []
    else
      (match last with
      | Some at ->
          "Your node has not posted since "
          ^ Digestif_daily.Daily_digest.day_label (unix at)
          ^ "."
      | None -> "Your node has not posted yet.")
      :: Option.to_list (Option.map silence_reason_line (silence_reason c))
  in
  match (me, head) with
  | None, _ | _, [] -> None
  | Some _, lines -> Some { Digestif_mail.Digest.title = "Silence"; lines }

let silence_section node ~since ~now =
  silence_report
    { node; fold = Node.fold node; now; on_write = (fun () -> ()) }
    ~since

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
  | Some me -> (
      let recipient =
        match parent with
        | Some p when p.author <> me -> Some p.author
        | _ -> None
      in
      let kind = if recipient = None then "summary" else "answer" in
      let refused rule =
        let o : Store.outbound =
          {
            o_id = Store.local_hash ();
            o_kind = kind;
            voice = "person";
            recipient;
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
            match recipient with
            | None ->
                Ok (Content.summary_body ~text ~voice:"person" ?reply_to ())
            | Some r -> (
                match (card c r, own_card_key c) with
                | Some k, Some self_key ->
                    Content.directed_body ~to_identity:r
                      ~to_key:k.encryption_key ~self_key ~text ~voice:"person"
                      ?reply_to ()
                | _ ->
                    Error
                      "Both of you need a published card before a reply can be \
                       sealed.")
          in
          match Result.bind body (sign c ~kind) with
          | Error e -> invalid "not_signed" e
          | Ok hash -> (
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

let feed c q =
  match limit_of q with
  | Error e -> e
  | Ok limit ->
      let before = List.assoc_opt "before" q in
      feed_msgs c
      |> List.filter (fun m ->
          match before with
          | Some b -> unix m.created_at < unix b
          | None -> true)
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
   setup chat and the first note). A state of the note page: the steps of the run, the note once it
   waits, or why there is none. The newest tick since the start says the run had nothing to say; an
   open problem in the work run says why it could not write one. *)
module First_note = struct
  let progress_file c =
    Filename.concat c.node.dir "behaviors/nightly/progress.json"

  let progress c =
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

  let shared c = own_rows c "summary" <> []

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
    match (Store.Notes.waiting (log c), problem, tick) with
    | n :: _, _, _ -> `Waiting n.Store.Notes.n_id
    | [], Some p, _ -> `Failed (Problems.sentence p)
    | [], None, Some { outcome = Store.Quiet; _ } -> `No_activity
    | [], None, _ -> `Writing

  (* Absent before the chat starts the note and after it goes out. *)
  let json c : Yojson.Safe.t option =
    match Store.Setup.first_note_started (log c) with
    | None -> None
    | Some _ when shared c -> None
    | Some started ->
        Some
          (`Assoc
             (match state c ~started with
             | `Waiting id -> [ ("state", str "waiting"); ("note", str id) ]
             | `No_activity -> [ ("state", str "no_activity") ]
             | `Failed m -> [ ("state", str "failed"); ("message", str m) ]
             | `Writing -> ("state", str "writing") :: progress c))

  (* The navigation is hidden until the first note goes out, except with no activity: there may be
     nothing to approve for a long time, and Settings has to be reachable. *)
  let hides_navigation c =
    (not (shared c))
    &&
    match Store.Setup.first_note_started (log c) with
    | Some started -> state c ~started <> `No_activity
    | None -> true
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
           ("open_asks", `Int (open_asks c));
           ( "notes_awaiting_approval",
             `Int (List.length (Store.Notes.waiting (log c))) );
         ]
       @ (match First_note.json c with
         | Some j -> [ ("first_note", j) ]
         | None -> [])
       @
       match phone_app_url c with
       | Some u -> [ ("phone_app_url", str u) ]
       | None -> []))

let answer c x body =
  match string_field "option_id" body with
  | _ when ask_status c x <> "open" ->
      invalid "not_open" "This ask is no longer open."
  | Some o
    when List.exists
           (fun (ch : Digestif_mail.Ask.choice) -> ch.id = o)
           x.a.options -> (
      match Option.bind (own_card_key c) Content.raw_x25519 with
      | None -> invalid "no_card" "Publish your card before answering."
      | Some member_key -> (
          let body =
            Digestif_mail.Ask.decision_body ~member_key ~ask:x.a_hash ~option:o
          in
          match sign c ~kind:"decision" body with
          | Error e -> invalid "not_signed" e
          | Ok _ -> (
              match List.find_opt (fun y -> y.a_hash = x.a_hash) (asks c) with
              | Some y -> ok ~status:201 (ask_json c y)
              | None -> not_found ())))
  | _ -> invalid ~field:"option_id" "unknown_option" "No such option."

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
            ok ~status:201
              (deny_json (Store.add_deny (log c) ~kind:k ~value ())))

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
  let organizations _c = not_built "ISS-38778"
  let set_organization _c _id _body = not_built "ISS-38778"
  let repositories _c _query = not_built "ISS-38778"
  let set_repository _c _id _body = not_built "ISS-38778"
  let authors _c = not_built "ISS-38778"
  let add_author _c _body = not_built "ISS-38778"
  let label_author _c _id _body = not_built "ISS-38778"
  let remove_author _c _id = not_built "ISS-38778"
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

  let approvable (n : N.note) ~(newest : N.version option) (v : N.version) =
    n.n_status = "waiting" && N.passed v
    && Option.map (fun (x : N.version) -> x.v_id) newest = Some v.v_id
    && Option.value v.v_text ~default:"" <> ""

  let note_json c ?shown (n : N.note) : Yojson.Safe.t =
    let newest = newest c n in
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
      @ [
          ( "can_approve",
            `Bool
              (match shown with
              | Some v -> approvable n ~newest v
              | None -> false) );
          ("can_edit", `Bool (n.n_status = "waiting"));
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
      | Some t -> [ ("preview", str (clip (first_line t))) ]
      | None -> [])

  let list c =
    ok
      (`Assoc
         [
           ("notes", `List (List.map (summary_json c) (N.all (log c))));
           ("suggest_auto_approval", `Bool (N.suggest (log c)));
           ("no_activity", `Bool false);
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
        match
          Option.bind (string_field "version_id" body) (N.version (log c))
        with
        | _ when n.n_status <> "waiting" ->
            invalid "not_waiting" "This note is not waiting."
        | Some v when v.v_note = n.n_id && approvable n ~newest v ->
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

  let problem_kind ~signed_out =
    if signed_out then "signed_out" else "model_unavailable"

  (* A check could not finish on [v]: it stays unseen and unapproved, its Log says so and when the
     checks alone run again, and the check's problem stays open until they pass. *)
  let could_not_finish c ?(runs = []) (v : N.version) ~check ~signed_out ~retry
      =
    let kind = problem_kind ~signed_out in
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
  let submit ?(runs = []) ?could_not_finish:cnf ~approve c text =
    let at = Time_fmt.now () in
    let approve = approve && cnf = None in
    let status = if approve then "auto_approved" else "waiting" in
    let retry = c.now +. N.retry_hour in
    let id, vid =
      N.add (log c) ~at
        ?could_not_finish:(Option.map (fun (check, _) -> (check, retry)) cnf)
        ~status text
    in
    let v = Option.get (N.version (log c) vid) in
    add_log c ~note_id:id
      (List.map (with_version_id v)
         ((Note_checks.written ~at :: (if cnf = None then runs else []))
         @ if approve then [ Note_checks.entry ~at "auto_approved" [] ] else []
         ));
    Problems.resolve c ~job:"write_version" ();
    (match cnf with
    | Some (check, signed_out) ->
        could_not_finish c ~runs v ~check ~signed_out ~retry
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
    | Could_not_finish of { check : string; signed_out : bool }

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
        | Could_not_finish { check; signed_out } ->
            let retry = c.now +. N.retry_hour in
            N.could_not_finish (log c) vid ~check ~retry_at:retry;
            could_not_finish c ~runs v ~check ~signed_out ~retry;
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

  (* `digestif learnings set --version`: the agent's update of Learnings from an edit's diff. *)
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
  let send c =
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
                match
                  sign c ~kind:"summary"
                    (Content.summary_body ~text ~voice:"agent" ())
                with
                | Ok hash ->
                    N.posted (log c) ~note_id:n.n_id ~hash;
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
end

(* ISS-38780: Settings is one tab (DES-37265, Settings is one tab). *)
module Settings = struct
  let note_time _c = not_built "ISS-38780"
  let set_note_time _c _body = not_built "ISS-38780"

  (* The deny list's own section of Settings. *)
  let deny_list c = ok (`List (List.map deny_json (Store.deny_list (log c))))
end

(* ISS-38784: stages, the clock, the status note and Members (DES-37265, Onboarding, Active
   and Paused, The clock, The status note, Members is one table). *)
module Stages = struct
  (* node_status: stage. *)
  let status_fields _c : (string * Yojson.Safe.t) list = []

  (* member_summary, by identity: stage, last_note_at, last_status_note. *)
  let member_fields _c _identity : (string * Yojson.Safe.t) list = []

  (* feed_item, by hash: status_note. *)
  let feed_fields _c _hash : (string * Yojson.Safe.t) list = []
  let invitees _c = not_built "ISS-38784"
end

(* ISS-38785: Pause (DES-37265, Pause). *)
module Pause = struct
  (* node_status: pause_warning. *)
  let status_fields _c : (string * Yojson.Safe.t) list = []
  let paused _c = not_built "ISS-38785"
  let pause _c = not_built "ISS-38785"
  let unpause _c = not_built "ISS-38785"
end

let route c ~meth ~path ~query ~body =
  match (meth, path) with
  | "GET", [ "status" ] ->
      extend (status c) (Stages.status_fields c @ Pause.status_fields c)
  | "GET", [ "feed" ] ->
      extend_each
        (fun j -> Stages.feed_fields c (string_of "hash" j))
        (feed c query)
  | "GET", [ "messages"; h ] ->
      with_found (find_msg c h) (fun m -> ok (message_json c m))
  | "POST", [ "messages" ] -> post c body
  | "GET", [ "asks" ] -> (
      let rank x = if ask_status c x = "open" then 0 else 1 in
      match List.assoc_opt "status" query with
      | Some s when not (List.mem s ask_statuses) ->
          invalid ~field:"status" "status" "Unknown status."
      | filter ->
          asks c
          |> List.filter (fun x ->
              match filter with Some s -> ask_status c x = s | None -> true)
          |> List.sort (fun x y ->
              match compare (rank x) (rank y) with
              | 0 -> compare y.a_created_at x.a_created_at
              | n -> n)
          |> List.map (fun x -> `Assoc (ask_summary_fields c x))
          |> fun l -> ok (`List l))
  | "GET", [ "asks"; id ] ->
      with_found
        (List.find_opt (fun x -> x.a_hash = id) (asks c))
        (fun x -> ok (ask_json c x))
  | "POST", [ "asks"; id; "answers" ] ->
      with_found
        (List.find_opt (fun x -> x.a_hash = id) (asks c))
        (fun x -> answer c x body)
  | "GET", [ "members" ] ->
      extend_each
        (fun j -> Stages.member_fields c (string_of "identity" j))
        (ok (`List (members_json c)))
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
  | "GET", [ "dinners" ] ->
      ok
        (`List
           (List.map
              (fun d ->
                `Assoc
                  (dinner_head c d
                  @ [
                      ("guests", `Int (List.length d.d_guests));
                      ("joined", `Int (joined_count d));
                    ]))
              (dinners c)))
  | "GET", [ "dinners"; h ] ->
      with_found
        (List.find_opt (fun d -> d.d_hash = h) (dinners c))
        (fun d ->
          ok
            (`Assoc
               (dinner_head c d
               @ [
                   ("guests", `List d.d_guests);
                   ("relays", `List (List.map str d.body.relays));
                 ])))
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
  | "GET", [ "sources" ] ->
      refresh_sources c;
      ok (sources_json c)
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
  | "GET", [ "rules"; "deny" ] -> Settings.deny_list c
  | "POST", [ "rules"; "deny" ] -> add_deny c body
  | "GET", [ "rules"; "deny"; id ] ->
      with_found (Store.deny_entry (log c) id) (fun e -> ok (deny_json e))
  | "DELETE", [ "rules"; "deny"; id ] ->
      with_found
        (Store.deny_entry (log c) id)
        (fun e ->
          Store.remove_deny (log c) e.d_id;
          no_content)
  | "GET", [ "notes" ] -> Notes.list c
  | "POST", [ "notes"; "suggestion"; "dismiss" ] -> Notes.dismiss_suggestion c
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
  | "GET", [ "problems" ] -> Problems.list c query
  | "GET", [ "organizations" ] -> Repositories.organizations c
  | "PUT", [ "organizations"; id ] -> Repositories.set_organization c id body
  | "GET", [ "repositories" ] -> Repositories.repositories c query
  | "PUT", [ "repositories"; id ] -> Repositories.set_repository c id body
  | "GET", [ "commit_authors" ] -> Repositories.authors c
  | "POST", [ "commit_authors" ] -> Repositories.add_author c body
  | "PUT", [ "commit_authors"; id ] -> Repositories.label_author c id body
  | "DELETE", [ "commit_authors"; id ] -> Repositories.remove_author c id
  | _ -> not_found ()

(* One request: the fold is computed once, from the log as it stands. *)
let handle ?(on_write = fun () -> ()) node ~meth ~path ~query ~body =
  let c =
    { node; fold = Node.fold node; now = Unix.gettimeofday (); on_write }
  in
  route c ~meth ~path ~query ~body

let ctx_of ?(on_write = fun () -> ()) node =
  { node; fold = Node.fold node; now = Unix.gettimeofday (); on_write }

let read_runs = function
  | None -> Ok []
  | Some j -> Note_checks.read_runs ~at:(Time_fmt.now ()) j

(* `digestif note`: the agent hands the node a checked note, and [checks], what each check run
   removed, by part and by what it broke (Note_checks.read_runs). [approve] is the agent approving
   it, which it does when auto approval is saved. *)
let submit_note_text ?checks ?could_not_finish ?(approve = false) node text =
  if text = "" then Error "the note is empty"
  else
    let* runs = read_runs checks in
    Notes.submit ~runs ?could_not_finish ~approve (ctx_of node) text

(* `digestif note checked`: the check behavior hands back an edit's checked text, or which check
   could not finish. *)
let version_checked_text ?checks ?approve node ~version result =
  let* runs = read_runs checks in
  Notes.checked ?approve ~runs (ctx_of node) version result

(* `digestif learnings set --version`: the agent's update of Learnings from an edit's diff. *)
let learnings_from_edit node ~version text =
  Notes.learned (ctx_of node) version text

(* The send job, once per pass of `digestif run`. *)
let send_notes node = Notes.send (ctx_of node)

(* `digestif post`: a behavior hands the node a body it built. A content kind (a summary, question,
   answer or proposal) goes through the deny layer first, so no behavior carries its own copy of the
   rules: the words are a summary's text, or a directed body's sealed words opened with this
   member's key, which every directed body is sealed to. A body the node cannot read is refused
   rather than signed unchecked. A refusal is kept as a refused outbound row, so the person sees it
   and the rule that tripped. Every other kind signs as it was given. *)
type post_error = Refused of string | Failed of string

let refused_rule_unreadable = "deny: unreadable"

let post_body node ?(key_name = "device") ~kind (body : Yojson.Safe.t) =
  let c =
    {
      node;
      fold = Node.fold node;
      now = Unix.gettimeofday ();
      on_write = (fun () -> ());
    }
  in
  let sign () =
    match Node.write node ~key_name ~kind body with
    | Ok (hash, _) -> Ok hash
    | Error e -> Error (Failed e)
  in
  if not (List.mem kind Content.feed_kinds) then sign ()
  else
    let read = Content.read ~enc:(encryption c) ~kind (Some body) in
    let verdict =
      match read.text with
      | None when List.mem kind Content.directed_kinds ->
          Some refused_rule_unreadable
      | text -> deny_check c (Option.value text ~default:"")
    in
    match verdict with
    | None -> sign ()
    | Some rule ->
        Store.add_outbound (log c)
          {
            o_id = Store.local_hash ();
            o_kind = kind;
            voice = read.voice;
            recipient = read.recipient;
            reply_to = read.reply_to;
            o_text = None;
            status = "refused";
            refused_rule = Some rule;
            o_created_at = Time_fmt.now ();
            posted_hash = None;
            held_reason = None;
          };
        Error (Refused rule)
