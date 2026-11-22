(* The host's node watching the joins on its dinners.

   Whoever reads an invite email first can post its join, so every join on one of the host's
   invites reaches the host's person. A join the host expected (the person recorded hearing that
   the guest installed) is shown in the feed and the digest; any other is an ask: confirm, or
   revoke the identity. *)

type expectation =
  | Sent
      (** The invite went out; the host has not heard that the guest installed.
      *)
  | Expected
      (** The host's person recorded hearing from the guest that they installed.
      *)

type state =
  | Open of expectation
  | Joined of { identity_key : string; confirmed : bool }
  | Revoked of { identity_key : string }

(* An invite every admin signed (Approved_invite, DES-85466): the approval it came from, the role the
   guest is invited to, and the email exactly as the admins signed it, its install command and
   expiry still marked. The filled email is rendered from it when it is shown, so the invite key's
   secret half, which the keystore holds, is never written into the ledger. [promotion] is the
   promotion this node filed once an admin invitee's join folded. *)
type approved = {
  approval : string;
  role : string;  (** member or admin *)
  subject : string;
  body : string;
  relay : string;  (** The relay the invite code names. *)
  promotion : string option;
}

type record = {
  dinner_hash : string;
  guest_name : string;
  guest_email : string;
  invite_key : string;
  expires_at : Ptime.t;
  message : string;  (** The host's own lines the invite email opened with. *)
  state : state;
  approved : approved option;
      (** Set on an invite the admins signed; None on a host's own dinner. *)
}

type ledger = record list

let records_of_dinner ~dinner_hash ~message (d : Dinner.t) =
  List.map
    (fun (i : Dinner.invite) ->
      {
        dinner_hash;
        guest_name = i.guest.name;
        guest_email = i.guest.email;
        invite_key = i.invite_key;
        expires_at = i.expires_at;
        message;
        state = Open Sent;
        approved = None;
      })
    d.invites

let update ledger key f =
  List.map (fun r -> if r.invite_key = key then f r else r) ledger

let mark_expected ledger ~invite_key =
  update ledger invite_key (fun r ->
      match r.state with Open _ -> { r with state = Open Expected } | _ -> r)

type option_ = Confirm | Revoke

type ask = {
  key : string;  (** join:<invite key>, one ask per invite. *)
  identity_key : string;  (** The identity the answer confirms or revokes. *)
  title : string;
  context : string;
  options : option_ list;
  recommended : option_;
  default : option_;  (** What happens when the ask lapses unanswered. *)
  lapses_at : Ptime.t;
}

type outcome =
  | Not_ours  (** The join is on an invite this host did not write. *)
  | Shown of record
      (** An expected join: shown in the feed and the digest, nothing asked. *)
  | Asked of record * ask
  | Already_handled of record  (** The same join seen again on another relay. *)

(* An unanswered ask revokes. A revoked guest who really was the guest gets a new invite in a
   minute; a stranger left in the circle reads everything from the join forward, and what was
   read cannot be taken back. *)
let ask_lapse = Ptime.Span.of_int_s (72 * 3600)

(* The device key that wrote the dinner may revoke the identity a join on it admitted for 7 days after
   the join (protocol.md, the revoke body), so an ask raised late still lapses inside that window,
   with a day to spare for a node that was asleep when it lapsed. *)
let device_revoke_window = Ptime.Span.of_int_s (7 * 86400)
let latest_lapse = Ptime.Span.of_int_s (6 * 86400)

let lapses_at ~now ~joined_at =
  let raised = Dinner.expiry ~now ask_lapse
  and cap = Dinner.expiry ~now:joined_at latest_lapse in
  if Ptime.is_later raised ~than:cap then cap else raised

let ask_for ~now ~joined_at r ~identity_key ~why =
  {
    key = "join:" ^ r.invite_key;
    identity_key;
    title =
      Printf.sprintf "Confirm %s joined, or revoke the identity" r.guest_name;
    context =
      Printf.sprintf "%s %s Identity %s." why
        "If you do not answer, the identity is revoked and the guest can be \
         invited again."
        identity_key;
    options = [ Confirm; Revoke ];
    recommended = Revoke;
    default = Revoke;
    lapses_at = lapses_at ~now ~joined_at;
  }

let observe ~now ledger (join : Join.t) =
  match List.find_opt (fun r -> r.invite_key = join.invite_key) ledger with
  | None -> (ledger, Not_ours)
  | Some r -> (
      let joined confirmed =
        {
          r with
          state = Joined { identity_key = join.identity_key; confirmed };
        }
      in
      match r.state with
      | Open Expected ->
          let r' = joined true in
          (update ledger r.invite_key (fun _ -> r'), Shown r')
      | Open Sent ->
          let r' = joined false in
          let why =
            Printf.sprintf
              "Someone joined with %s's invite before you heard they installed."
              r.guest_name
          in
          ( update ledger r.invite_key (fun _ -> r'),
            Asked
              ( r',
                ask_for ~now ~joined_at:join.created_at r'
                  ~identity_key:join.identity_key ~why ) )
      | (Joined { identity_key; _ } | Revoked { identity_key })
        when identity_key = join.identity_key ->
          (ledger, Already_handled r)
      | Joined _ | Revoked _ ->
          (* A second identity on one invite: two relays each accepted a different join. The fold
             keeps one per relay; the host decides which person this is. *)
          let why =
            Printf.sprintf
              "A second identity joined with %s's invite, through another \
               relay."
              r.guest_name
          in
          ( ledger,
            Asked
              ( r,
                ask_for ~now ~joined_at:join.created_at r
                  ~identity_key:join.identity_key ~why ) ))

(* The person's answer, recorded in the ledger. Revoke returns the identity to revoke: the node
   writes that revoke, signed by the host's identity key, which only the phrase derives. *)
let answer ledger ~invite_key ~(identity_key : string) choice =
  match choice with
  | Confirm ->
      ( update ledger invite_key (fun r ->
            { r with state = Joined { identity_key; confirmed = true } }),
        None )
  | Revoke ->
      ( update ledger invite_key (fun r ->
            { r with state = Revoked { identity_key } }),
        Some identity_key )

(* ---- the ask, as the node's ask store keeps it ---- *)

let option_id = function Confirm -> "confirm" | Revoke -> "revoke"

let option_of_id = function
  | "confirm" -> Some Confirm
  | "revoke" -> Some Revoke
  | _ -> None

let option_label = function
  | Confirm -> "Confirm, this is the guest"
  | Revoke -> "Revoke the identity"

let to_store (a : ask) : Digestif_core.Asks.t =
  {
    key = a.key;
    kind = Some "join";
    title = a.title;
    detail = a.context;
    about = Some a.identity_key;
    options =
      List.map
        (fun o ->
          { Digestif_core.Asks.id = option_id o; label = option_label o })
        a.options;
    recommended = option_id a.recommended;
    on_no_answer = option_id a.default;
    lapses_at = Some (Dinner.iso8601 a.lapses_at);
    raised_at = "";
    answer = None;
    answered_at = None;
    envelope = None;
    answered_via = None;
  }

(* The invite key a join ask is about, from its key. *)
let invite_key_of_ask_key key =
  let p = "join:" in
  if String.starts_with ~prefix:p key then
    Some
      (String.sub key (String.length p) (String.length key - String.length p))
  else None

type lapse =
  | Revoke_as_device
      (** Inside the window: the node signs the revoke with the device key that
          wrote the dinner, [by] that key, and appends it with no one at the
          keyboard. *)
  | Needs_phrase
      (** Past the window: the ask stays open and lapsed at the head of the
          digest, and revoking takes the identity key, so the person's answer.
      *)

(* An ask that lapsed unanswered. [now] is when the node acts on it, the revoke's created_at, and
   [joined_at] the join's created_at; the fold judges the window by those two. *)
let lapsed ledger ~invite_key ~identity_key ~now ~joined_at =
  let window_ends = Dinner.expiry ~now:joined_at device_revoke_window in
  if Ptime.is_later now ~than:window_ends then (ledger, Needs_phrase)
  else
    ( update ledger invite_key (fun r ->
          { r with state = Revoked { identity_key } }),
      Revoke_as_device )

(* ---- persistence: the node keeps the ledger beside its log ---- *)

let state_to_json = function
  | Open Sent -> `Assoc [ ("state", `String "sent") ]
  | Open Expected -> `Assoc [ ("state", `String "expected") ]
  | Joined { identity_key; confirmed } ->
      `Assoc
        [
          ("state", `String "joined");
          ("identity_key", `String identity_key);
          ("confirmed", `Bool confirmed);
        ]
  | Revoked { identity_key } ->
      `Assoc
        [ ("state", `String "revoked"); ("identity_key", `String identity_key) ]

(* How far the join watcher has read the log: every join with a local order up to [watched_through]
   was observed, except those in [pending], held back because their invite may be one of the
   records that did not parse. A join past it was stored since, whether or not the ledger could be
   read then, so the next sync that reads the ledger observes it. DIG-324

   It is written onto every record rather than around them, so the file stays the list of records
   an older release reads; a release that saves without it drops it, and the next sync starts the
   cursor at the log's end, past every join that release's own watcher already saw. *)
type cursor = { watched_through : int; pending : string list }

let cursor_fields = function
  | None -> []
  | Some c ->
      [
        ("watched_through", `Int c.watched_through);
        ("pending", `List (List.map (fun h -> `String h) c.pending));
      ]

