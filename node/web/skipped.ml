(* ISS-81609 (docs/design.md, Reaching a person): the projects the last reading left unread because a
   folder could not be judged, and why, for one notice from the node in the local Inbox. Both readers
   record here: the node's own (Sources.extract_reading, for Draft for me and the setup chat) and the
   behaviors nightly (`digestif skipped report`). The newest reading stands, whichever reader made it.

   What is kept carries folder names, so it never leaves the machine: it lives in this node's config,
   and the notice it raises is a local subject (Item.local_subject) whose title is a count. The
   folders are in the notice's detail alone, which the digest never carries. *)

open Digestif_core

type reason = No_access | Too_many | Too_long | Could_not_read

let reasons =
  [
    ("no_access", No_access);
    ("too_many", Too_many);
    ("too_long", Too_long);
    ("could_not_read", Could_not_read);
  ]

let reason_name r = fst (List.find (fun (_, x) -> x = r) reasons)
let reason_of_name n = List.assoc_opt n reasons

let of_sources_reason : Sources.reason -> reason = function
  | Permission -> No_access
  | Cap -> Too_many
  | Listing_time | Reading_deadline -> Too_long
  | Read_error -> Could_not_read

(* One reading's skips: how many projects it did not read, and each folder that kept one unread. *)
type t = { projects : int; folders : (string * reason) list }

let none = { projects = 0; folders = [] }
let k_reading = "reading_skipped"

(* The pairs a notice last told, so the same folder skipped for the same reason is told once. *)
let k_told = "reading_skipped_told"

let to_json t =
  `Assoc
    [
      ("projects", `Int t.projects);
      ( "folders",
        `List
          (List.map
             (fun (f, r) ->
               `Assoc
                 [ ("folder", `String f); ("reason", `String (reason_name r)) ])
             t.folders) );
    ]

(* A reading as `digestif skipped report` is handed it, or as it was kept. A folder with a reason
   this release does not know is kept as one that could not be read, so a skip is never dropped. *)
let of_json j =
  let open Yojson.Safe.Util in
  try
    let projects = j |> member "projects" |> to_int in
    let folders =
      match j |> member "folders" with
      | `Null -> []
      | l ->
          to_list l
          |> List.filter_map (fun f ->
              match f |> member "folder" with
              | `String folder when folder <> "" ->
                  let reason =
                    match f |> member "reason" with
                    | `String r ->
                        Option.value (reason_of_name r) ~default:Could_not_read
                    | _ -> Could_not_read
                  in
                  Some (folder, reason)
              | _ -> None)
    in
    if projects < 0 then Error "projects must not be negative."
    else Ok { projects; folders = List.sort_uniq compare folders }
  with Type_error (m, _) | Yojson.Json_error m -> Error m

let of_reading (r : Sources.reading) =
  {
    projects = r.unjudged;
    folders =
      List.sort_uniq compare
        (List.map (fun (f, why) -> (f, of_sources_reason why)) r.skipped);
  }

(* The newest reading replaces the one before: a reading that skipped nothing clears it. *)
let record (log : Log.t) t =
  let t = if t.projects = 0 then none else t in
  Store.set_config log k_reading (Yojson.Safe.to_string (to_json t))

let current (log : Log.t) =
  match Store.config log k_reading with
  | None -> none
  | Some s -> (
      match of_json (Yojson.Safe.from_string s) with
      | Ok t -> t
      | Error _ -> none
      | exception Yojson.Json_error _ -> none)

let pairs t = List.map (fun (f, r) -> f ^ "\t" ^ reason_name r) t.folders

let told (log : Log.t) =
  match Store.config log k_told with
  | None | Some "" -> []
  | Some s -> String.split_on_char '\n' s

let set_told (log : Log.t) t =
  Store.set_config log k_told (String.concat "\n" (pairs t))

(* The notice's title, a count and nothing on the machine: it is the one line the digest carries. *)
let title t =
  if t.projects = 1 then
    "1 project was not read: Digestif could not look at a folder it is in."
  else
    Printf.sprintf
      "%d projects were not read: Digestif could not look at a folder they are \
       in."
      t.projects

let why ~macos = function
  | No_access ->
      if macos then
        "no access. Open System Settings, Privacy and Security, Full Disk \
         Access, and add the Digestif node."
      else "no access. Change the folder's permissions so you can open it."
  | Too_many -> "too many entries, more than 10,000 in one folder."
  | Too_long -> "took too long to list."
  | Could_not_read -> "it could not be read."

(* The notice's detail: each folder and why, with what to do for no access. It names folders, so it
   is shown on this machine and nowhere else. *)
let detail ?(macos = Keystore.is_macos ()) t =
  let lines =
    List.map
      (fun (f, r) -> Printf.sprintf "%s: %s" (Sources.tilde f) (why ~macos r))
      t.folders
  in
  String.concat "\n"
    (lines
    @ [
        "A project that cannot be judged is never read, so its sessions are \
         not in your notes until this clears.";
      ])
