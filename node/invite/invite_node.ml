(* The invite flow on a node: the founder writes the circle's root, listing its first guests, and
   keeps its Host_watch ledger beside the log, every sync runs the watcher over the joins it stores and raises its asks in the node's ask
   store, and the guest's node reads its dinner and writes its join. *)

open Digestif_core

let ( let* ) = Result.bind
let ptime_now () = Option.get (Ptime.of_float_s (Unix.gettimeofday ()))

(* ---- the host ---- *)

type invited = {
  dinner_hash : string;
      (** The envelope that lists the invites: here, the circle's root. *)
  dinner : Dinner.t;
  message : string;  (** The host's lines every guest's email opens with. *)
}

(* Found a circle on this node (protocol.md, circle): sign its root, a circle envelope naming it
   [name] with this node's identity as founder and listing [guests] (who may be none), with this
   node's device key, make it the node's root, and record an invite per guest in the ledger with the
   founder's [message], the lines its email opens with. A blank message is refused before anything
   is written when there is a guest to send it to. [relays] defaults to the node's own; any given
   are added to the node unless [add_relays] is false, so the next sync appends the root to every
   one of them. No dinner is
   involved: a dinner is an event inside a circle, never its root.
   [admins], the founder's admin key, are the circle's own signer set: they, and not the release
   signers, sign every later invite (protocol.md, circle). A circle with none is refused before
   anything is written, since a root without admins is malformed. DIG-277

   A node holds one circle. A node that already has a root is refused: a second circle is a second
   node, with its own data directory, keys, identity and relays (docs/design.md, Circles). *)
let found ?(now = ptime_now ()) ?ttl ?(add_relays = true) ~admins
    (node : Node.t) ~name ?relays ?(message = "") guests =
  let* () =
    if admins = [] then
      Error "a circle names its admins: the founder's admin key at least"
    else Ok ()
  in
  let* () =
    match Node.root node with
    | None -> Ok ()
    | Some root ->
        let id = match Circles.id_of_name name with "" -> "<id>" | id -> id in
        Error
          (Printf.sprintf
             "this node already holds the circle rooted at %s, and a node \
              holds one circle; found the new one from its own node under \
              ~/digestif: digestif --circle %s init, then digestif --circle %s \
              circle found"
             root id id)
  in
  let* message =
    if guests = [] then Ok (String.trim message)
    else Invite_email.message_of_string message
  in
  let* host =
    match Log.get_config node.log Node.k_identity with
    | Some h -> Ok h
    | None -> Error "this node has no identity; run digestif init"
  in
  let relays =
    match relays with
    | Some (_ :: _ as rs) -> rs
    | _ -> List.map (fun (r : Log.relay_row) -> r.url) (Log.relays node.log)
  in
  let* ledger = Host_watch.load node.dir in
  let* root = Dinner.create_circle ~host ~name ~relays ~now ?ttl guests in
  (* A founding against relays that host many circles stores each circle address once a relay hosts
     it (Founding), never the base urls the root lists. *)
  if add_relays then List.iter (Log.add_relay node.log) relays;
  let* root_hash, _ =
    Node.write node ~kind:"circle" (Dinner.circle_body ~admins root)
  in
  Node.set_root node root_hash;
  let* () =
    Host_watch.save node.dir
      (ledger
      @ Host_watch.records_of_dinner ~dinner_hash:root_hash ~message root)
  in
  Ok { dinner_hash = root_hash; dinner = root; message }

(* What the watcher made of a join a sync stored. *)
type seen = { join_hash : string; outcome : Host_watch.outcome }

(* What a sync's join watcher could not do: read the ledger, save it, or raise an ask. The sync
   ran regardless; each says what was skipped. *)
type watch_problem =
  | Unreadable_records of int
      (** Records in invites.json that do not parse: skipped, and kept in the
          file as written. *)
  | Unreadable_ledger of string
      (** invites.json is not a ledger: no join was watched and the file was
          left alone. The joins stored meanwhile are watched by the first sync
          that reads it again. *)
  | Not_saved of string  (** The ledger the joins changed was not written. *)
  | Ask_not_raised of string  (** A join ask the store refused. *)
  | Not_settled of string
      (** A first-join ask an earlier release raised that was not confirmed. *)

let watch_problem_to_string = function
  | Unreadable_records n ->
      Printf.sprintf
        "%d record%s in invites.json do%s not parse: skipped, and kept in the \
         file as written"
        n
        (if n = 1 then "" else "s")
        (if n = 1 then "es" else "")
  | Unreadable_ledger e ->
      "invites.json was not read, so no join was watched this sync (they are \
       watched once it reads again): " ^ e
  | Not_saved e -> "the invite ledger was not saved: " ^ e
  | Ask_not_raised e -> "a join ask was not raised: " ^ e
  | Not_settled e ->
      "an earlier release's first-join ask was not confirmed: " ^ e

(* Whether a join on [invite_key] may be on one of [keep], the ledger items that did not parse: one
   naming that invite key, or one naming none that can be read. *)
let may_be_kept keep invite_key =
  List.exists
    (function
      | `Assoc fs -> (
          match List.assoc_opt "invite_key" fs with
          | Some (`String k) -> k = invite_key
          | _ -> true)
      | _ -> true)
    keep

