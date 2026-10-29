(* Pairing a phone (docs/protocol.md, The phone): the member pastes the phone's pairing code, the
   identity re-derived from the phrase signs a device body admitting the phone's key, and the body
   carries the enrollment that hands the phone the member's encryption key. This machine's device
   key appends it. *)

open Digestif_core
open Digestif_mail

let ( let* ) = Result.bind

let add (node : Node.t) ~phrase ~code =
  let* identity = Node.identity_from_phrase node phrase in
  let* enc = Node.encryption_key node in
  let relays =
    List.map (fun (r : Log.relay_row) -> r.url) (Log.relays node.log)
  in
  let* body =
    Phone.device_body ~identity_key:identity ~encryption_priv:enc.secret ~relays
      code
  in
  let* hash, _ = Node.write node ~kind:"device" body in
  let* _, key, _ = Device.verify body in
  Ok (hash, key)
