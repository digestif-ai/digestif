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

let member_ref c identity : Yojson.Safe.t =
  let name, agent =
    match card c identity with
    | Some k -> (k.card_name, k.agent_name)
    | None -> ("Member " ^ short identity, "Agent")
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
    |> List.filter (fun (o : Store.outbound) ->
        o.status = "awaiting_approval" || o.status = "refused")
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

let awaiting c =
  List.filter
    (fun (o : Store.outbound) -> o.status = "awaiting_approval")
    (Store.outbox (log c))

let approvals_required c =
  max 0 (Store.required_approvals - Store.approved (log c))

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

let silence_notes_limit = 5

(* The nightly tick runs once a day; a node with no tick in a day and a half missed one. *)
let tick_window = 1.5 *. 86400.0

(* Why this node, silent for three days, has not posted: nothing to read, the nightly tick has
   stopped running, the last run that did anything could not use the harness or had its note refused,
   or a relay is rejecting what it pushes. *)
let silence_reason c =
  let l = log c in
  let ticks =
    List.filter
      (fun (t : Store.tick) -> c.now -. unix t.t_at < three_days)
      (Store.ticks l ~limit:64)
  in
  let latest_did_something =
    List.find_opt (fun (t : Store.tick) -> t.outcome <> Store.Quiet) ticks
  in
  if not (List.exists (fun (s : Store.source) -> s.selected) (Store.sources l))
  then Some "no_sources"
  else if
    not
      (List.exists
         (fun (t : Store.tick) -> c.now -. unix t.t_at < tick_window)
         ticks)
  then Some "asleep"
  else
    match latest_did_something with
    | Some { outcome = Store.Harness_signed_out; _ } ->
        Some "harness_signed_out"
    | Some { outcome = Store.Refused; _ } -> Some "deny_refusing"
    | _ ->
        if
          List.exists
            (fun (r : Log.relay_row) -> r.last_error <> None)
            (Log.relays l)
        then Some "relay_rejecting"
        else None

(* The silence notes a behavior recorded in the last three days, newest first. *)
let silence_window_notes c =
  Store.silence_notes (log c)
    ~since:(Time_fmt.of_unix (c.now -. three_days))
    ~limit:silence_notes_limit

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
  let note =
    if silent_self then
      Option.map
        (fun (n : Store.silence_note) -> n.sn_text)
        (List.nth_opt (silence_window_notes c) 0)
    else None
  in
  (match member_ref c k.key with `Assoc f -> f | _ -> [])
  @ [ ("status", str status) ]
  @ opt "last_posted_at" last
  @ opt "silence_reason" reason
  @ opt "silence_note" note
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
  Hashtbl.fold (fun h _ acc -> h :: acc) c.fold.dinners []
  |> List.filter_map (fun h ->
      match Log.find (log c) h with
      | Some { signed = { body = Some b; _ }; _ } -> (
          match Bodies.parse_dinner b with
          | Ok d ->
              let guest (g : Bodies.guest) =
                let joined =
                  match Hashtbl.find_opt c.fold.invites g.invite_key with
                  | Some { spent_by = Some join; _ } -> (
                      match Log.find (log c) join with
                      | Some { signed = { body = Some jb; _ }; _ } -> (
                          match Bodies.parse_join jb with
                          | Ok j -> Some j.identity_key
                          | Error _ -> None)
                      | _ -> None)
                  | _ -> None
                in
                let status =
                  match joined with
                  | Some id -> (
                      match Fold.find c.fold id with
                      | Some { revoked_by = Some _; _ } -> "revoked"
                      | _ -> "joined")
                  | None ->
                      if c.now >= unix g.expires_at then "expired"
                      else "invited"
                in
                `Assoc
                  ([
                     ("name", str g.name);
                     ("status", str status);
                     ("expires_at", str g.expires_at);
                   ]
                  @ opt "identity" joined)
              in
              Some { d_hash = h; body = d; d_guests = List.map guest d.guests }
          | Error _ -> None)
      | _ -> None)
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

