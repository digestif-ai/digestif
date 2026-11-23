(* The circle folders' nodes the machine's one service runs (DIG-347; docs/design.md, Circles). The
   machine's service is the standard node's: its supervisor (Supervisor) runs that node and keeps
   or rolls back each release by it, and beside it runs `digestif run` for every circle folder under
   ~/digestif, a link included, starting one for a folder that appears and stopping one whose folder
   goes. Each folder stays a whole node, one process with its own log, keys and UI port (the port
   DIG-264 derives from its directory).

   Releases live once per machine: every folder's node runs the release the machine's good names,
   from the machine's releases/ (Layout.share), and never updates itself. A release the standard
   node has not yet reported healthy is never run here, so a folder's node moves to a release only
   once it is kept, and moves at once. A folder's node that exits is started again after a pause
   that doubles while it keeps exiting soon after starting, so one node that cannot start costs
   the machine nothing and holds up no other.

   Before a folder's node first runs here, any per-node service DIG-264 installed for it is retired
   (Service.retire, read from the unit's own --data-dir), so no node runs twice.

   On a machine whose standard place holds no node, the supervisor's own child runs one folder's
   node in its place (stand_in), and that folder is not run here. DIG-351 *)

type ops = {
  folders : unit -> string list;
      (** The data directories to run now, the machine's own left out. *)
  release : unit -> string option;  (** The release the machine's good names. *)
  prepare : dir:string -> release:string -> (unit, string) result;
      (** Retire the folder's own service and point it at the release. *)
  spawn : dir:string -> release:string -> (int, string) result;
  poll : int -> Supervisor.exit_status option;
  terminate : int -> unit;
  now : unit -> float;
  log : string -> unit;
}

type running = { pid : int; on : string; started : float }

type child = {
  dir : string;
  running : running option;
  quick_exits : int;  (** Exits in a row, each soon after its start. *)
  next_start : float;
  refusal : string option;  (** Why the last start could not prepare. *)
}

type t = child list

let empty : t = []

(* A node that ran this long before it exited was running, and its next start waits the least. *)
let steady = 60.
let first_pause = 10.
let longest_pause = 600.

(* Seconds before the next start after [n] quick exits in a row. *)
let pause n =
  Float.min longest_pause (first_pause *. (2. ** float_of_int (max 0 (n - 1))))

(* How long a folder whose start could not prepare waits before it is tried again. *)
let retry_prepare = 60.

(* The folders to run among [dirs]: each one once, by its real path, and never the machine's own
   node, which the supervisor runs itself (a circle link to the standard node is that node). *)
let folders ~machine dirs =
  let machine = Node.canonical_dir machine in
  List.fold_left
    (fun (seen, acc) d ->
      let c = Node.canonical_dir d in
      if c = machine || List.mem c seen then (seen, acc)
      else (c :: seen, d :: acc))
    ([], []) dirs
  |> snd |> List.rev

(* The circle folder whose node the supervisor runs as its own child, in the machine's place, among
   [folders] (DIG-351): none while the machine's standard place holds a node, else the folder it ran
   last while that one is still there, else the first. Running that folder's node is what lets a
   machine whose only nodes are circle folders judge a release by one of them, and it leaves no node
   at the standard place for nobody to set up. That folder is left out of the ones run here. *)
let stand_in ~machine_holds_node ~previous folders =
  if machine_holds_node then None
  else
    match previous with
    | Some p when List.mem p folders -> Some p
    | _ -> ( match folders with d :: _ -> Some d | [] -> None)

let start ops ~now ~release c =
  match release with
  | None -> c
  | Some r -> (
      let refused e =
        if c.refusal <> Some e then
          ops.log (Printf.sprintf "%s: not started: %s" c.dir e);
        { c with refusal = Some e; next_start = now +. retry_prepare }
      in
      match ops.prepare ~dir:c.dir ~release:r with
      | Error e -> refused e
      | Ok () -> (
          match ops.spawn ~dir:c.dir ~release:r with
          | Error e -> refused e
          | Ok pid ->
              ops.log (Printf.sprintf "%s: started on %s, pid %d" c.dir r pid);
              {
                c with
                running = Some { pid; on = r; started = now };
                refusal = None;
              }))

let step ops ~now ~release c =
  match c.running with
  | Some run -> (
      match ops.poll run.pid with
      | Some status ->
          let quick =
            if now -. run.started >= steady then 1 else c.quick_exits + 1
          in
          let wait = pause quick in
          ops.log
            (Printf.sprintf "%s: %s; starting it again in %.0f seconds" c.dir
               (Supervisor.describe status)
               wait);
          {
            c with
            running = None;
            quick_exits = quick;
            next_start = now +. wait;
          }
      | None -> (
          match release with
          | Some r when r <> run.on ->
              ops.log (Printf.sprintf "%s: moving to %s" c.dir r);
              ops.terminate run.pid;
              start ops ~now ~release { c with running = None; quick_exits = 0 }
          | _ ->
              if c.quick_exits > 0 && now -. run.started >= steady then
                { c with quick_exits = 0 }
              else c))
  | None -> if now >= c.next_start then start ops ~now ~release c else c

let stop_child ops c = Option.iter (fun r -> ops.terminate r.pid) c.running

(* One look: stop the nodes whose folder went, add the folders that appeared, and start, restart
   or move each node as it needs. *)
let tick ops (t : t) : t =
  let now = ops.now () in
  let wanted = ops.folders () in
  let release = ops.release () in
  let kept =
    List.filter
      (fun c ->
        if List.mem c.dir wanted then true
        else begin
          if c.running <> None then
            ops.log (Printf.sprintf "%s: its folder is gone; stopping" c.dir);
          stop_child ops c;
          false
        end)
      t
  in
  let added =
    List.filter_map
      (fun dir ->
        if List.exists (fun c -> c.dir = dir) kept then None
        else
          Some
            {
              dir;
              running = None;
              quick_exits = 0;
              next_start = now;
              refusal = None;
            })
      wanted
  in
  List.map (step ops ~now ~release) (kept @ added)

(* Stop every node, when the supervisor itself stops. *)
let stop ops (t : t) = List.iter (stop_child ops) t
