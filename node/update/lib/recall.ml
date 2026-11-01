(* What a recall does to the version a node runs (docs/releases.md, A recall). A node derives what
   is recalled on every pass, from the channel and the circle, with the signer set it holds
   (Policy.recall_of): nothing about a recall is stored, so the next version both sign, or removing
   the recalling key, is all it takes to undo one.

   On reading a recall of the version it runs, a node moves back to the newest older release on its
   disk (Move_back). One signer's recall is bounded by a week: it cannot take a node below the newest
   release the node first installed more than a week ago, so it cannot move a node off a version it
   has run that long, and chained recalls cannot walk it down releases/. A recall every signer
   signed has no limit. *)

let week = 7. *. 86_400.

(* The newest version this node first installed more than a week before [now] (State.first_installed,
   which a move back never resets), leaving out a version every signer recalled. One signer's recall
   cannot take the node below it. *)
let floor (state : State.t) ~now ~recalled_by_every_signer =
  List.fold_left
    (fun acc (v, at) ->
      if now -. at <= week || recalled_by_every_signer v then acc
      else
        match acc with
        | Some f when Version.compare f v >= 0 -> acc
        | _ -> Some v)
    None state.first_installed

type outcome =
  | Not_recalled  (** The running version is not recalled. *)
  | Moved_back of { recall : Policy.recall; to_ : Version.t; line : string }
      (** current and good name [to_]; the caller exits. *)
  | Stayed of { recall : Policy.recall; line : string }
      (** The node keeps running the recalled version until the next release. *)

let keeps_running v =
  Printf.sprintf "so it keeps running %s until the next release."
    (Version.to_string v)

let stayed_line (recall : Policy.recall) ~running (refusal : Move_back.refusal)
    =
  let v = Version.to_string in
  let why =
    match refusal with
    | Not_supervised | Nothing_older ->
        "This node has nothing to go back to, " ^ keeps_running running
    | Below_floor f when Version.equal f running ->
        Printf.sprintf
          "This node has run %s for more than a week, and one signer's recall \
           does not move a node off a version it has run that long, %s"
          (v running) (keeps_running running)
    | Below_floor f ->
        Printf.sprintf
          "This node ran %s for more than a week, and one signer's recall does \
           not take a node below it, %s"
          (v f) (keeps_running running)
    | Self_test_failed (older, e) ->
        Printf.sprintf "Going back to %s failed its self-test (%s), %s"
          (v older) e (keeps_running running)
  in
  Policy.recalled_line recall ^ " " ^ why

(* The version the node runs: the release current names, or the installed one when the node has
   no layout yet. *)
let running ~dir (state : State.t) =
  match Option.bind (Layout.current dir) (Layout.version_of dir) with
  | Some v -> v
  | None -> state.installed

(* Act on the recalls that count under [trust] for the version this node runs. *)
let apply ?self_test ~dir ~now ~(trust : Policy.trust)
    ~(recalls : Release.recall Release.signed list) (state : State.t) =
  let from = running ~dir state in
  match Policy.recall_of trust recalls from with
  | None -> (state, Not_recalled)
  | Some recall -> (
      let recalled v = Policy.recall_of trust recalls v <> None in
      let recalled_by_every_signer v =
        match Policy.recall_of trust recalls v with
        | Some r -> r.every_signer
        | None -> false
      in
      let floor =
        if recall.every_signer then None
        else floor state ~now ~recalled_by_every_signer
      in
      match
        Move_back.run ?self_test ?floor ~excluded:recalled ~dir ~from state
      with
      | Ok (state, to_) ->
          ( state,
            Moved_back
              {
                recall;
                to_;
                line =
                  Printf.sprintf "%s This node went back to %s."
                    (Policy.recalled_line recall)
                    (Version.to_string to_);
              } )
      | Error refusal ->
          ( state,
            Stayed { recall; line = stayed_line recall ~running:from refusal }
          ))
