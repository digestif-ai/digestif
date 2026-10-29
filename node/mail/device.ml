(* The device body (docs/protocol.md, Circle-state bodies) for the two keys this library admits: a
   machine's mail key, and a phone's device key with its enrollment (docs/protocol.md, The phone). *)

let signed_triple ~identity_key ~key ~role =
  `Assoc
    [
      ( "identity_key",
        `String (Keys.ed25519 (Crypto.Ed25519.public identity_key)) );
      ("key", `String (Keys.ed25519 key));
      ("role", `String role);
    ]

(* [identity_key] is derived from the recovery phrase by the caller just long enough to call this. *)
let body ~identity_key ~key ~role ?enrollment () =
  let triple = signed_triple ~identity_key ~key ~role in
  let signature =
    B64.encode (Crypto.Ed25519.sign identity_key (Jcs.encode triple))
  in
  match triple with
  | `Assoc kvs ->
      `Assoc
        (kvs
        @ [ ("signature", `String signature) ]
        @ match enrollment with Some e -> [ ("enrollment", e) ] | None -> [])
  | j -> j

let ( let* ) = Result.bind

(* Check the identity's signature over the triple; the enrollment is outside it. *)
let verify body =
  let* identity = Seal.string_member "identity_key" body in
  let* key = Seal.string_member "key" body in
  let* role = Seal.string_member "role" body in
  let* signature = Seal.b64_member "signature" body in
  let* public = Keys.decode_ed25519 identity in
  let triple =
    `Assoc
      [
        ("identity_key", `String identity);
        ("key", `String key);
        ("role", `String role);
      ]
  in
  if Crypto.Ed25519.verify ~public signature (Jcs.encode triple) then
    Ok (identity, key, role)
  else Error "bad_signature"
