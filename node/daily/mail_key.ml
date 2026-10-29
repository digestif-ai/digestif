(* This machine's mail key (docs/protocol.md, The mail key): admitted by a device body with role
   mail, and chainless, so its sequence numbers come from a counter the node keeps in the log and
   never hands out twice.

   The device body needs the identity's signature, and the identity key exists only while the
   recovery phrase is in hand, so `digestif init` signs it then and keeps the body (public bytes,
   no secret). It is appended on the first pass that finds this machine's device key admitted:
   written any earlier it would take seq 1 of the device key's chain ahead of the founding dinner
   or the join, which no relay could accept. *)

open Digestif_core
open Digestif_mail

let k_device_body = "mail_device_body"
let k_seq = "mail_seq"
let ( let* ) = Result.bind

let prepare (node : Node.t) ~(identity : Crypto.signing_key) =
  let* mail = Node.mail_key node in
  let body = Device.body ~identity_key:identity ~key:mail.pub ~role:Bodies.Mail () in
  Log.set_config node.log k_device_body (Yojson.Safe.to_string body);
  Ok ()

(* Whether the log already holds a device envelope admitting [key]. *)
let written (node : Node.t) key =
  List.exists
    (fun (r : Log.row) ->
      match r.signed.body with
      | Some b -> (
          match Bodies.parse_device b with Ok d -> d.key = key | Error _ -> false)
      | None -> false)
    (Log.of_kind node.log "device")

type admission =
  | Admitted  (** the fold already admits it *)
  | Appended of string  (** its device envelope went into the log this pass *)
  | Waiting  (** this machine's own device key is not admitted yet *)
  | Needs_phrase  (** no device body was prepared; run digestif device publish *)

let admit (node : Node.t) (fold : Fold.t) =
  match (Log.get_config node.log Node.k_device, Log.get_config node.log Node.k_mail) with
  | None, _ | _, None -> Error "no device or mail key; run digestif init"
  | Some device, Some mail -> (
      if Fold.find fold mail <> None || written node mail then Ok Admitted
      else
        match Fold.find fold device with
        | Some { role = Device; revoked_by = None; _ } -> (
            match Log.get_config node.log k_device_body with
            | None -> Ok Needs_phrase
            | Some text ->
                let* hash, _ =
                  Node.write node ~kind:"device" (Yojson.Safe.from_string text)
                in
                Ok (Appended hash))
        | _ -> Ok Waiting)

(* The next sequence number for the mail key. The counter is written before the number is used, so
   a crash after this returns loses a number and never reuses one; the log's own maximum is a floor
   under it, for a counter restored from an older copy of the log. *)
let next_seq (node : Node.t) () =
  let held =
    match Log.get_config node.log Node.k_mail with
    | Some mail -> Option.value (Log.max_seq node.log mail) ~default:0
    | None -> 0
  in
  let last =
    match Option.bind (Log.get_config node.log k_seq) int_of_string_opt with
    | Some n -> n
    | None -> 0
  in
  let n = max last held + 1 in
  Log.set_config node.log k_seq (string_of_int n);
  n
