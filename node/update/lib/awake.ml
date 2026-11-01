(* Time the machine was awake, measured by stepping: the caller sleeps a short nominal step, then
   adds what the wall clock says passed. A step that took far longer than asked spanned a sleep of
   the machine, so it counts as the step alone. A laptop closed during a health window therefore
   does not use the window up, and a clock set back counts as nothing. *)

type t = { elapsed : float }

let zero = { elapsed = 0. }

(* Slack before a step counts as a sleep: a loaded machine can run a step late by seconds. *)
let slack = 30.

let step t ~nominal ~wall_delta =
  let counted =
    if wall_delta < 0. then 0.
    else if wall_delta > nominal +. slack then nominal
    else wall_delta
  in
  { elapsed = t.elapsed +. counted }
