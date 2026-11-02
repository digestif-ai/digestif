(* The guest's join, signed and kept beside the log before it is posted, so a setup that stops after
   the join (a closed window, a relay that did not answer) posts the same envelope again and never
   spends the single-use invite twice. Relays take a duplicate append as the same append.

   It holds nothing secret: the join envelope is public once posted, and the invite is named by its
   public key, never by the code. *)

open Digestif_core

type t = {
  invite_key : string;  (** the invite's public key, ed25519:<base64url> *)
  dinner_hash : string;
  relays : string list;  (** every relay the dinner lists *)
  guest_name : string option;  (** the name the host gave this guest *)
  join : Envelope.signed;
  posted : bool;  (** a relay took it and the node adopted it *)
}

let file dir = Filename.concat dir "join.json"

let to_json t : Yojson.Safe.t =
  `Assoc
    [
      ("invite_key", `String t.invite_key);
      ("dinner_hash", `String t.dinner_hash);
      ("relays", `List (List.map (fun r -> `String r) t.relays));
      ( "guest_name",
        match t.guest_name with Some n -> `String n | None -> `Null );
      ("join", Envelope.signed_to_json t.join);
      ("posted", `Bool t.posted);
    ]

let of_json (j : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  try
    match Envelope.signed_of_json (member "join" j) with
    | Error e -> Error (Envelope.error_message e)
    | Ok join ->
        Ok
          {
            invite_key = to_string (member "invite_key" j);
            dinner_hash = to_string (member "dinner_hash" j);
            relays = List.map to_string (to_list (member "relays" j));
            guest_name = to_string_option (member "guest_name" j);
            join;
            posted = to_bool (member "posted" j);
          }
  with Type_error (m, _) -> Error m

let load dir =
  let p = file dir in
  if not (Sys.file_exists p) then Ok None
  else
    match Yojson.Safe.from_file p with
    | exception (Yojson.Json_error m | Sys_error m) -> Error (p ^ ": " ^ m)
    | j -> (
        match of_json j with
        | Ok t -> Ok (Some t)
        | Error m -> Error (p ^ ": " ^ m))

(* Written to a temporary file and renamed, so a stop mid-write never leaves half a join. *)
let save dir t =
  try
    Node.mkdir_p dir;
    let p = file dir in
    let tmp = p ^ ".tmp" in
    let fd = Unix.openfile tmp [ O_WRONLY; O_CREAT; O_TRUNC ] 0o600 in
    let oc = Unix.out_channel_of_descr fd in
    output_string oc (Yojson.Safe.pretty_to_string (to_json t));
    output_char oc '\n';
    close_out oc;
    Unix.rename tmp p;
    Ok ()
  with Unix.Unix_error (e, _, arg) ->
    Error (Printf.sprintf "%s: %s" arg (Unix.error_message e))