let record_to_json ?cursor r : Yojson.Safe.t =
  let state = match state_to_json r.state with `Assoc fs -> fs | _ -> [] in
  `Assoc
    ([
       ("dinner", `String r.dinner_hash);
       ("guest_name", `String r.guest_name);
       ("guest_email", `String r.guest_email);
       ("invite_key", `String r.invite_key);
       ("expires_at", `String (Dinner.iso8601 r.expires_at));
       ("message", `String r.message);
     ]
    @ state @ cursor_fields cursor
    @
    match r.approved with
    | None -> []
    | Some a ->
        [
          ( "approved",
            `Assoc
              ([
                 ("approval", `String a.approval);
                 ("role", `String a.role);
                 ("subject", `String a.subject);
                 ("body", `String a.body);
                 ("relay", `String a.relay);
               ]
              @
              match a.promotion with
              | None -> []
              | Some p -> [ ("promotion", `String p) ]) );
        ])

let to_json ?cursor ledger : Yojson.Safe.t =
  `List (List.map (record_to_json ?cursor) ledger)

(* The cursor a record carries; the newest of the records' is the file's. *)
let cursor_of_record_json = function
  | `Assoc fs -> (
      match List.assoc_opt "watched_through" fs with
      | Some (`Int n) ->
          let pending =
            match List.assoc_opt "pending" fs with
            | Some (`List hs) ->
                List.filter_map (function `String h -> Some h | _ -> None) hs
            | _ -> []
          in
          Some { watched_through = n; pending }
      | _ -> None)
  | _ -> None

let newest_cursor items =
  List.fold_left
    (fun acc j ->
      match (acc, cursor_of_record_json j) with
      | None, c -> c
      | Some a, Some c when c.watched_through > a.watched_through -> Some c
      | a, _ -> a)
    None items

let record_of_json j =
  let field k = match j with `Assoc fs -> List.assoc_opt k fs | _ -> None in
  let str k = match field k with Some (`String s) -> Some s | _ -> None in
  let ( let* ) = Option.bind in
  let* dinner_hash = str "dinner" in
  let* guest_name = str "guest_name" in
  let* guest_email = str "guest_email" in
  let* invite_key = str "invite_key" in
  let* expires_at = Option.bind (str "expires_at") Dinner.parse_time in
  (* A ledger written before invites carried the host's lines has none to show. *)
  let message = Option.value (str "message") ~default:"" in
  let* state =
    match (str "state", str "identity_key", field "confirmed") with
    | Some "sent", _, _ -> Some (Open Sent)
    | Some "expected", _, _ -> Some (Open Expected)
    | Some "joined", Some identity_key, Some (`Bool confirmed) ->
        Some (Joined { identity_key; confirmed })
    | Some "revoked", Some identity_key, _ -> Some (Revoked { identity_key })
    | _ -> None
  in
  let* approved =
    match field "approved" with
    | None | Some `Null -> Some None
    | Some a -> (
        let s k =
          match a with
          | `Assoc fs -> (
              match List.assoc_opt k fs with
              | Some (`String v) -> Some v
              | _ -> None)
          | _ -> None
        in
        match (s "approval", s "role", s "subject", s "body", s "relay") with
        | Some approval, Some role, Some subject, Some body, Some relay ->
            Some
              (Some
                 {
                   approval;
                   role;
                   subject;
                   body;
                   relay;
                   promotion = s "promotion";
                 })
        | _ -> None)
  in
  Some
    {
      dinner_hash;
      guest_name;
      guest_email;
      invite_key;
      expires_at;
      message;
      state;
      approved;
    }

