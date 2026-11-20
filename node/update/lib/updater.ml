(* One update pass: read the channel, plan, stage, switch or obey a recall, persist. The node's service calls [run]
   on a schedule. A switch only moves current and records a trial; the caller then exits, and the
   supervisor runs the new release and decides whether it stays (Supervisor). [installed] in
   update.json moves only once the new release reports healthy. *)

type step =
  | Nothing
  | Switched of Version.t  (** current names this version; the caller exits. *)
  | Staged of Version.t * string
      (** Staged in releases/, but the node is not supervised: a person runs the
          path's `service install` once. *)
  | Waiting of Version.t  (** A failed stage whose backoff has not passed. *)
  | Stage_failed of Version.t * string * float
      (** Kept for another try at the time given. *)
  | Refused of Version.t * string
  | Moved_back of Version.t * Version.t * string
      (** A recall of the first version moved current and good back to the
          second; the caller exits. The line is the digest's. *)

type outcome = {
  plan : Policy.plan;
  step : step;
  problems : string list;
  recall : string list;
      (** What a recall of the running version did, when it moved nothing: the
          digest's line saying why the node stays. *)
}

let ( let* ) = Result.bind

(* [installed] is the last release this node ran healthy, and [good] names that release on disk. A
   release adopted by `digestif service install` (a staged archive, or a local build stamped with a
   version) is good without ever having been switched to by a pass, so its version counts as
   installed whenever update.json says less: the node never plans a release older than the one it
   runs. A move back lowers both together, so this never undoes one. *)
let with_good ~dir (state : State.t) =
  match Option.bind (Layout.good dir) (Layout.version_of dir) with
  | Some v when Version.compare v state.installed > 0 ->
      { state with installed = v }
  | _ -> state

(* Seconds before the next try after [attempts] failed stages: 10 minutes, doubling, at most a
   day. *)
let backoff = State.backoff

(* [circle] is the recalls the node's circle carries (Circle_recall), counted with the channel's. *)
let check ?(circle = []) ~(fetch : Feed.fetch) ~base ~platform (state : State.t)
    =
  let* feed = Feed.read fetch ~base ~installed:state.installed in
  let recalls = feed.recalls @ circle in
  let refused v =
    List.find_map
      (fun (r : State.refused) ->
        if Version.equal r.refused_version v then Some r.why else None)
      state.refused
  in
  (* The channel's signer-set changes move trust first, past a pin, each checked against the set
     before it; a release is then judged by the set they leave. *)
  let state, _ =
    State.adopt_sets state ~revocations:feed.revocations feed.signer_sets
  in
  let plan =
    Policy.plan ~refused ~recalls ~installed:state.installed ~pin:state.pin
      ~platform state.trust ~revocations:feed.revocations feed.releases
  in
  Ok (plan, recalls, feed.problems, state.signer_sets)

(* Download, verify and stage [a]; a failure is kept as pending with its backoff, and one that may be
   the release counts a strike (State.strike). The download stops
   at the size both signers signed, so a channel serving an endless answer at the archive's URL is
   one failed stage, never a node that reads until its memory runs out. *)
let stage ?node_major ~fetch ~base ~dir ~now (state : State.t) version
    (a : Release.artifact) =
  let staged =
    let* bytes =
      Result.map_error
        (fun e -> Stage.Retry e)
        (let* target = Feed.resolve ~base a.url in
         fetch ~limit:a.size target)
    in
    let* () =
      Result.map_error
        (fun e -> Stage.Retry e)
        (Install.verify_artifact a bytes)
    in
    Stage.from_archive ?node_major ~dir ~version bytes
  in
  match staged with
  | Ok name ->
      (* A version with strikes keeps them through the trial it now starts: the trial's verdict
         clears them (healthy) or adds one (Supervisor). *)
      let pending =
        match state.pending with
        | Some p when Version.equal p.pending_version version && p.strikes > 0
          ->
            Some p
        | _ -> None
      in
      (Ok name, { state with pending })
  | Error (Stage.Suspect why) -> (
      let state = State.strike state version why ~now in
      match state.pending with
      | Some p when Version.equal p.pending_version version ->
          (Error (Stage_failed (version, why, p.due_at)), state)
      | _ -> (Error (Refused (version, why ^ State.struck_out_suffix)), state))
  | Error (Stage.Refuse why) ->
      ( Error (Refused (version, why)),
        State.refuse { state with pending = None } version why )
  | Error (Stage.Retry why) ->
      let attempts, strikes =
        match state.pending with
        | Some p when Version.equal p.pending_version version ->
            (p.attempts + 1, p.strikes)
        | _ -> (1, 0)
      in
      let due_at = now +. backoff attempts in
      ( Error (Stage_failed (version, why, due_at)),
        {
          state with
          pending =
            Some
              { pending_version = version; cause = why; attempts; due_at; strikes };
        } )

(* The pass holds the state's lock from its read to its write (State.with_lock), so a signer set the
   web UI adopts or a person's Try again meanwhile waits for it rather than being overwritten. *)
let rec run ?node_major ?self_test ?circle ~(fetch : Feed.fetch) ~base ~platform
    ~dir ~now () =
  State.with_lock (Filename.concat dir "update.json") (fun () ->
      run_locked ?node_major ?self_test ?circle ~fetch ~base ~platform ~dir ~now
        ())

and run_locked ?node_major ?self_test ?circle ~(fetch : Feed.fetch) ~base
    ~platform ~dir ~now () =
  let state_path = Filename.concat dir "update.json" in
  let* state = State.load state_path in
  let state = with_good ~dir state in
  let* plan, recalls, problems, signer_sets =
    check ?circle ~fetch ~base ~platform state
  in
  (* Trust moves first: a signer-set change every current and every new key signed holds whether or
     not this pass installs anything. The version this node runs counts as installed from the first pass that
     finds it there, for a node that never switched. *)
  let state =
    State.note_install
      { state with trust = plan.trust; signer_sets }
      state.installed ~now
  in
  (* A newer release both signers signed is the way forward from a recalled one; a recall moves
     the node back only when there is nothing newer to take. *)
  let recall, state =
    if plan.install <> None then (Recall.Not_recalled, state)
    else
      let state, o =
        Recall.apply ?self_test ~dir ~now ~trust:plan.trust ~recalls state
      in
      (o, state)
  in
  let step, state =
    match recall with
    | Moved_back { recall; to_; line } ->
        (Moved_back (recall.recalled, to_, line), state)
    | Not_recalled | Stayed _ -> (
        match (plan.install, plan.artifact) with
        | Some r, Some a -> (
            let version = r.doc.version in
            match state.pending with
            | Some p
              when Version.equal p.pending_version version && now < p.due_at ->
                (Waiting version, state)
            | _ -> (
                match
                  stage ?node_major ~fetch ~base ~dir ~now state version a
                with
                | Error step, state -> (step, state)
                | Ok name, state -> (
                    if not (Layout.supervised dir) then
                      (Staged (version, Layout.release_dir dir name), state)
                    else
                      match Trial.begin_ dir ~release:name ~version with
                      | Ok () -> (Switched version, state)
                      | Error e ->
                          (Stage_failed (version, e, now +. backoff 1), state)))
            )
        | _ -> (Nothing, { state with pending = None }))
  in
  State.save state_path state;
  let recall = match recall with Stayed { line; _ } -> [ line ] | _ -> [] in
  Ok { plan; step; problems; recall }
