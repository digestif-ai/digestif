(* The invite flow on a node: the host writes a dinner and keeps its Host_watch ledger beside the
   log, every sync runs the watcher over the joins it stores and raises its asks in the node's ask
   store, and the guest's node reads its dinner and writes its join. *)

open Digestif_core

let ( let* ) = Result.bind
let ptime_now () = Option.get (Ptime.of_float_s (Unix.gettimeofday ()))

(* ---- the host ---- *)

type invited = { dinner_hash : string; dinner : Dinner.t }

(* Write a dinner naming [guests], signed with this node's device key, and record an invite per
   guest in the ledger. [relays] defaults to the node's own; any given are added to the node, so
   the next sync appends the dinner to every one of them. A node with no circle root yet is
   founding a circle, and this dinner is its root. *)
let invite ?(now = ptime_now ()) ?ttl (node : Node.t) ~date ~label ?relays
    guests =
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
  let* dinner = Dinner.create ~host ~date ~label ~relays ~now ?ttl guests in
  List.iter (Log.add_relay node.log) relays;
  let* dinner_hash, _ = Node.write node ~kind:"dinner" (Dinner.body dinner) in
  if Node.root node = None then Node.set_root node dinner_hash;
  let* () =
    Host_watch.save node.dir
      (ledger @ Host_watch.records_of_dinner ~dinner_hash dinner)
  in
  Ok { dinner_hash; dinner }

(* The person heard from a guest that they installed: their join will be shown, not asked about.
   [guest] is the guest's name (as the dinner wrote it, any case) or the invite key. *)
let expect (node : Node.t) ~guest =
  let* ledger = Host_watch.load node.dir in
  let wanted = String.lowercase_ascii (String.trim guest) in
  let open_ =
    List.filter
      (fun (r : Host_watch.record) ->
        (match r.state with Open _ -> true | _ -> false)
        && (r.invite_key = guest || String.lowercase_ascii r.guest_name = wanted))
      ledger
  in
  match open_ with
  | [] -> Error (Printf.sprintf "no open invite for %S" guest)
  | [ r ] ->
      let ledger = Host_watch.mark_expected ledger ~invite_key:r.invite_key in
      let* () = Host_watch.save node.dir ledger in
      Ok r
  | rs ->
      Error
        (Printf.sprintf "%d open invites are for %S; name one by invite key: %s"
           (List.length rs) guest
           (String.concat ", "
              (List.map (fun (r : Host_watch.record) -> r.invite_key) rs)))

(* What the watcher made of a join a sync stored. *)
type seen = { join_hash : string; outcome : Host_watch.outcome }

(* Sync, running Host_watch.observe on every join the sync stores for the first time, on every
   relay: the fold admits one join per invite, and the host still hears of a second one another
   relay accepted. Each ask goes to the ask store, keyed by its invite, so a second identity on one
   invite re-raises the same ask. *)
let sync ?transport ?(now = ptime_now ()) (node : Node.t) =
  let* ledger = Host_watch.load node.dir in
  let ledger = ref ledger and seen = ref [] and failed = ref None in
  let on_stored hash (sg : Envelope.signed) =
    if sg.envelope.kind = "join" && !ledger <> [] then
      match Join.verify sg with
      | Error _ -> ()
      | Ok join ->
          let l, outcome = Host_watch.observe ~now !ledger join in
          ledger := l;
          (match outcome with
          | Host_watch.Asked (_, ask) -> (
              match Asks.raise_ node.log (Host_watch.to_store ask) with
              | Ok () -> ()
              | Error e -> failed := Some e)
          | _ -> ());
          seen := { join_hash = hash; outcome } :: !seen
  in
  let* report = Sync.sync ?transport ~on_stored node in
  let* () = if !seen = [] then Ok () else Host_watch.save node.dir !ledger in
  match !failed with
  | Some e -> Error ("raising a join ask: " ^ e)
  | None -> Ok (report, List.rev !seen)

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

(* Set this machine up from the phrase (device and mail keys, as digestif init does), read the
   dinner through the bootstrap read, write the join and append it to every relay the dinner
   lists, keep it in the log, and add those relays to the node. A relay that took the join now
   admits this device, so the circle root is read from the first one that answers. *)
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

let join ?(transport = Relay_client.curl) ?(now = ptime_now ()) ?agent_name
    (node : Node.t) ~code ~phrase =
  let* derived = Node.init node ~phrase in
  let* device = Node.device_key node in
  let* written =
    Result.map_error Join.error_message
      (Join.write ~transport ~now ~code ~identity:derived.identity ~device)
  in
  let accepted =
    List.filter_map
      (fun (relay, r) -> match r with Ok _ -> Some relay | Error _ -> None)
      written.appended
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
             written.appended))
  else
    let* _ = Node.import node written.join in
    List.iter (Log.add_relay node.log) written.dinner.parsed_relays;
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
    (match own_guest_name written.dinner code with
    | Some name ->
        let agent_name =
          Option.value agent_name ~default:(default_agent_name name)
        in
        ignore (write_card node ~name ~agent_name)
    | None -> ());
    Ok written