(* The records that parse, and every item that does not, exactly as the file holds it. *)
let partition_json = function
  | `List items ->
      Ok
        (List.fold_right
           (fun j (records, unreadable) ->
             match record_of_json j with
             | Some r -> (r :: records, unreadable)
             | None -> (records, j :: unreadable))
           items ([], []))
  | _ -> Error "the ledger is a list"

let of_json j =
  match partition_json j with
  | Ok (records, []) -> Ok records
  | Ok (_, _ :: _) -> Error "a ledger record does not parse"
  | Error e -> Error e

(* The ledger file beside the node's log. A node that never sent an invite has none. *)
let file dir = Filename.concat dir "invites.json"

let read_json dir ~parse =
  let p = file dir in
  if not (Sys.file_exists p) then parse (`List [])
  else
    match Yojson.Safe.from_file p with
    | j -> Result.map_error (fun e -> p ^ ": " ^ e) (parse j)
    | exception (Yojson.Json_error m | Sys_error m) -> Error (p ^ ": " ^ m)

(* The whole ledger, refused when any record does not parse: the commands that change one record
   and save the rest. *)
let load dir = read_json dir ~parse:of_json

(* The ledger as the join watcher reads it on every sync: the records that parse, and the items
   that do not, kept as written so a [save ~keep] writes them back untouched. An Error is a file
   that is not a ledger at all. *)
