(* What is wrong with this node's updates now, for the web UI's header (the digest says each thing
   once; the UI says it while it holds). A stage that failed and will be tried again, and every
   release refused that is newer than the one running. Each line is the state, not the event: which
   release, why, what the node runs meanwhile, and what happens next, and [retry] names the release a
   person's Try again would take another try at when that can help (Schedule.retry). DIG-255 *)

type entry = { line : string; retry : Version.t option }

(* Whether a refusal may have been this machine rather than the release: failures that each may
   have been the machine, on every try (State.strike), a self-test that could not run or ran past
   its bound, or an unpack, refused by an older node that refused those at once. Every other refusal is the release's bytes,
   which the next release replaces. *)
let machine_may_be_why why =
  State.struck_out why
  || List.exists
    (fun prefix -> String.starts_with ~prefix why)
    [ "its self-test failed: "; "the release archive did not unpack" ]

let clock at =
  let t = Unix.localtime at in
  let h = t.tm_hour mod 12 in
  Printf.sprintf "%d:%02d %s"
    (if h = 0 then 12 else h)
    t.tm_min
    (if t.tm_hour < 12 then "AM" else "PM")

let entries ~dir =
  match State.load (Schedule.state_path dir) with
  | Error e ->
      [ { line = "The update state cannot be read: " ^ e ^ "."; retry = None } ]
  | Ok s ->
      let s = Updater.with_good ~dir s in
      let running = Version.to_string s.installed in
      let pending =
        match s.pending with
        | None -> []
        | Some p ->
            [
              {
                line =
                  Printf.sprintf
                    "Release %s could not be installed on this machine yet: \
                     %s. Still running %s; the node tries again at %s."
                    (Version.to_string p.pending_version)
                    p.cause running (clock p.due_at);
                retry = Some p.pending_version;
              };
            ]
      in
      let refused =
        List.filter_map
          (fun (r : State.refused) ->
            if Version.compare r.refused_version s.installed <= 0 then None
            else
              let v = Version.to_string r.refused_version in
              if machine_may_be_why r.why then
                Some
                  {
                    line =
                      Printf.sprintf
                        "Release %s was refused on this machine: %s. Still \
                         running %s."
                        v r.why running;
                    retry = Some r.refused_version;
                  }
              else
                Some
                  {
                    line =
                      Printf.sprintf
                        "Release %s was refused: %s. That is the release's \
                         fault, and the next release replaces it; there is \
                         nothing to do. Still running %s."
                        v r.why running;
                    retry = None;
                  })
          s.refused
      in
      pending @ refused

let problems ~dir = List.map (fun e -> e.line) (entries ~dir)

(* The release a Try again would take another try at, when one can help. *)
let retryable ~dir = List.find_map (fun e -> e.retry) (entries ~dir)
