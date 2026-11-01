(* What is wrong with this node's updates now, for the web UI's header (the digest says each thing
   once; the UI says it while it holds). A stage that failed and will be tried again, and every
   release refused that is newer than the one running. *)

let problems ~dir =
  match State.load (Schedule.state_path dir) with
  | Error e -> [ "The update state cannot be read: " ^ e ^ "." ]
  | Ok s ->
      let pending =
        match s.pending with
        | None -> []
        | Some p ->
            [
              Printf.sprintf
                "Release %s could not be staged: %s. The node tries again \
                 after %s."
                (Version.to_string p.pending_version)
                p.cause
                (Schedule.clock_line p.due_at);
            ]
      in
      let refused =
        List.filter_map
          (fun (r : State.refused) ->
            if Version.compare r.refused_version s.installed > 0 then
              Some
                (Printf.sprintf "Release %s was refused: %s."
                   (Version.to_string r.refused_version)
                   r.why)
            else None)
          s.refused
      in
      pending @ refused
