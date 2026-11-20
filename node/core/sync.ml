(* Signed sync (protocol.md, Conformance cases): read every relay from its cursor, verify every
   envelope, keep the union, fold it, find forks, gaps and broken chains, apply retracts, and push to
   each relay every envelope of ours it does not hold. A relay missing a range is backfilled two ways:
   this node reads the range from the relays that have it, and repairs the relay with its own
   envelopes. The one exception is admission: a relay that admits this node takes from it the
   dinners and joins it lacks and the self-authored device messages, which carry their own proof
   (replicate_relay). *)

type relay_report = {
  relay : string;
  fetched : int;
  stored : int;
  pushed : int;
  dropped : int;
      (** own envelopes this relay refused for good, dropped from the log *)
  replicated : int;
      (** other members' joins and self-authored device messages this relay
          lacked and took from this node *)
  error : string option;
}

type report = {
  relays : relay_report list;
  fold : Fold.t;
  raised : Log.fault list;
      (** the faults this sync recorded that are still open *)
  open_faults : int;  (** every open fault, [digestif faults] lists them *)
}

let page_size = 500

(* Keep one envelope a relay served: true when the log did not hold it. An envelope whose hash or
   signature does not check is a fault against its author and is passed over, as is one that has no
   canonical form (a string that is not UTF-8): it can never verify, and nothing it says is read. *)
let store_served ~on_stored (node : Node.t) ~relay (s : Relay_client.stored) =
  let e = s.signed.envelope in
  let fault kind detail =
    Log.add_fault node.log ~kind ~author:e.author ~seq:e.seq ~detail;
    false
  in
  match Envelope.hash_result e with
  | Error m -> fault "invalid_envelope" (relay ^ " " ^ s.hash ^ " " ^ m)
  | Ok hash when hash <> s.hash ->
      fault "relay_hash_mismatch" (relay ^ " " ^ s.hash)
  | Ok hash -> (
      match Envelope.verify s.signed with
      | Error err ->
          fault "invalid_envelope"
            (relay ^ " " ^ hash ^ " " ^ Envelope.error_message err)
      | Ok () ->
          let result = Log.insert node.log ~hash s.signed in
          Log.add_sighting node.log ~relay ~relay_id:s.relay_id ~hash
            ~received_at:s.received_at;
          let inserted = result = Log.Inserted in
          if inserted then on_stored hash s.signed;
          inserted)