(* Observe, in the order this node stored them, the joins the watcher has not: every join past the
   cursor ([start], the log's end before this sync stored anything, on a ledger no watcher saved a
   cursor in), every join the cursor holds pending, and every join on an invite the ledger still
   has Open (DIG-292: an Open invite with a join in the log is one whose join was missed, since
   observing it moves it out of Open; this reaches joins stored before the ledger carried a
   cursor). A join on an invite no readable record names that may be one of the records that did
   not parse is held pending rather than called someone else's, and observed once its record
   reads. The log is read whole only when something is pending or an invite is Open. DIG-324 *)
let watch_joins ~now ~start (node : Node.t) (w : Host_watch.watch) ~watch =
  let after, pending =
    match w.cursor with
    | Some c -> (c.watched_through, c.pending)
    | None -> (start, [])
  in
  let ledger = ref w.ledger in
  let is_open key =
    List.exists
      (fun (r : Host_watch.record) ->
        r.invite_key = key && r.state = Host_watch.Open)
      !ledger
  in
  let ours key =
    List.exists (fun (r : Host_watch.record) -> r.invite_key = key) !ledger
  in
  let rows =
    if
      pending = []
      && not
           (List.exists
              (fun (r : Host_watch.record) -> is_open r.invite_key)
              w.ledger)
    then Log.of_kind_after node.log "join" ~after
    else Log.of_kind node.log "join"
  in
  let through = ref after and held = ref [] in
  List.iter
    (fun (row : Log.row) ->
      through := max !through row.local_order;
      match (row.retracted_by, Join.verify row.signed) with
      | None, Ok (join : Join.t) ->
          let fresh = row.local_order > after || List.mem row.hash pending in
          if fresh || is_open join.invite_key then
            if
              (not (ours join.invite_key)) && may_be_kept w.keep join.invite_key
            then held := row.hash :: !held
            else ledger := watch ~now !ledger row.hash join
      | _ -> ())
    rows;
  (!ledger, { Host_watch.watched_through = !through; pending = List.rev !held })

(* Confirm every open ask an earlier release raised on the first join of an open invite
   (Host_watch.first_join_ask), which this release shows instead of asking about: the ledger
   records the identity confirmed and the ask is answered confirm, by rule. A ledger that does not
   read whole is left alone, the watcher having reported it. DIG-421 *)
let settle_first_join_asks (node : Node.t) ~problem =
  match Host_watch.load node.dir with
  | Error _ -> ()
  | Ok ledger -> (
      let asks =
        List.filter (Host_watch.first_join_ask ledger) (Asks.list node.log)
      in
      if asks <> [] then
        let ledger =
          List.fold_left
            (fun ledger (a : Asks.t) ->
              match (Host_watch.invite_key_of_ask_key a.key, a.about) with
              | Some invite_key, Some identity_key ->
                  fst
                    (Host_watch.answer ledger ~invite_key ~identity_key
                       Host_watch.Confirm)
              | _ -> ledger)
            ledger asks
        in
        match Host_watch.save node.dir ledger with
        | Error e -> problem (Not_settled e)
        | Ok () ->
            List.iter
              (fun (a : Asks.t) ->
                match
                  Asks.record_answer node.log ~via:Asks.Rule ~key:a.key
                    (Host_watch.option_id Host_watch.Confirm)
                with
                | Ok () -> ()
                | Error e -> problem (Not_settled e))
              asks)

