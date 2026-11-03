(* Work a request starts and does not wait on. The node's server answers one request at a time, so
   anything slow inside a request holds every other page until it ends; work that can take longer
   than a page should wait runs here instead, on a thread of its own, against a connection of its
   own to the node's log (the request's connection is the server's). ISS-41767, ISS-41847 *)

open Digestif_core

(* [f] on a thread of its own, against its own connection to the node's log in [dir]. [running]
   allows one at a time: nothing when it is already set, the thread otherwise, and it is cleared
   when [f] ends. An exception, from [f] or from opening the log, is printed under [what] and then
   handed to [on_error]. *)
let run ~running ~(dir : string) ~what ?(on_error = fun (_ : exn) -> ())
    (f : Log.t -> unit) =
  if Atomic.compare_and_set running false true then
    Some
      (Thread.create
         (fun () ->
           Fun.protect
             ~finally:(fun () -> Atomic.set running false)
             (fun () ->
               try
                 let log = Log.open_ (Node.log_path dir) in
                 Fun.protect
                   ~finally:(fun () -> Log.close log)
                   (fun () -> f log)
               with e ->
                 Printf.eprintf "%s %s: %s\n%!" (Time_fmt.now ()) what
                   (Printexc.to_string e);
                 on_error e))
         ())
  else None
