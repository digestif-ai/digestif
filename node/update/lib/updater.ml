(* One update pass: read the channel, plan, install, persist. The node's service calls [run] on a
   schedule and exits after an install so launchd or systemd starts the new binary. *)

type outcome = {
  plan : Policy.plan;
  installed : Version.t option;
      (** The version written over the binary, if any. *)
  problems : string list;
}

let ( let* ) = Result.bind

let check ~(fetch : Feed.fetch) ~base ~platform (state : State.t) =
  let* feed = Feed.read fetch ~base ~installed:state.installed in
  let plan =
    Policy.plan ~installed:state.installed ~pin:state.pin ~platform state.trust
      ~revocations:feed.revocations feed.releases
  in
  Ok (plan, feed.problems)

let run ~(fetch : Feed.fetch) ~base ~platform ~state_path ~binary =
  let* state = State.load state_path in
  let* plan, problems = check ~fetch ~base ~platform state in
  (* Trust moves first: a signer-set change both signers signed holds whether or not this pass
     installs anything. *)
  let state = { state with trust = plan.trust } in
  let* installed =
    match (plan.install, plan.artifact) with
    | Some r, Some a ->
        let* bytes = fetch (Feed.resolve ~base a.url) in
        let* () = Install.verify_artifact a bytes in
        let* () = Install.replace ~binary bytes in
        Ok (Some r.doc.version)
    | _ -> Ok None
  in
  let state =
    match installed with
    | Some v -> { state with installed = v }
    | None -> state
  in
  State.save state_path state;
  Ok { plan; installed; problems }