(* Sync, then run Host_watch.observe on every join the watcher has not observed (watch_joins): the
   fold admits one join per invite, and the host still hears of a second one another relay
   accepted. Each ask goes to the ask store, keyed by its invite, so a second identity on one invite
   re-raises the same ask. The ledger is the watcher's, never the sync's: a record that does not
   parse is skipped and kept, a ledger that cannot be read at all is left alone, and either is
   returned as a watch problem beside the sync's own report. The result is an Error only when the
   sync itself failed. DIG-224

   The joins are read from the log after the sync rather than as it stores them, against the cursor
   saved with the ledger, so a join stored while the ledger could not be read, or on an invite whose
   record did not parse, is observed by the first sync that reads it, a second identity on an invite
   already Joined or Revoked included. While no record parses the cursor is kept in the log's
   config table instead, and moves back onto the records once one reads. DIG-292 DIG-324 DIG-329 *)
let sync ?transport ?(now = ptime_now ()) (node : Node.t) =
  let problems = ref [] in
  let problem p = problems := p :: !problems in
  let watched =
    match Host_watch.load_watch ~log:node.log node.dir with
    | Ok w ->
        if w.keep <> [] then problem (Unreadable_records (List.length w.keep));
        Some w
    | Error e ->
        problem (Unreadable_ledger e);
        None
  in
  let start = Log.last_local_order node.log in
  let synced = Sync.sync ?transport node in
  let seen = ref [] in
  let watch ~now ledger hash (join : Join.t) =
    let l, outcome = Host_watch.observe ~now ledger join in
    (match outcome with
    | Host_watch.Asked (_, ask) -> (
        match Asks.raise_ node.log (Host_watch.to_store ask) with
        | Ok () -> ()
        | Error e -> problem (Ask_not_raised e))
    | _ -> ());
    seen := { join_hash = hash; outcome } :: !seen;
    l
  in
  (match watched with
  | Some w when w.ledger <> [] || w.keep <> [] -> (
      let ledger, cursor = watch_joins ~now ~start node w ~watch in
      if ledger = [] then (
        if
          (* No record parses, so none can carry the cursor (and no join changed one): the log's
           config table keeps it until a record reads again. DIG-329 *)
          w.cursor <> Some cursor
        then Host_watch.set_config_cursor node.log cursor)
      else if
        !seen <> [] || w.cursor <> Some cursor
        || Host_watch.config_cursor node.log <> None
      then
        match Host_watch.save ~keep:w.keep ~cursor node.dir ledger with
        | Ok () -> Host_watch.unset_config_cursor node.log
        | Error e -> problem (Not_saved e))
  | _ -> ());
  settle_first_join_asks node ~problem;
  let* report = synced in
  Ok (report, List.rev !seen, List.rev !problems)

(* An answer to a join ask: the person's, or one the daily pass settled from a decision or a lapse
   ([via]). Revoke asks [identity] for the key that signs the revoke (called only then): the
   identity key the phrase derives, or the device key that wrote the dinner, inside its revoke
   window. It writes the revoke as the next envelope of this device's chain for the next sync to
   push, and returns its hash. *)
