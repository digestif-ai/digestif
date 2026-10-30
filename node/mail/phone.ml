(* Pairing a phone (docs/protocol.md, The phone): the phone shows a code carrying its two public
   keys, and the node admits the signing key with a device body whose enrollment hands the phone
   the member's encryption key, sealed to the phone's X25519 key. *)

open Digestif_core

let check_of keys = B64url.encode (String.sub (Mail_crypto.sha256 keys) 0 3)

let pairing_code ~ed25519 ~x25519 =
  let keys = ed25519 ^ x25519 in
  "p1." ^ B64url.encode keys ^ "." ^ check_of keys

let ( let* ) = Result.bind

(* The member reads these on the Add a phone page; the UI's mock (ui/mock/node.ts) answers the
   same sentences. *)
let not_a_code =
  "Not a pairing code: it starts with p1. and comes from the phone."

let check_mismatch = "The pairing code's check does not match; retype it."

(* The phone's raw Ed25519 and X25519 public keys. Whitespace a paste picked up is ignored. *)
let parse_pairing_code code =
  let code = String.concat "" (String.split_on_char ' ' (String.trim code)) in
  match String.split_on_char '.' code with
  | [ "p1"; keys; check ] -> (
      match B64url.decode keys with
      | Ok raw when String.length raw = 64 ->
          if check_of raw <> check then Error check_mismatch
          else Ok (String.sub raw 0 32, String.sub raw 32 32)
      | _ -> Error not_a_code)
  | _ -> Error not_a_code

let enrollment ~phone_x25519 ~identity_key ~encryption_priv ~relays =
  Seal.seal ~recipients:[ phone_x25519 ]
    (`Assoc
       [
         ("encryption_key", `String (B64url.encode encryption_priv));
         ("identity_key", `String (Keys.public identity_key));
         ("relays", `List (List.map (fun r -> `String r) relays));
       ])

(* The device body admitting the phone. The laptop's device key appends it. *)
let device_body ~identity_key ~encryption_priv ~relays code =
  let* ed, x = parse_pairing_code code in
  Ok
    (Device.body ~identity_key ~key:ed ~role:Bodies.Device
       ~enrollment:
         (enrollment ~phone_x25519:x ~identity_key ~encryption_priv ~relays)
       ())

(* The phone's half: the member's encryption private key, identity key and relays. *)
let open_enrollment ~phone_x25519_priv body =
  let* e = Seal.member "enrollment" body in
  let* p = Seal.open_ ~priv:phone_x25519_priv e in
  let* key = Seal.b64_member "encryption_key" p in
  let* identity = Seal.string_member "identity_key" p in
  let* relays = Seal.member "relays" p in
  let relays =
    match relays with
    | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  Ok (key, identity, relays)
