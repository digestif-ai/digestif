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

(* Seconds before the next try after [attempts] failed stages: 10 minutes, doubling, at most a
   day. *)
let backoff attempts =
  Float.min 86_400. (600. *. (2. ** float_of_int (max 0 (attempts - 1))))

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
  let plan =
    Policy.plan ~refused ~recalls ~installed:state.installed ~pin:state.pin
      ~platform state.trust ~revocations:feed.revocations feed.releases
  in
  Ok (plan, recalls, feed.problems)

(* Download, verify and stage [a]; a failure is kept as pending with its backoff. *)
let stage ?node_major ~fetch ~base ~dir ~now (state : State.t) version
    (a : Release.artifact) =
  let staged =
    let* bytes =
      Result.map_error
        (fun e -> Stage.Retry e)
        (fetch (Feed.resolve ~base a.url))
    in
    let* () =
      Result.map_error
        (fun e -> Stage.Retry e)
        (Install.verify_artifact a bytes)
    in
    Stage.from_archive ?node_major ~dir ~version bytes
  in
  match staged with
  | Ok name -> (Ok name, { state with pending = None })
  | Error (Stage.Refuse why) ->
      ( Error (Refused (version, why)),
        State.refuse { state with pending = None } version why )
  | Error (Stage.Retry why) ->
      let attempts =
        match state.pending with
        | Some p when Version.equal p.pending_version version -> p.attempts + 1
        | _ -> 1
      in
      let due_at = now +. backoff attempts in
      ( Error (Stage_failed (version, why, due_at)),
        {
          state with
          pending =
            Some { pending_version = version; cause = why; attempts; due_at };
        } )

let run ?node_major ?self_test ?circle ~(fetch : Feed.fetch) ~base ~platform
    ~dir ~now () =
  let state_path = Filename.concat dir "update.json" in
  let* state = State.load state_path in
  let* plan, recalls, problems = check ?circle ~fetch ~base ~platform state in
  (* Trust moves first: a signer-set change both signers signed holds whether or not this pass
     installs anything. The version this node runs counts as installed from the first pass that
     finds it there, for a node that never switched. *)
  let state =
    State.note_install { state with trust = plan.trust } state.installed ~now
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
