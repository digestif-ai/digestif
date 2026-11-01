(* One update pass: read the channel, plan, stage, switch, persist. The node's service calls [run]
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

type outcome = { plan : Policy.plan; step : step; problems : string list }

let ( let* ) = Result.bind

(* Seconds before the next try after [attempts] failed stages: 10 minutes, doubling, at most a
   day. *)
let backoff attempts =
  Float.min 86_400. (600. *. (2. ** float_of_int (max 0 (attempts - 1))))

let check ~(fetch : Feed.fetch) ~base ~platform (state : State.t) =
  let* feed = Feed.read fetch ~base ~installed:state.installed in
  let refused v =
    List.find_map
      (fun (r : State.refused) ->
        if Version.equal r.refused_version v then Some r.why else None)
      state.refused
  in
  let plan =
    Policy.plan ~refused ~installed:state.installed ~pin:state.pin ~platform
      state.trust ~revocations:feed.revocations feed.releases
  in
  Ok (plan, feed.problems)

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

let run ?node_major ~(fetch : Feed.fetch) ~base ~platform ~dir ~now () =
  let state_path = Filename.concat dir "update.json" in
  let* state = State.load state_path in
  let* plan, problems = check ~fetch ~base ~platform state in
  (* Trust moves first: a signer-set change both signers signed holds whether or not this pass
     installs anything. *)
  let state = { state with trust = plan.trust } in
  let step, state =
    match (plan.install, plan.artifact) with
    | Some r, Some a -> (
        let version = r.doc.version in
        match state.pending with
        | Some p when Version.equal p.pending_version version && now < p.due_at
          ->
            (Waiting version, state)
        | _ -> (
            match stage ?node_major ~fetch ~base ~dir ~now state version a with
            | Error step, state -> (step, state)
            | Ok name, state -> (
                if not (Layout.supervised dir) then
                  (Staged (version, Layout.release_dir dir name), state)
                else
                  match Trial.begin_ dir ~release:name ~version with
                  | Ok () -> (Switched version, state)
                  | Error e ->
                      (Stage_failed (version, e, now +. backoff 1), state))))
    | _ -> (Nothing, { state with pending = None })
  in
  State.save state_path state;
  Ok { plan; step; problems }
