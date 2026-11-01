(* Signed sync (protocol.md, Conformance cases): read every relay from its cursor, verify every
   envelope, keep the union, fold it, find forks, gaps and broken chains, apply retracts, and push to
   each relay every envelope of ours it does not hold. A relay missing a range is backfilled two ways:
   this node reads the range from the relays that have it, and repairs the relay with its own
   envelopes. Nodes cannot repair a relay with another author's envelopes, because a relay accepts an
   append only from the envelope's author. *)

type relay_report = {
  relay : string;
  fetched : int;
  stored : int;
  pushed : int;
  error : string option;
}

type report = {
  relays : relay_report list;
  fold : Fold.t;
  faults : Log.fault list;
}

let page_size = 500

let fetch_relay ?(on_stored = fun _ _ -> ()) (node : Node.t) transport ~key
    (r : Log.relay_row) =
  let rec loop after fetched stored =
    match
      Relay_client.fetch transport ~base:r.url ~key ~after ~limit:page_size
    with
    | Error e -> (fetched, stored, Some e)
    | Ok page -> (
        let stored =
          List.fold_left
            (fun stored (s : Relay_client.stored) ->
              let hash = Envelope.hash s.signed.envelope in
              if hash <> s.hash then begin
                Log.add_fault node.log ~kind:"relay_hash_mismatch"
                  ~author:s.signed.envelope.author ~seq:s.signed.envelope.seq
                  ~detail:(r.url ^ " " ^ s.hash);
                stored
              end
              else
                match Envelope.verify s.signed with
                | Error e ->
                    Log.add_fault node.log ~kind:"invalid_envelope"
                      ~author:s.signed.envelope.author
                      ~seq:s.signed.envelope.seq
                      ~detail:
                        (r.url ^ " " ^ hash ^ " " ^ Envelope.error_message e);
                    stored
                | Ok () ->
                    let result = Log.insert node.log ~hash s.signed in
                    Log.add_sighting node.log ~relay:r.url ~relay_id:s.relay_id
                      ~hash ~received_at:s.received_at;
                    if result = Log.Inserted then begin
                      on_stored hash s.signed;
                      stored + 1
                    end
                    else stored)
            stored page.envelopes
        in
        let last =
          List.fold_left
            (fun m (s : Relay_client.stored) -> max m s.relay_id)
            after page.envelopes
        in
        Log.set_cursor node.log r.url last;
        let fetched = fetched + List.length page.envelopes in
        match page.next with
        | Some next when next > after && page.envelopes <> [] ->
            loop (max next last) fetched stored
        | _ -> (fetched, stored, None))
  in
  Log.transaction node.log (fun () -> loop r.cursor 0 0)

(* Forks, gaps and chain breaks, recomputed over the whole log each pass. A gap that fills resolves. *)
let detect_faults (node : Node.t) (fold : Fold.t) =
  List.iter
    (fun author ->
      if not (Fold.is_chainless fold author) then begin
        (* A revoked key's envelopes past its cutoff are not read, so they make no fork. *)
        let rows =
          List.filter
            (fun (r : Log.row) ->
              not
                (Fold.past_cutoff fold
                   {
                     Fold.hash = r.hash;
                     envelope = r.signed.envelope;
                     body = r.signed.body;
                   }))
            (Log.by_author node.log author)
        in
        let by_seq = Hashtbl.create 16 in
        List.iter
          (fun (r : Log.row) ->
            Hashtbl.replace by_seq r.signed.envelope.seq
              (r
              :: Option.value
                   (Hashtbl.find_opt by_seq r.signed.envelope.seq)
                   ~default:[]))
          rows;
        let max_seq =
          List.fold_left
            (fun m (r : Log.row) -> max m r.signed.envelope.seq)
            0 rows
        in
        for seq = 1 to max_seq do
          match Hashtbl.find_opt by_seq seq with
          | None ->
              Log.add_fault node.log ~kind:"gap" ~author ~seq
                ~detail:"missing from every relay"
          | Some rs ->
              Log.resolve_faults node.log ~kind:"gap" ~author ~seq;
              (match
                 List.sort_uniq compare
                   (List.map (fun (r : Log.row) -> r.hash) rs)
               with
              | _ :: _ :: _ as hashes ->
                  Log.add_fault node.log ~kind:"fork" ~author ~seq
                    ~detail:(String.concat " " hashes)
              | _ -> ());
              List.iter
                (fun (r : Log.row) ->
                  let prev = r.signed.envelope.prev in
                  if seq = 1 then (
                    if prev <> None then
                      Log.add_fault node.log ~kind:"broken_chain" ~author ~seq
                        ~detail:(r.hash ^ " names a prev at seq 1"))
                  else
                    match (Hashtbl.find_opt by_seq (seq - 1), prev) with
                    | Some [ p ], Some prev when p.hash <> prev ->
                        Log.add_fault node.log ~kind:"broken_chain" ~author ~seq
                          ~detail:
                            (r.hash ^ " names prev " ^ prev ^ ", seq "
                            ^ string_of_int (seq - 1)
                            ^ " is " ^ p.hash)
                    | Some [ _ ], None ->
                        Log.add_fault node.log ~kind:"broken_chain" ~author ~seq
                          ~detail:(r.hash ^ " names no prev")
                    | _ -> ())
                rs
        done
      end)
    (Log.authors node.log)

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

(* Push our own envelopes each relay lacks, in chain order. *)
let push_relay (node : Node.t) transport ~key (r : Log.relay_row) =
  let mine =
    List.concat_map
      (fun author -> Log.by_author node.log author)
      (Node.own_keys node)
    |> List.filter (fun (row : Log.row) ->
        not (Log.held_by node.log ~relay:r.url row.hash))
  in
  let rec go pushed = function
    | [] -> (pushed, None)
    | (row : Log.row) :: rest -> (
        match
          Relay_client.append transport ~base:r.url
            ~key:(if Envelope.is_bootstrap row.signed then None else Some key)
            row.signed
        with
        | Ok receipt ->
            Log.add_sighting node.log ~relay:r.url ~relay_id:receipt.relay_id
              ~hash:row.hash ~received_at:None;
            go (if receipt.duplicate then pushed else pushed + 1) rest
        | Error (Relay_client.Refused (_, errs) as e)
          when List.mem_assoc "fork" errs ->
            Log.add_fault node.log ~kind:"fork"
              ~author:row.signed.envelope.author ~seq:row.signed.envelope.seq
              ~detail:(r.url ^ " refused " ^ row.hash ^ " as a fork");
            ignore e;
            go pushed rest
        | Error e -> (pushed, Some (Relay_client.error_to_string e)))
  in
  go 0 mine

(* A relay that refused the read because this node is not admitted there, then took a push of ours:
   the push was the bootstrap (a founding dinner, a replacement laptop's device message) that admits
   it, so the read is worth making again in the same sync. *)
let bootstrapped error pushed push_error =
  match (error, push_error) with
  | Some e, None ->
      pushed > 0 && List.mem "not_admitted" (Relay_client.error_codes e)
  | _ -> false

(* Read, then push, then read again a relay the push admitted this node to. *)
let sync_relay ?on_stored (node : Node.t) transport ~key (r : Log.relay_row) =
  let fetched, stored, error = fetch_relay ?on_stored node transport ~key r in
  (* A relay that refused the read (this node not admitted there yet) still takes our appends:
     a founding dinner, or a replacement laptop's device message, reaches it unsigned this way. *)
  let pushed, push_error =
    match error with
    | Some (Relay_client.Transport _) -> (0, None)
    | _ -> push_relay node transport ~key r
  in
  let fetched, stored, error =
    if bootstrapped error pushed push_error then
      let f, s, e = fetch_relay ?on_stored node transport ~key r in
      (fetched + f, stored + s, e)
    else (fetched, stored, error)
  in
  let error =
    match (error, push_error) with
    | Some e, _ -> Some (Relay_client.error_to_string e)
    | None, e -> e
  in
  Log.record_sync node.log r.url error;
  { relay = r.url; fetched; stored; pushed; error }

(* A member who runs a relay publishes a relay message, and every node adds it (design.md, Two
   relays to start). Each relay message the fold applied, so written by an admitted member, adds its
   URL once: a relay this node removed stays removed until a new relay message names it. *)
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
        | Some (Ok r) -> Log.adopt_relay_message node.log ~hash:row.hash r.url
        | _ -> ())
    (Log.of_kind node.log "relay")

(* [on_stored] sees each envelope the first time this node stores it, after verification: the hook a
   handler for a kind the core does not fold (a release revocation, a sealed message) attaches to. *)
let sync ?(transport = Relay_client.curl) ?on_stored (node : Node.t) =
  match Node.device_key node with
  | Error e -> Error e
  | Ok key ->
      let reports =
        List.map
          (sync_relay ?on_stored node transport ~key)
          (Log.relays node.log)
      in
      let fold = Node.fold node in
      Log.transaction node.log (fun () ->
          detect_faults node fold;
          apply_retracts node fold;
          adopt_relays node fold);
      Ok { relays = reports; fold; faults = Log.open_faults node.log }
