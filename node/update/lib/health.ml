(* The report a running node makes that it is healthy: `digestif run` writes health.json once its
   first pass has opened the store, synced and started the web UI. The supervisor reads it to end a
   switch's trial. *)

type t = { version : string; pid : int; at : float }

let write dir t =
  State.write_atomic (Layout.health_path dir)
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("version", `String t.version);
            ("pid", `Int t.pid);
            ("at", `Float t.at);
          ])
    ^ "\n")

let read dir =
  match State.read_file (Layout.health_path dir) with
  | exception Sys_error _ -> None
  | bytes -> (
      match Yojson.Safe.from_string bytes with
      | exception Yojson.Json_error _ -> None
      | json -> (
          match
            ( Release.field "version" json,
              Release.field "pid" json,
              Release.field "at" json )
          with
          | Some (`String version), Some (`Int pid), Some at ->
              let at =
                match at with
                | `Float f -> f
                | `Int i -> float_of_int i
                | _ -> 0.
              in
              Some { version; pid; at }
          | _ -> None))

let clear dir =
  try Sys.remove (Layout.health_path dir) with Sys_error _ -> ()
