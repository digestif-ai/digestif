(* The device body (docs/protocol.md, Circle-state bodies) for the two keys this library admits: a
   machine's mail key, and a phone's device key with its enrollment (docs/protocol.md, The phone).
   The signed triple is digestif_core's (Bodies.make_device); the enrollment rides outside it. *)

open Digestif_core

(* [identity_key] is derived from the recovery phrase by the caller just long enough to call this;
   [key] is the raw 32-byte Ed25519 public key being admitted. *)
let body ~identity_key ~key ~role ?enrollment () =
  match Bodies.make_device ~identity:identity_key ~key:(Keys.encode_ed25519 key) ~role with
  | `Assoc kvs ->
      `Assoc
        (kvs @ match enrollment with Some e -> [ ("enrollment", e) ] | None -> [])
  | j -> j

(* Check the identity's signature over the triple; the enrollment is outside it. Returns the
   identity key, the admitted key and the role as text. *)
let verify body =
  match Bodies.parse_device body with
  | Error e -> Error e
  | Ok d when Bodies.device_signature_valid d ->
      Ok (d.d_identity_key, d.key, Bodies.role_to_string d.role)
  | Ok _ -> Error "bad_signature"