let answer ?via ?answered_at (node : Node.t) ~key ~choice ~identity =
  let* ask =
    match Asks.find node.log key with
    | Some a -> Ok a
    | None -> Error ("no ask " ^ key)
  in
  let* invite_key =
    match Host_watch.invite_key_of_ask_key key with
    | Some k -> Ok k
    | None -> Error (key ^ " is not a join ask")
  in
  let* identity_key =
    match ask.about with
    | Some k -> Ok k
    | None -> Error (key ^ " names no identity")
  in
  let* option_ =
    match Host_watch.option_of_id choice with
    | Some o -> Ok o
    | None -> Error (Printf.sprintf "answer %s with confirm or revoke" key)
  in
  let* ledger = Host_watch.load node.dir in
  let ledger, revoke =
    Host_watch.answer ledger ~invite_key ~identity_key option_
  in
  let* hash =
    match revoke with
    | None -> Ok None
    | Some target ->
        let* by = identity () in
        let* body = Node.revoke_body node ~by ~target in
        let* hash, _ = Node.write node ~kind:"revoke" body in
        Ok (Some hash)
  in
  let* () = Host_watch.save node.dir ledger in
  let* () = Asks.record_answer node.log ?answered_at ?via ~key choice in
  Ok hash

(* What a lapsed join ask came to (Host_watch.lapsed). *)
type lapse =
  | Revoked of string
      (** the revoke the device key signed, for the next sync *)
  | Needs_phrase
      (** past the device key's window, or this device did not write the dinner:
          the ask stays open and lapsed until the person answers it with the
          phrase *)

let to_ptime f = Option.get (Ptime.of_float_s f)

(* A join ask that lapsed with no decision, acted on at [now]: inside the window the device key that
   wrote the dinner signs the revoke itself, by that key, writes it as the next envelope of this
   device's chain for the next sync to append to every relay, saves the ledger and records the
   lapse. Past it the ask stays open. *)
let lapsed ?answered_at (node : Node.t) (fold : Fold.t) ~now ~key =
  let* ask =
    match Asks.find node.log key with
    | Some a -> Ok a
    | None -> Error ("no ask " ^ key)
  in
  let* invite_key =
    match Host_watch.invite_key_of_ask_key key with
    | Some k -> Ok k
    | None -> Error (key ^ " is not a join ask")
  in
  let* identity_key =
    match ask.about with
    | Some k -> Ok k
    | None -> Error (key ^ " names no identity")
  in
  let* dinner, joined_at =
    match Hashtbl.find_opt fold.joins identity_key with
    | Some j -> Ok j
    | None -> Error ("no join admitted " ^ identity_key)
  in
  let* device = Node.device_key node in
  let* ledger = Host_watch.load node.dir in
  match
    Host_watch.lapsed ledger ~invite_key ~identity_key ~now:(to_ptime now)
      ~joined_at:(to_ptime joined_at)
  with
  | _, Host_watch.Needs_phrase -> Ok Needs_phrase
  | _, Revoke_as_device
    when Hashtbl.find_opt fold.dinner_authors dinner
         <> Some (Keys.public device) ->
      Ok Needs_phrase
  | ledger, Revoke_as_device ->
      let* body = Node.revoke_body node ~by:device ~target:identity_key in
      let* hash, _ = Node.write node ~kind:"revoke" body in
      let* () = Host_watch.save node.dir ledger in
      let* () =
        Asks.record_answer node.log ?answered_at ~via:Asks.Lapse ~key
          (Host_watch.option_id Host_watch.Revoke)
      in
      Ok (Revoked hash)

(* ---- the guest ---- *)

(* The name the host gave this guest beside their invite key in the dinner. *)
let own_guest_name (d : Dinner.parsed) code =
  Option.map
    (fun (g : Dinner.listed_guest) -> g.listed_name)
    (Dinner.find_guest d (Invite_code.invite_public_key code))

(* "Roman's agent" for Roman Cherkasov, until the member names it with `digestif card`. *)
let default_agent_name name =
  let first =
    match String.index_opt name ' ' with
    | Some i -> String.sub name 0 i
    | None -> name
  in
  first ^ "'s agent"

(* The member's first card: the name the host gave them and their agent's name, so the circle
   reads a name rather than a key from the join on. `digestif card` replaces it. *)
let write_card (node : Node.t) ~name ~agent_name =
  let* enc = Node.encryption_key node in
  let body =
    Bodies.make_card ~name ~agent_name
      ~encryption_key:(Keys.encryption_public enc)
  in
  Result.map fst (Node.write node ~kind:"card" body)