let load_readable dir = read_json dir ~parse:partition_json

(* What the join watcher reads on every sync: [load_readable]'s records and unreadable items, and
   the cursor the records that parse carry (None on a file no watcher has saved one in). *)
type watch = {
  ledger : ledger;
  keep : Yojson.Safe.t list;
  cursor : cursor option;
}

let load_watch dir =
  read_json dir ~parse:(fun j ->
      Result.map
        (fun (ledger, keep) ->
          let readable =
            match j with
            | `List items ->
                List.filter (fun i -> record_of_json i <> None) items
            | _ -> []
          in
          { ledger; keep; cursor = newest_cursor readable })
        (partition_json j))

(* The cursor in the file now, so a command that changes a record keeps the watcher's. *)
let current_cursor dir =
  match load_watch dir with Ok w -> w.cursor | Error _ -> None

(* Written to a temporary file and renamed over the old one, so a crash leaves one or the other.
   [keep] are items [load_readable] could not read, written back after the records. [cursor] is the
   join watcher's; without it the file's own is kept. *)
let save ?(keep = []) ?cursor dir ledger =
  let p = file dir in
  let tmp = p ^ ".tmp" in
  let cursor =
    match cursor with Some _ -> cursor | None -> current_cursor dir
  in
  let json =
    match to_json ?cursor ledger with `List rs -> `List (rs @ keep) | j -> j
  in
  match
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 tmp
      (fun oc -> Yojson.Safe.pretty_to_channel oc json);
    Sys.rename tmp p
  with
  | () -> Ok ()
  | exception Sys_error m -> Error m
