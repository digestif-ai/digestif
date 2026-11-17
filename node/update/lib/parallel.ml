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