(* Sign the join and keep it beside the log before anything is posted: set this machine up from the
   phrase (device and mail keys, as digestif init does), read the dinner through the bootstrap read,
   check it names this invite unexpired, and store the signed join (Join_store). Nothing is spent:
   the invite is spent only when a relay takes the join, which [post] does. A machine that holds no
   join yet and never joined starts clean, so a phrase shown in a run that stopped before this point
   does not hold the node. *)
let prepare ?(transport = Relay_client.curl) ?(now = ptime_now ())
    (node : Node.t) ~code ~phrase =
  let* stored = Join_store.load node.dir in
  let* () =
    match stored with
    | Some s when s.invite_key = Invite_code.invite_public_key code ->
        Error
          "this machine already holds a signed join for this invite; run \
           digestif setup to post it"
    | Some _ ->
        Error
          "this machine already holds a join for another invite; run digestif \
           setup to finish it"
    | None -> Ok ()
  in
  if Node.root node = None then
    Log.exec node.log "DELETE FROM config WHERE key = ?"
      [ Log.s Node.k_identity ];
  let* derived = Node.init node ~phrase in
  let* device = Node.device_key node in
  let* sg, circle =
    Result.map_error Join.error_message (Join.read_dinner ~transport code)
  in
  let* dinner_hash, dinner, _ =
    Result.map_error Join.error_message (Join.check_dinner ~now ~code sg)
  in
  let join =
    Join.envelope ~now ~code
      (Join.body ~dinner_hash ~code ~identity:derived.identity ~device)
  in
  let stored =
    {
      Join_store.invite_key = Invite_code.invite_public_key code;
      dinner_hash;
      relays = Join.relays_at ~circle dinner.parsed_relays;
      guest_name = own_guest_name dinner code;
      join;
      posted = false;
    }
  in
  let* () = Join_store.save node.dir stored in
  Ok stored

type posted = {
  dinner_hash : string;
  join : Envelope.signed;
  appended : (string * (Relay_client.receipt, Relay_client.error) result) list;
      (** Each relay the dinner lists, and what it answered the join's append.
      *)
}

(* Post a stored join: a bootstrap append (no Digestif-Key; the join's signatures are the proof) to
   every relay the dinner lists, the same envelope on every run, so a re-run is a duplicate append
   the relay takes as the same one. A relay that took it admits this device, so the circle root is
   read from the first one that answers, and the member's first card is written once. *)
let post ?(transport = Relay_client.curl) ?agent_name (node : Node.t)
    (stored : Join_store.t) =
  let appended =
    List.map
      (fun relay ->
        (relay, Relay_client.append transport ~base:relay ~key:None stored.join))
      stored.relays
  in
  let accepted =
    List.filter_map
      (fun (relay, r) -> match r with Ok _ -> Some relay | Error _ -> None)
      appended
  in
  if accepted = [] then
    Error
      ("no relay took the join: "
      ^ String.concat "; "
          (List.map
             (fun (relay, r) ->
               match r with
               | Ok _ -> relay
               | Error e -> relay ^ " " ^ Relay_client.error_to_string e)
             appended))
  else
    let* device = Node.device_key node in
    let* _ = Node.import node stored.join in
    List.iter (Log.add_relay node.log) stored.relays;
    List.iter
      (fun relay ->
        if Node.root node = None then
          match Relay_client.circle transport ~base:relay ~key:device with
          | Ok (`Assoc f) -> (
              match List.assoc_opt "root" f with
              | Some (`String r) -> Node.set_root node r
              | _ -> ())
          | _ -> ())
      accepted;
    (match stored.guest_name with
    | Some name when not stored.posted ->
        let agent_name =
          Option.value agent_name ~default:(default_agent_name name)
        in
        ignore (write_card node ~name ~agent_name)
    | _ -> ());
    let* () =
      if stored.posted then Ok ()
      else Join_store.save node.dir { stored with posted = true }
    in
    Ok { dinner_hash = stored.dinner_hash; join = stored.join; appended }

(* The whole guest act in one call: prepare, then post. *)
let join ?transport ?now ?agent_name (node : Node.t) ~code ~phrase =
  let* stored = prepare ?transport ?now node ~code ~phrase in
  post ?transport ?agent_name node stored
