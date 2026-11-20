(* CALLS THAT WAIT ON THE NETWORK, MADE AT ONCE: each runs on a thread of its own and the answers come
   back in the order asked. What they wait on is a child process (gh, git, curl) or a socket, and
   the runtime lock is released while a thread blocks on either, so the waits overlap and the run
   takes as long as the slowest call rather than their sum. An exception a call raises is raised
   again here, once every call has finished. *)

let map f xs =
  let start x =
    let slot = ref None in
    let th =
      Thread.create
        (fun () ->
          slot := Some (match f x with v -> Ok v | exception e -> Error e))
        ()
    in
    (th, slot)
  in
  match xs with
  | [] -> []
  | [ x ] -> [ f x ]
  | _ ->
      let started = List.map start xs in
      List.iter (fun (th, _) -> Thread.join th) started;
      List.map
        (fun (_, slot) ->
          match !slot with
          | Some (Ok v) -> v
          | Some (Error e) -> raise e
          | None -> assert false)
        started

(* [map] with at most [limit] calls in flight: each of [limit] threads takes the next call not yet
   started until none is left, so the run takes about the slowest call while the calls fit under
   [limit], and a long list never starts all of its calls at once. The answers come back in the
   order asked, and an exception a call raised is raised again once every call has finished. *)
let map_limit ~limit f xs =
  let n = List.length xs in
  if limit >= n then map f xs
  else
    let todo = Array.of_list xs in
    let slots = Array.make n None in
    let next = ref 0 and m = Mutex.create () in
    let rec work () =
      match
        Mutex.protect m (fun () ->
            let i = !next in
            if i < n then (
              next := i + 1;
              Some i)
            else None)
      with
      | None -> ()
      | Some i ->
          slots.(i) <-
            Some (match f todo.(i) with v -> Ok v | exception e -> Error e);
          work ()
    in
    ignore (map work (List.init (max 1 limit) (fun _ -> ())));
    Array.to_list slots
    |> List.map (function
      | Some (Ok v) -> v
      | Some (Error e) -> raise e
      | None -> assert false)

(* Two calls of different types at once. *)
let both f g =
  let a = ref None in
  let th =
    Thread.create
      (fun () ->
        a := Some (match f () with v -> Ok v | exception e -> Error e))
      ()
  in
  let b = match g () with v -> Ok v | exception e -> Error e in
  Thread.join th;
  match (!a, b) with
  | Some (Ok a), Ok b -> (a, b)
  | Some (Error e), _ | _, Error e -> raise e
  | None, _ -> assert false
