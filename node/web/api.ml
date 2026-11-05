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

let message_json c m : Yojson.Safe.t =
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

let ask_kinds = Digestif_mail.Ask.wire_kinds
let ask_statuses = [ "open"; "answered"; "lapsed"; "withdrawn" ]

(* The ask an "ask" envelope seals for this member, and its plaintext. *)
let open_ask (enc : Crypto.encryption_key) (r : Log.row) =
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

(* An ask's kind, as its plaintext names it; one this node does not know reads as a share. *)
let ask_kind_of p =
  match Content.str_field "kind" p with
  | Some k when List.mem k ask_kinds -> k
  | _ -> "share"

(* The member's own authors: every key the log holds that the fold says is theirs. *)
let own_authors c =
  match self_identity c with
  | None -> []
  | Some me ->
      List.filter (fun k -> identity_of c k = Some me) (Log.authors (log c))

(* ISS-41988: bring the store's index of asks and decisions up to the log, opening each envelope
   once. An envelope whose body has not arrived yet is left for the next read; one withdrawn before
   it was read is recorded as unopened. *)
let index_asks c =
  match encryption c with
  | None -> ()
  | Some enc ->
      let module I = Store.Ask_index in
      let l = log c in
      let each kind f =
        I.unindexed l kind
        |> List.iter (fun hash ->
            match Log.find l hash with
            | Some r when r.signed.body <> None || r.retracted_by <> None -> f r
            | _ -> ())
      in
      Log.transaction l (fun () ->
          each "ask" (fun r ->
              I.put_ask l ~hash:r.hash ~author:r.signed.envelope.author
                ~created_at:r.signed.envelope.created_at
                (Option.map
                   (fun ((a : Digestif_mail.Ask.t), p) ->
                     {
                       I.deadline_at = a.lapses_at;
                       lapses_unix = Option.map unix a.lapses_at;
                       kind = ask_kind_of p;
                       title = a.title;
                       sender = Content.str_field "from" p;
                     })
                   (open_ask enc r)));
          each "decision" (fun r ->
              I.put_decision l ~hash:r.hash ~author:r.signed.envelope.author
                ~decided:
                  (match r.signed.body with
                  | None -> None
                  | Some b -> (
                      match
                        Digestif_mail.Ask.decision_of_body ~priv:enc.secret b
                      with
                      | Ok (ask, option) ->
                          let at = r.signed.envelope.created_at in
                          Some (ask, option, at, unix at)
                      | Error _ -> None))))

(* The ask the envelope [r] holds, with the member's answer to it from the index. *)
let ask_of_row c enc ~authors (r : Log.row) =
  match open_ask enc r with
  | None -> None
  | Some (a, p) ->
      Some
        {
          a_hash = r.hash;
          a_kind = ask_kind_of p;
          a;
          from = Content.str_field "from" p;
          a_created_at = r.signed.envelope.created_at;
          withdrawn = r.retracted_by <> None;
          decision =
            Store.Ask_index.decision ~authors
              ~lapses_at:(Option.map unix a.lapses_at)
              (log c) r.hash;
        }

(* The asks [hashes] names, in that order, each one the index lists as the member's own. *)
let asks_of c ~authors hashes =
  match encryption c with
  | None -> []
  | Some enc ->
      List.filter_map
        (fun hash ->
          Option.bind (Log.find (log c) hash) (ask_of_row c enc ~authors))
        hashes

(* The ask [hash], when it is one of the member's own the node can show. *)
let find_ask c hash =
  index_asks c;
  let authors = own_authors c in
  match Store.Ask_index.status ~authors ~now:c.now (log c) hash with
  | None -> None
  | Some _ -> List.nth_opt (asks_of c ~authors [ hash ]) 0

let ask_status c x =
  if x.withdrawn then "withdrawn"
  else if x.decision <> None then "answered"
  else if match x.a.lapses_at with Some l -> c.now >= unix l | None -> false
  then "lapsed"
  else "open"

let summary_of c ~id ~kind ~title ~status ~from ~deadline_at ~created_at =
  [
    ("id", str id);
    ("kind", str kind);
    ("title", str title);
    ("status", str status);
  ]
  @ (match from with Some f -> [ ("from", member_ref c f) ] | None -> [])
  @ opt "deadline_at" deadline_at
  @ [ ("created_at", str created_at) ]

let ask_summary_fields c x =
  summary_of c ~id:x.a_hash ~kind:x.a_kind ~title:x.a.title
    ~status:(ask_status c x) ~from:x.from ~deadline_at:x.a.lapses_at
    ~created_at:x.a_created_at

let ask_json c x : Yojson.Safe.t =
  let default =
    List.find_opt
      (fun (o : Digestif_mail.Ask.choice) -> o.id = x.a.on_no_answer)
      x.a.options
  in
  `Assoc
    (ask_summary_fields c x
    @ [
        ("local", `Bool (Digestif_mail.Ask.local x.a_kind));
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
            (match (default, x.a.lapses_at) with
            | Some o, Some _ ->
                "If you do not answer by the deadline: " ^ o.label ^ "."
            | Some o, None -> "If you do not answer: " ^ o.label ^ "."
            | None, Some _ -> "Lapses at the deadline."
            | None, None -> "Stands until you answer.") );
      ]
    @ opt "message" x.a.about
    @
    match x.decision with
    | Some (o, at) ->
        [ ("answer", `Assoc [ ("option_id", str o); ("answered_at", str at) ]) ]
    | None -> [])

(* ISS-42316 (DES-37153, What leaves the machine): a local ask lives in the node's own ask store
   and never in the log, so the Asks list reads it from there. It holds no options and takes no
   answer here: it is answered on the page it opens, and closes itself. *)
let local_asks ?(all = false) c =
  List.filter
    (fun (a : Asks.t) -> Asks.local_kind a.kind)
    (Asks.list ~all (log c))

let local_ask c id =
  List.find_opt (fun (a : Asks.t) -> a.key = id) (local_asks ~all:true c)

let local_status (a : Asks.t) = if a.answer = None then "open" else "answered"

let local_summary c (a : Asks.t) =
  summary_of c ~id:a.key
    ~kind:(Option.value a.kind ~default:"share")
    ~title:a.title ~status:(local_status a) ~from:None ~deadline_at:None
    ~created_at:a.raised_at

let local_ask_json c (a : Asks.t) : Yojson.Safe.t =
  `Assoc
    (local_summary c a
    @ [
        ("local", `Bool true);
        ("detail", str a.detail);
        ("options", `List []);
        ( "on_no_answer",
          str "Nothing is read until you decide, and the ask stays open." );
      ]
    @
    match (a.answer, a.answered_at) with
    | Some o, Some at ->
        [ ("answer", `Assoc [ ("option_id", str o); ("answered_at", str at) ]) ]
    | _ -> [])

let open_asks c =
  index_asks c;
  Store.Ask_index.open_count ~authors:(own_authors c) ~now:c.now (log c)
  + List.length (local_asks c)

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

(* ISS-41988: one page of the member's asks, open first and then the newest, of [status] when the
   query names one, read from the store's index: the list opens no ask, each having been opened once
   when the index first read it. *)
let ask_page c query =
  let authors =
    lazy
      (index_asks c;
       own_authors c)
  in
  (* ISS-42316: the open local asks lead the list, as every open ask does, and a cursor naming one
     continues past it. *)
  let locals = local_asks c in
  let local id = List.exists (fun (a : Asks.t) -> a.key = id) locals in
  let known id =
    local id
    || Store.Ask_index.status ~authors:(Lazy.force authors) ~now:c.now (log c)
         id
       <> None
  in
  match
    let* status =
      match List.assoc_opt "status" query with
      | None | Some "" -> Ok None
      | Some s when List.mem s ask_statuses -> Ok (Some s)
      | Some _ -> Error (invalid ~field:"status" "status" "Unknown status.")
    in
    let* limit = limit_param query ~default:100 in
    let* after = cursor_param query ~known in
    Ok (status, limit, after)
  with
  | Error e -> e
  | Ok (status, limit, after) ->
      let shown =
        if status <> None && status <> Some "open" then []
        else
          match after with
          | None -> locals
          | Some id when local id ->
              let rec past = function
                | [] -> []
                | (a : Asks.t) :: rest -> if a.key = id then rest else past rest
              in
              past locals
          | Some _ -> []
      in
      let shown = List.filteri (fun i _ -> i < limit) shown in
      let after = match after with Some id when local id -> None | a -> a in
      let indexed =
        if List.length shown >= limit then []
        else
          Store.Ask_index.page ~authors:(Lazy.force authors) ~now:c.now ?status
            ?after
            ~limit:(limit - List.length shown)
            (log c)
      in
      List.map (fun a -> `Assoc (local_summary c a)) shown
      @ List.map
          (fun (l : Store.Ask_index.listed) ->
            `Assoc
              (summary_of c ~id:l.l_hash ~kind:l.l_kind ~title:l.l_title
                 ~status:l.l_status ~from:l.l_sender
                 ~deadline_at:l.l_deadline_at ~created_at:l.l_created_at))
          indexed
      |> fun l -> ok (`List l)

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
                Ok
                  (Content.summary_body ~text ~voice:"person" ?reply_to
                     ~stage:(Store.Stages.stage (log c))
                     ())
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
          (refused c)
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
   had nothing to say; an open problem in the work run says why it could not write one. *)
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

  (* The navigation is hidden until the first note goes out, except with no activity: there may be
     nothing to approve for a long time, and Settings has to be reachable. *)
  let no_activity c =
    match pending c with
    | Some (_, started) -> state c ~started = `No_activity
    | None -> false

  let hides_navigation c = (not (shared c)) && not (no_activity c)
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
       @ (match First_note.ref_ c with
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
              match find_ask c x.a_hash with
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
      @ (match First_note.progress c n with
        | Some p -> [ ("progress", p) ]
        | None -> [])
      @ [
          ( "can_approve",
            `Bool
              (match shown with
              | Some v -> approvable n ~newest v
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
      | Some t -> [ ("preview", str (clip (first_line t))) ]
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
  let submit ?(runs = []) ?could_not_finish:cnf ?(ends = []) ~approve c text =
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
    (* Where the note ends moves each source's start once it is approved: now, when the agent
       approved it, else when the member does (Store.Notes.approve). *)
    Store.Record.set_ends (log c) ~note_id:id ends;
    if approve then Store.Record.approve (log c) ~note_id:id;
    add_log c ~note_id:id
      (List.map (with_version_id v)
         ((Note_checks.written ~at :: (if cnf = None then runs else []))
         @ if approve then [ Note_checks.entry ~at "auto_approved" [] ] else []
         ));
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
                let stage = Store.Stages.going_out (log c) in
                match
                  sign c ~kind:"summary"
                    (Content.summary_body ~text ~voice:"agent" ~stage ())
                with
                | Ok hash ->
                    N.posted (log c) ~note_id:n.n_id ~hash;
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
   twice and can take minutes, so Save starts it in the background (Background.run) and answers at
   once; the Agent page reads the check until it ends, and every other page answers meanwhile. *)
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
  let thread : Thread.t option ref = ref None

  (* The running check's end, for a test. *)
  let wait () = Option.iter Thread.join !thread

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

  (* The check, on its own thread and its own connection to the log: saved only when it passes. *)
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
    | Ok a -> (
        let busy () =
          invalid "checking"
            (match Atomic.get last with
            | Some { agent; status = Checking } ->
                agent.name ^ " is still being checked."
            | _ -> "A check is still running.")
        in
        if Atomic.get checking then busy ()
        else
          let started = { agent = a; status = Checking } in
          let dir = c.node.dir in
          let prior = Atomic.exchange last (Some started) in
          match
            Background.run ~running:checking ~dir ~what:"agent check"
              ~on_error:(fun e ->
                Atomic.set last
                  (Some
                     {
                       agent = a;
                       status =
                         failed a
                           ("could not be checked (" ^ Printexc.to_string e
                          ^ ")");
                     }))
              (run ~dir a)
          with
          | Some t ->
              thread := Some t;
              ok ~status:202 (check_json started)
          | None ->
              Atomic.set last prior;
              busy ())
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

  (* feed_item, by hash: status_note. A status note is one muted line under the member's name. *)
  let feed_fields c hash : (string * Yojson.Safe.t) list =
    match Log.find (log c) hash with
    | Some r when r.signed.envelope.kind = "summary" ->
        opt "status_note" (Content.status_of r.signed.body)
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

  (* The Feed's compose box opens at Active. *)
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
    match P.warning (log c) ~now:c.now with
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

    (* An unpause on the machine closes the open ask by writing its Unpause decision with the
       device key, so the phone and its answer links read it as answered (docs/protocol.md, Asks
       and decisions). An ask no digest appended yet has no envelope to answer and is recorded
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
                    (Digestif_mail.Ask.decision_body ~member_key:enc.public ~ask
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
  | "POST", [ "messages" ] -> Stages.compose c (fun () -> post c body)
  | "GET", [ "asks" ] -> ask_page c query
  | "GET", [ "asks"; id ] -> (
      match local_ask c id with
      | Some a -> ok (local_ask_json c a)
      | None -> with_found (find_ask c id) (fun x -> ok (ask_json c x)))
  | "POST", [ "asks"; id; "answers" ] when local_ask c id <> None ->
      invalid "local"
        "This ask is answered on its own page, and closes itself once nothing \
         waits."
  | "POST", [ "asks"; id; "answers" ] ->
      with_found (find_ask c id) (fun x -> answer c x body)
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
          no_content)
  | "GET", [ "notes" ] -> Notes.list c query
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

(* `digestif note`: the agent hands the node a checked note, and [checks], what each check run
   removed, by part and by what it broke (Note_checks.read_runs). [approve] is the agent approving
   it, which it does when auto approval is saved. *)
let submit_note_text ?checks ?could_not_finish ?(approve = false) ?ends node
    text =
  if text = "" then Error "the note is empty"
  else
    let* runs = read_runs checks in
    Notes.submit ~runs ?could_not_finish ?ends ~approve (ctx_of node) text

(* `digestif note checked`: the check behavior hands back an edit's checked text, or which check
   could not finish. *)
let version_checked_text ?checks ?approve node ~version result =
  let* runs = read_runs checks in
  Notes.checked ?approve ~runs (ctx_of node) version result

(* `digestif learnings set VERSION`: the agent's update of Learnings from an edit's diff. *)
let learnings_from_edit node ~version text =
  Notes.learned (ctx_of node) version text

(* The send job, once per pass of `digestif run`. *)
let send_notes node = Notes.send (ctx_of node)

(* `digestif run`: the clock, after the pass's work run was started. A note that has waited 30
   days pauses an Active member first, which sends Paused and stops the clock. *)
let clock node ~working =
  let c = ctx_of node in
  match Pause.due c with Some r -> Some r | None -> Stages.clock c ~working

(* `digestif run`: after the pass's sync settled the asks, an Unpause answered to the Paused ask
   unpauses. Answers whether it did. *)
let settled_unpause node = Pause.answered (ctx_of node)

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
  if not (List.mem kind Content.feed_kinds) then sign ()
  else if stage <> "active" then
    Error
      (Failed
         (Printf.sprintf "this member is %s: nothing is posted until Active"
            stage))
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