(* An entry the relay served that is no envelope at all names no author this node can hold it
   against: the fault is the relay's, keyed by where the relay placed it. *)
let record_malformed (node : Node.t) ~relay (m : Relay_client.malformed) =
  Log.add_fault node.log ~kind:"malformed_entry" ~author:""
    ~seq:(Option.value m.bad_relay_id ~default:0)
    ~detail:
      (String.concat " " ((relay :: Option.to_list m.bad_hash) @ [ m.reason ]))

let fetch_relay ?(on_stored = fun _ _ -> ()) (node : Node.t) transport ~key
    (r : Log.relay_row) =
  let rec loop after fetched stored =
    match
      Relay_client.fetch transport ~base:r.url ~key ~after ~limit:page_size
    with
    | Error e -> (fetched, stored, Some e)
    | Ok page -> (
        (* One page is stored under the write lock, and the next is fetched with it released: a
           relay call can take a minute, and every other connection to the log waits on the lock
           only as long as its busy timeout. ISS-47731 *)
        let stored, last =
          Log.transaction node.log @@ fun () ->
          let stored =
            List.fold_left
              (fun stored s ->
                if store_served ~on_stored node ~relay:r.url s then stored + 1
                else stored)
              stored page.envelopes
          in
          List.iter (record_malformed node ~relay:r.url) page.malformed;
          (* The cursor passes every entry the page placed, a bad one included: an entry this node
             refused is refused on every read, and holding the cursor before it would stop this
             relay's sync for good. DIG-222 *)
          let last =
            List.fold_left max after
              (List.map
                 (fun (s : Relay_client.stored) -> s.relay_id)
                 page.envelopes
              @ List.filter_map
                  (fun (m : Relay_client.malformed) -> m.bad_relay_id)
                  page.malformed)
          in
          Log.set_cursor node.log r.url last;
          (stored, last)
        in
        let served = List.length page.envelopes + List.length page.malformed in
        let fetched = fetched + served in
        match page.next with
        | Some next when next > after && served > 0 ->
            loop (max next last) fetched stored
        | _ -> (fetched, stored, None))
  in
  loop r.cursor 0 0

(* This node's join epoch, the floor below which every relay withholds content from it
   (relay/src/read.ts, page): 0 for a founder, and for a node the fold has not admitted yet. *)
let reader_epoch (node : Node.t) (fold : Fold.t) =
  match
    Option.bind (Log.get_config node.log Node.k_device) (Fold.find fold)
  with
  | Some k -> k.join_epoch
  | None -> 0

(* The first seq of [links] whose envelope is at or past [floor]: below it a missing seq may be
   content written before this node joined, which no relay serves it. An author's chain carries a
   non-decreasing epoch, so every seq above it is at or past the floor and a missing one is a gap. A
   chain wholly below the floor has none, and expects every hole. *)
let first_served ~floor links =
  if floor = 0 then Some 1
  else
    List.fold_left
      (fun m (l : Log.link) ->
        if l.epoch < floor then m
        else match m with Some s when s <= l.seq -> m | _ -> Some l.seq)
      None links

(* The faults one author's chain holds, as (kind, author, seq, detail), and the seqs of its open gap
   faults that are resolved: held now, or below the reader's floor ([first_served]). [links] are the
   author's envelopes in chain order, a revoked key's past its cutoff left out, and [open_gaps] the
   seqs of the author's open gap faults. *)
let chain_faults ~floor ~author ~open_gaps (links : Log.link list) =
  let by_seq = Hashtbl.create 16 in
  List.iter
    (fun (l : Log.link) ->
      Hashtbl.replace by_seq l.seq
        (l :: Option.value (Hashtbl.find_opt by_seq l.seq) ~default:[]))
    links;
  let max_seq = List.fold_left (fun m (l : Log.link) -> max m l.seq) 0 links in
  let served_from =
    Option.value (first_served ~floor links) ~default:(max_seq + 1)
  in
  let resolved =
    List.filter
      (fun seq -> seq < served_from || Hashtbl.mem by_seq seq)
      open_gaps
  in
  let faults = ref [] in
  let fault kind seq detail =
    faults := (kind, author, seq, detail) :: !faults
  in
  for seq = 1 to max_seq do
    match Hashtbl.find_opt by_seq seq with
    | None when seq < served_from -> ()
    | None ->
        if not (List.mem seq open_gaps) then
          fault "gap" seq "missing from every relay"
    | Some ls ->
        (match
           List.sort_uniq compare (List.map (fun (l : Log.link) -> l.hash) ls)
         with
        | _ :: _ :: _ as hashes -> fault "fork" seq (String.concat " " hashes)
        | _ -> ());
        List.iter
          (fun (l : Log.link) ->
            if seq = 1 then (
              if l.prev <> None then
                fault "broken_chain" seq (l.hash ^ " names a prev at seq 1"))
            else
              match (Hashtbl.find_opt by_seq (seq - 1), l.prev) with
              | Some [ p ], Some prev when p.hash <> prev ->
                  fault "broken_chain" seq
                    (l.hash ^ " names prev " ^ prev ^ ", seq "
                    ^ string_of_int (seq - 1)
                    ^ " is " ^ p.hash)
              | Some [ _ ], None ->
                  fault "broken_chain" seq (l.hash ^ " names no prev")
              | _ -> ())
          ls
  done;
  (List.rev !faults, resolved)

(* Forks, gaps and chain breaks, recomputed over the whole log each pass, so a change to the fold (a
   revocation's cutoff, this node's join epoch) is read as soon as it lands. The pass reads only the
   chain columns of each envelope (Log.chains), decodes none, records what it found through one
   prepared statement, and writes a gap's resolution only where an open gap fault is resolved: it
   runs under the sync's write lock, which every other writer waits on. DIG-210 *)
let detect_faults (node : Node.t) (fold : Fold.t) =
  let floor = reader_epoch node fold in
  let open_gaps = Hashtbl.create 16 in
  List.iter
    (fun (f : Log.fault) ->
      Hashtbl.replace open_gaps f.author
        (f.seq :: Option.value (Hashtbl.find_opt open_gaps f.author) ~default:[]))
    (Log.open_faults_of_kind node.log "gap");
  let faults =
    List.concat_map
      (fun (author, links) ->
        if Fold.is_chainless fold author then []
        else
          (* A revoked key's envelopes past its cutoff are not read, so they make no fork. *)
          let links =
            List.filter
              (fun (l : Log.link) ->
                not (Fold.past_cutoff_at fold ~author ~seq:l.seq ~hash:l.hash))
              links
          in
          let open_gaps =
            Option.value (Hashtbl.find_opt open_gaps author) ~default:[]
          in
          let faults, resolved = chain_faults ~floor ~author ~open_gaps links in
          List.iter
            (fun seq -> Log.resolve_faults node.log ~kind:"gap" ~author ~seq)
            (List.sort_uniq compare resolved);
          faults)
      (Log.chains node.log)
  in
  Log.add_faults node.log faults

(* A retract drops its target's body when the same identity wrote both. *)
let apply_retracts (node : Node.t) (fold : Fold.t) =
  List.iter
    (fun (r : Log.row) ->
      match r.signed.body with
      | None -> ()
      | Some body -> (
          match Bodies.parse_retract body with
          | Error _ -> ()
          | Ok target -> (
              match Log.find node.log target with
              | None -> ()
              | Some t when t.retracted_by <> None -> ()
              | Some t ->
                  let ra = Fold.identity_of fold r.signed.envelope.author in
                  let ta = Fold.identity_of fold t.signed.envelope.author in
                  if ra <> None && ra = ta then
                    Log.drop_body node.log ~hash:target ~retracted_by:r.hash
                  else
                    Log.add_fault node.log ~kind:"retract_not_author"
                      ~author:r.signed.envelope.author
                      ~seq:r.signed.envelope.seq
                      ~detail:(r.hash ^ " targets " ^ target))))
    (Log.of_kind node.log "retract")

(* The codes a relay refuses an envelope with that it would refuse again however often it is sent
   (spec/digestif-relay.json, the append's 422). A fork is surfaced as a fault instead, a request
   refusal (401) is about the signer and not the envelope, and a rate limit lifts. *)
let permanent_codes =
  [
    "not_admitted";
    "malformed";
    "bad_signature";
    "sequence_regression";
    "too_large";
    "wrong_circle";
    "retract_not_author";
  ]

let permanently_refused = function
  | Relay_client.Refused (422, errs) ->
      (not (List.mem_assoc "fork" errs))
      && List.exists (fun (c, _) -> List.mem c permanent_codes) errs
  | _ -> false

type push = { pushed : int; dropped : int; error : string option }

(* Whether [row] is a device message admitting a key the circle already admits: dropping it loses
   nothing, so its dropped_own fault is resolved as it is raised. Every other drop loses what the
   envelope carried (a digest, a note), so its fault stays open for `digestif faults` to show.
   DIG-202 *)
let readmits (node : Node.t) (row : Log.row) =
  row.signed.envelope.kind = "device"
  &&
  match Option.map Bodies.parse_device row.signed.body with
  | Some (Ok d) -> Fold.find (Node.fold node) d.key <> None
  | _ -> false

(* The request signer of an own envelope: none for a bootstrap, else its author's own key, the mail
   key for an answer or decision the mail key wrote. A relay takes a non-join only from its author
   (relay/src/append.ts), so the device key signing a mail key's envelope is refused 401. *)
let signer (node : Node.t) (row : Log.row) =
  if Envelope.is_bootstrap row.signed then Ok None
  else
    Node.own_signing_key node row.signed.envelope.author
    |> Result.map Option.some

(* Push our own envelopes each relay lacks, in chain order. An own envelope this relay refused for
   good is dropped and the rest of its chain re-signed after the last envelope before it
   (Node.drop_refused, protocol.md "A refused envelope never existed"), then the push goes on from
   the re-signed one, so one refusal never holds back what came after it. A drop is made only on a
   relay that read this node as admitted ([may_drop]): a relay that does not know this node yet
   refuses what it cannot fold, and that says nothing about the envelope. *)
let push_relay ?(may_drop = true) (node : Node.t) transport (r : Log.relay_row)
    =
  let unpushed () =
    List.concat_map
      (fun author -> Log.unheld_by node.log ~relay:r.url author)
      (Node.own_keys node)
  in
  let rec go pushed dropped = function
    | [] -> { pushed; dropped; error = None }
    | (row : Log.row) :: rest -> (
        match signer node row with
        | Error why -> { pushed; dropped; error = Some why }
        | Ok key -> append pushed dropped row rest key)
  and append pushed dropped row rest key =
    match Relay_client.append transport ~base:r.url ~key row.signed with
    | Ok receipt ->
        Log.add_sighting node.log ~relay:r.url ~relay_id:receipt.relay_id
          ~hash:row.hash ~received_at:None;
        go (if receipt.duplicate then pushed else pushed + 1) dropped rest
    | Error (Relay_client.Refused (_, errs)) when List.mem_assoc "fork" errs ->
        Log.add_fault node.log ~kind:"fork" ~author:row.signed.envelope.author
          ~seq:row.signed.envelope.seq
          ~detail:(r.url ^ " refused " ^ row.hash ^ " as a fork");
        go pushed dropped rest
    | Error e when may_drop && permanently_refused e -> (
        let redundant = readmits node row in
        match Node.drop_refused node row with
        | Ok _ ->
            Log.add_fault node.log ~kind:"dropped_own"
              ~author:row.signed.envelope.author ~seq:row.signed.envelope.seq
              ~detail:
                (r.url ^ " refused " ^ row.hash ^ ": "
                ^ Relay_client.error_to_string e);
            if redundant then
              Log.resolve_faults node.log ~kind:"dropped_own"
                ~author:row.signed.envelope.author ~seq:row.signed.envelope.seq;
            go pushed (dropped + 1) (unpushed ())
        | Error why ->
            {
              pushed;
              dropped;
              error =
                Some
                  (Relay_client.error_to_string e
                  ^ " (kept " ^ row.hash ^ ": " ^ why ^ ")");
            })
    | Error e ->
        { pushed; dropped; error = Some (Relay_client.error_to_string e) }
  in
  go 0 0 (unpushed ())

(* A relay that refused the read because this node is not admitted there, then took a push of ours:
   the push was the bootstrap (a circle root, a replacement laptop's device message) that admits
   it, so the read is worth making again in the same sync. *)
let bootstrapped error pushed push_error =
  match (error, push_error) with
  | Some e, None ->
      pushed > 0 && List.mem "not_admitted" (Relay_client.error_codes e)
  | _ -> false

(* The envelopes of other members that admit someone, which this node holds, its fold applied, and
   [r] never returned (protocol.md, The admission fold): every dinner, then every join, then every
   self-authored device message, each in fold order (created_at, hash), so a join reaches the relay
   after the dinner it names and a device message after the join that admitted its identity. A
   dinner is its host device's own envelope, but a host whose node never syncs [r] (a retired
   laptop, a host who left) never pushes it, and [r] would refuse every join naming it. A second relay seeded after an invite window closed gets its
   members this way, since the guest's own late join is judged at that relay's clock and refused. A
   device message another device of the identity wrote is not here: a relay takes it only from its
   author, whose node pushes it as its own once the join has admitted that device. *)
let replicas ?(now = Unix.gettimeofday ()) (node : Node.t) (r : Log.relay_row) =
  let own = Node.own_keys node in
  let lacks (row : Log.row) =
    (not (List.mem row.signed.envelope.author own))
    && (not (Log.held_by node.log ~relay:r.url row.hash))
    &&
    match Log.replica_refusal node.log ~relay:r.url row.hash with
    | Some (_, retry_at) -> now >= retry_at
    | None -> true
  in
  let dinners =
    List.filter lacks
      (Log.of_kind node.log "circle" @ Log.of_kind node.log "dinner")
  in
  let joins = List.filter lacks (Log.of_kind node.log "join") in
  let devices =
    List.filter
      (fun (row : Log.row) -> lacks row && Envelope.is_bootstrap row.signed)
      (Log.of_kind node.log "device")
  in
  if dinners = [] && joins = [] && devices = [] then []
  else
    let fold = Node.fold node in
    let applied = Hashtbl.create 64 in
    List.iter (fun h -> Hashtbl.replace applied h ()) fold.applied;
    let in_fold_order rows =
      List.filter (fun (row : Log.row) -> Hashtbl.mem applied row.hash) rows
      |> List.sort (fun (a : Log.row) (b : Log.row) ->
          compare
            (a.signed.envelope.created_at, a.hash)
            (b.signed.envelope.created_at, b.hash))
    in
    in_fold_order dinners @ in_fold_order joins @ in_fold_order devices

(* How long a replica a relay refused [refusals] times waits before it is posted again: ten minutes,
   doubling with each refusal, never more than a day. A refusal can lift (the dinner a join names
   reaches the relay from its host), so it is retried, but never on every sync. *)
let replica_backoff refusals =
  Float.min 86_400. (600. *. (2. ** float_of_int (max 0 (refusals - 1))))

(* Push [replicas] to a relay that admits this node. A join goes with this node's device key as the
   request signer, the one envelope a relay takes from a signer other than its author, and is judged
   there by its created_at; a dinner and a self-authored device message go unsigned, as their
   author's bootstrap would, so the relay judges each against its author's chain there (a dinner
   behind a later envelope of its host device is a sequence_regression). A refusal is a replicate_refused fault naming the relay's reason, and the loop goes on: the
   envelope is someone else's, so it is never dropped. A transport failure ends the pass; the next
   sync tries again. *)
let replicate_relay ?(now = Unix.gettimeofday ()) (node : Node.t) transport ~key
    (r : Log.relay_row) =
  let rec go replicated = function
    | [] -> replicated
    | (row : Log.row) :: rest -> (
        let e = row.signed.envelope in
        let signer = if e.kind = "join" then Some key else None in
        match
          Relay_client.append transport ~base:r.url ~key:signer row.signed
        with
        | Ok receipt ->
            Log.add_sighting node.log ~relay:r.url ~relay_id:receipt.relay_id
              ~hash:row.hash ~received_at:None;
            Log.resolve_relay_faults node.log ~kind:"replicate_refused"
              ~author:e.author ~seq:e.seq ~relay:r.url;
            Log.clear_replica_refusal node.log ~relay:r.url row.hash;
            go (if receipt.duplicate then replicated else replicated + 1) rest
        | Error (Relay_client.Transport _) -> replicated
        | Error err ->
            Log.add_fault node.log ~kind:"replicate_refused" ~author:e.author
              ~seq:e.seq
              ~detail:
                (r.url ^ " refused the " ^ e.kind ^ " " ^ row.hash ^ ": "
                ^ Relay_client.error_to_string err);
            let refusals =
              1
              + Option.fold ~none:0 ~some:fst
                  (Log.replica_refusal node.log ~relay:r.url row.hash)
            in
            Log.record_replica_refusal node.log ~relay:r.url ~hash:row.hash
              ~refusals
              ~retry_at:(now +. replica_backoff refusals);
            go replicated rest)
  in
  go 0 (replicas ~now node r)

(* Read, then push, then read again a relay the push admitted this node to. The second value says
   whether the relay read clean, so admits this node and may be replicated to (replicate_relays). *)
let sync_relay ?on_stored (node : Node.t) transport ~key (r : Log.relay_row) =
  let fetched, stored, error = fetch_relay ?on_stored node transport ~key r in
  (* A relay that refused the read (this node not admitted there yet) still takes our appends:
     a circle root, or a replacement laptop's device message, reaches it unsigned this way. *)
  let { pushed; dropped; error = push_error } =
    match error with
    | Some (Relay_client.Transport _) ->
        { pushed = 0; dropped = 0; error = None }
    | _ -> push_relay ~may_drop:(error = None) node transport r
  in
  let fetched, stored, error =
    if bootstrapped error pushed push_error then
      let f, s, e = fetch_relay ?on_stored node transport ~key r in
      (fetched + f, stored + s, e)
    else (fetched, stored, error)
  in
  let read_clean = error = None in
  let error =
    match (error, push_error) with
    | Some e, _ -> Some (Relay_client.error_to_string e)
    | None, e -> e
  in
  Log.record_sync node.log r.url error;
  ( { relay = r.url; fetched; stored; pushed; dropped; replicated = 0; error },
    read_clean )

(* Replicate to every relay that read clean what admits other members there. It runs once every
   relay has been read, so a join this node learns from one relay reaches every other relay in the
   same sync, whatever order the relays are read in. *)
let replicate_relays (node : Node.t) transport ~key relays synced =
  List.map2
    (fun (r : Log.relay_row) (report, read_clean) ->
      if read_clean then
        { report with replicated = replicate_relay node transport ~key r }
      else report)
    relays synced

(* A member who runs a relay publishes a relay message, and every node adds it (design.md, Two
   relays to start). Each relay message the fold applied, so written by an admitted member, adds its
   URL once: a relay this node removed stays removed until a new relay message names it. A URL that
   is not a public https relay (Relay_url) is a fault, never a relay. *)
let adopt_relays (node : Node.t) (fold : Fold.t) =
  let applied = Hashtbl.create 64 in
  List.iter (fun h -> Hashtbl.replace applied h ()) fold.applied;
  List.iter
    (fun (row : Log.row) ->
      if
        Hashtbl.mem applied row.hash
        && not (Log.relay_message_adopted node.log row.hash)
      then
        match Option.map Bodies.parse_relay row.signed.body with
        | Some (Ok r) when Relay_url.from_circle r.url ->
            Log.adopt_relay_message node.log ~hash:row.hash r.url
        | Some (Ok r) ->
            Log.add_fault node.log ~kind:"unsafe_relay"
              ~author:row.signed.envelope.author ~seq:row.signed.envelope.seq
              ~detail:
                (row.hash ^ " names " ^ r.url
               ^ ", which is not a public https relay")
        | _ -> ())
    (Log.of_kind node.log "relay")

(* [on_stored] sees each envelope the first time this node stores it, after verification: the hook a
   handler for a kind the core does not fold (a release revocation, a sealed message) attaches to. *)
let sync ?(transport = Relay_client.curl) ?on_stored (node : Node.t) =
  match Node.device_key node with
  | Error e -> Error e
  | Ok key ->
      let relays = Log.relays node.log in
      let mark = Log.last_fault_id node.log in
      let synced =
        List.map (sync_relay ?on_stored node transport ~key) relays
      in
      let reports = replicate_relays node transport ~key relays synced in
      let fold = Node.fold node in
      Log.transaction node.log (fun () ->
          detect_faults node fold;
          apply_retracts node fold;
          adopt_relays node fold);
      Ok
        {
          relays = reports;
          fold;
          raised = Log.open_faults_after node.log mark;
          open_faults = Log.open_fault_count node.log;
        }
