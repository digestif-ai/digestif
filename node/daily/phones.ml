(* Pairing a phone (docs/protocol.md, The phone): the member pastes the phone's pairing code, the
   identity re-derived from the phrase signs a device body admitting the phone's key, and the body
   carries the enrollment that hands the phone the member's encryption key. This machine's device
   key appends it. *)

open Digestif_core
open Digestif_mail

(* What was wrong, by the input that was wrong: the local API names the field from it. *)
type error =
  | Pairing_code of string
  | Recovery_phrase of string
  | Not_signed of string

let error_message = function
  | Pairing_code m | Recovery_phrase m | Not_signed m -> m

let ( let* ) = Result.bind
let as_ f r = Result.map_error f r

(* The code is checked before the phrase is derived, so a mistyped code costs no derivation. *)
let add (node : Node.t) ~phrase ~code =
  let* _ = as_ (fun m -> Pairing_code m) (Phone.parse_pairing_code code) in
  let* identity =
    as_ (fun m -> Recovery_phrase m) (Node.identity_from_phrase node phrase)
  in
  let* enc = as_ (fun m -> Not_signed m) (Node.encryption_key node) in
  let relays =
    List.map (fun (r : Log.relay_row) -> r.url) (Log.relays node.log)
  in
  let* body =
    as_
      (fun m -> Pairing_code m)
      (Phone.device_body ~identity_key:identity ~encryption_priv:enc.secret
         ~relays code)
  in
  let* hash, _ =
    as_ (fun m -> Not_signed m) (Node.write node ~kind:"device" body)
  in
  let* _, key, _ = as_ (fun m -> Not_signed m) (Device.verify body) in
  Ok (hash, key)