(* approvals: this member's agent notes *)

let is_note m = m.kind = "summary" && m.voice = "agent"

let approval_notes c =
  let me = self_identity c in
  let held =
    Store.outbox (log c)
    |> List.filter (fun (o : Store.outbound) -> o.posted_hash = None)
    |> List.map (of_outbound c)
    |> List.filter is_note
  in
  let posted =
    View.feed (log c) c.fold
    |> List.map (of_row c)
    |> List.filter (fun m -> is_note m && Some m.author = me)
  in
  let waiting m = if m.status = "awaiting_approval" then 0 else 1 in
  List.sort
    (fun a b ->
      match compare (waiting a) (waiting b) with
      | 0 -> compare b.created_at a.created_at
      | n -> n)
    (held @ posted)

(* Sign a held note as the agent's summary, unless the deny layer now refuses it. *)
let approve c (o : Store.outbound) =
  let text = Option.value o.o_text ~default:"" in
  match deny_check c text with
  | Some rule ->
      Store.settle_outbound (log c) o.o_id ~status:"refused" ~refused_rule:rule
        ();
      Ok ()
  | None ->
      let* hash =
        sign c ~kind:"summary" (Content.summary_body ~text ~voice:"agent" ())
      in
      Store.settle_outbound (log c) o.o_id ~status:"posted" ~text
        ~posted_hash:hash ();
      Store.set_approved (log c) (Store.approved (log c) + 1);
      Ok ()

(* A note from the nightly pipeline: refused by the deny layer, held while any of the first five
   is unapproved, else signed. Answers the outbound row or the envelope hash. *)
let submit_note c text =
  let base : Store.outbound =
    {
      o_id = Store.local_hash ();
      o_kind = "summary";
      voice = "agent";
      recipient = None;
      reply_to = None;
      o_text = Some text;
      status = "awaiting_approval";
      refused_rule = None;
      o_created_at = Time_fmt.now ();
      posted_hash = None;
    }
  in
  let tick outcome r =
    if Result.is_ok r then
      Store.add_tick (log c) ~at:(Time_fmt.of_unix c.now) outcome;
    r
  in
  match deny_check c text with
  | Some rule ->
      Store.add_outbound (log c)
        {
          base with
          status = "refused";
          o_text = None;
          refused_rule = Some rule;
        };
      tick Store.Refused (Ok base.o_id)
  | None ->
      if approvals_required c > 0 then begin
        Store.add_outbound (log c) base;
        tick Store.Held (Ok base.o_id)
      end
      else
        tick Store.Posted
          (sign c ~kind:"summary"
             (Content.summary_body ~text ~voice:"agent" ()))

(* silence notes: a behavior says, in its own words, why a run handed over no note *)

let silence_note_max = 280

let silence_note_json (n : Store.silence_note) : Yojson.Safe.t =
  `Assoc
    [
      ("id", str n.sn_id); ("text", str n.sn_text); ("created_at", str n.sn_at);
    ]

(* The note reaches the person in the digest, which the mailing relay opens to mail it, so it
   passes the deny layer like anything else that leaves the node. *)
let record_silence_note ?outcome c text =
  let text = String.trim text in
  if text = "" then Error (`Empty, "Say why the run handed over no note.")
  else if String.length text > silence_note_max then
    Error
      ( `Too_long,
        Printf.sprintf "A silence note is at most %d characters."
          silence_note_max )
  else
    match deny_check c text with
    | Some rule -> Error (`Denied, "The deny layer refused it: " ^ rule ^ ".")
    | None ->
        Ok
          (Store.add_silence_note (log c) ?outcome ~at:(Time_fmt.of_unix c.now)
             text)

let add_silence_note c body =
  match
    record_silence_note c (Option.value (string_field "text" body) ~default:"")
  with
  | Ok n -> ok ~status:201 (silence_note_json n)
  | Error (`Empty, m) -> invalid ~field:"text" "empty" m
  | Error (`Too_long, m) -> invalid ~field:"text" "too_long" m
  | Error (`Denied, m) -> invalid ~field:"text" "denied" m

let silence_reason_line = function
  | "no_sources" ->
      "No source is chosen, so the nightly run has nothing to read."
  | "asleep" -> "The nightly run has not run in a day and a half."
  | "harness_signed_out" ->
      "The last run could not use your agent harness; it may be signed out."
  | "deny_refusing" -> "The deny layer refused the last note."
  | "relay_rejecting" -> "A relay rejected this node's last sync."
  | r -> r

let own_agent_name c =
  match Option.bind (self_identity c) (card c) with
  | Some k -> k.agent_name
  | None -> "Your agent"

(* The digest's silence report. While this node has not posted in three days: since when, the fixed
   reason, and every note a behavior recorded in those three days. Otherwise only the notes recorded
   since the last digest, so a night that was skipped for a reason still says so once. *)
let silence_report c ~since =
  let me = self_identity c in
  let last = Option.bind me (Hashtbl.find_opt (last_posted c)) in
  let silent =
    match last with Some at -> c.now -. unix at >= three_days | None -> true
  in
  let notes =
    if silent then silence_window_notes c
    else
      match since with
      | Some since ->
          Store.silence_notes (log c) ~since ~limit:silence_notes_limit
      | None -> silence_window_notes c
  in
  let seen = Hashtbl.create 8 in
  let note_lines =
    List.filter_map
      (fun (n : Store.silence_note) ->
        if Hashtbl.mem seen n.sn_text then None
        else (
          Hashtbl.add seen n.sn_text ();
          Some (own_agent_name c ^ ": " ^ n.sn_text)))
      notes
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
  match (me, head @ note_lines) with
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
           ("first_run", `Bool (Store.first_run (log c)));
           ("open_asks", `Int (open_asks c));
           ("notes_awaiting_approval", `Int (List.length (awaiting c)));
           ("approvals_required", `Int (approvals_required c));
         ]))

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

let preview c body =
  match selection c body with
  | Error e -> e
  | Ok [] -> ok (`Assoc [ ("extracted", `List []) ])
  | Ok ids -> (
      let chosen =
        List.filter
          (fun (s : Store.source) -> List.mem s.id ids)
          (Store.sources (log c))
      in
      let extracted = Sources.extract ~now:c.now chosen in
      let lines = ("extracted", `List (List.map str extracted)) in
      match Sources.write extracted with
      | Error e -> invalid "writer" e
      | Ok text -> (
          match deny_check c ~count:false text with
          | Some rule -> ok (`Assoc [ ("refused_rule", str rule); lines ])
          | None -> ok (`Assoc [ ("text", str text); lines ])))

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

let held_note c hash =
  match Store.outbound (log c) hash with
  | Some o when is_note (of_outbound c o) -> Some o
  | _ -> None

let decide c hash ~approve:yes =
  match held_note c hash with
  | None -> not_found ()
  | Some o when o.status <> "awaiting_approval" ->
      invalid "not_awaiting" "This note was already decided."
  | Some o -> (
      let r =
        if yes then approve c o
        else begin
          Store.settle_outbound (log c) o.o_id ~status:"retracted" ();
          Ok ()
        end
      in
      match r with
      | Error e -> invalid "not_signed" e
      | Ok () -> (
          match find_msg c hash with
          | Some m -> ok (message_json c m)
          | None -> not_found ()))

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

let with_found v f = match v with Some x -> f x | None -> not_found ()

let route c ~meth ~path ~query ~body =
  match (meth, path) with
  | "GET", [ "status" ] -> status c
  | "GET", [ "feed" ] -> feed c query
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
  | "GET", [ "members" ] -> ok (`List (members_json c))
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
  | "GET", [ "brief" ] ->
      let b = Store.brief (log c) in
      ok (`Assoc ([ ("text", str b.text) ] @ opt "updated_at" b.updated_at))
  | "PUT", [ "brief" ] -> (
      match
        String.trim (Option.value (string_field "text" body) ~default:"")
      with
      | "" -> invalid ~field:"text" "empty" "Write a few lines about yourself."
      | text ->
          Store.set_brief (log c) text;
          let b = Store.brief (log c) in
          ok (`Assoc ([ ("text", str b.text) ] @ opt "updated_at" b.updated_at))
      )
  | "GET", [ "sources" ] ->
      refresh_sources c;
      ok (sources_json c)
  | "PUT", [ "sources" ] -> (
      match selection c body with
      | Error e -> e
      | Ok ids ->
          Store.select_sources (log c) ids;
          ok (sources_json c))
  | "POST", [ "sources"; "preview" ] -> preview c body
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
  | "GET", [ "silence_notes" ] ->
      ok (`List (List.map silence_note_json (silence_window_notes c)))
  | "POST", [ "silence_notes" ] -> add_silence_note c body
  | "POST", [ "rules"; "deny" ] -> add_deny c body
  | "GET", [ "rules"; "deny"; id ] ->
      with_found (Store.deny_entry (log c) id) (fun e -> ok (deny_json e))
  | "DELETE", [ "rules"; "deny"; id ] ->
      with_found
        (Store.deny_entry (log c) id)
        (fun e ->
          Store.remove_deny (log c) e.d_id;
          no_content)
  | "GET", [ "approvals" ] ->
      ok
        (`Assoc
           [
             ("approved", `Int (Store.approved (log c)));
             ("required", `Int Store.required_approvals);
             ("notes", `List (List.map (item_json c) (approval_notes c)));
           ])
  | "GET", [ "approvals"; h ] ->
      let mine =
        match held_note c h with
        | Some _ -> find_msg c h
        | None -> List.find_opt (fun m -> m.hash = h) (approval_notes c)
      in
      with_found mine (fun m -> ok (message_json c m))
  | "POST", [ "approvals"; h; "approve" ] -> decide c h ~approve:true
  | "POST", [ "approvals"; h; "refuse" ] -> decide c h ~approve:false
  | _ -> not_found ()

(* One request: the fold is computed once, from the log as it stands. *)
let handle ?(on_write = fun () -> ()) node ~meth ~path ~query ~body =
  let c =
    { node; fold = Node.fold node; now = Unix.gettimeofday (); on_write }
  in
  route c ~meth ~path ~query ~body

(* `digestif tick --note`: the nightly pipeline says why it handed over no note. *)
let silence_note_text ?outcome node text =
  Result.map_error snd
    (record_silence_note ?outcome
       {
         node;
         fold = Node.fold node;
         now = Unix.gettimeofday ();
         on_write = (fun () -> ());
       }
       text)

(* `digestif note`: the nightly pipeline hands the node a note. *)
let submit_note_text node text =
  if text = "" then Error "the note is empty"
  else
    submit_note
      {
        node;
        fold = Node.fold node;
        now = Unix.gettimeofday ();
        on_write = (fun () -> ());
      }
      text
