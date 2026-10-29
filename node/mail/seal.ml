(* The one sealing construction (docs/protocol.md, Sealing): a random content key encrypts the
   canonical plaintext with AES-256-GCM, and each recipient gets that key wrapped under
   HKDF-SHA256 of an X25519 exchange with an ephemeral key of its own. *)

let alg = "x25519-hkdf-sha256-a256gcm"
let content_adata = "digestif-v0 sealed"
let wrap_info = "digestif-v0 seal"
let zero_nonce = String.make 12 '\000'
let ( let* ) = Result.bind

let wrap_key ~shared ~ephemeral_pub ~recipient =
  Crypto.hkdf ~salt:(ephemeral_pub ^ recipient) ~info:wrap_info ~ikm:shared 32

(* [ephemerals] supplies one ephemeral X25519 private key per recipient. Only the test vectors
   pass fixed values; everything else lets them be drawn. *)
let seal_with ~content_key ~nonce ~ephemerals ~recipients
    (plaintext : Yojson.Safe.t) =
  if List.length ephemerals <> List.length recipients then
    invalid_arg "Seal.seal_with";
  let ciphertext =
    Crypto.aes_gcm_encrypt ~key:content_key ~nonce ~adata:content_adata
      (Jcs.encode plaintext)
  in
  let entry recipient eph =
    let ephemeral_pub = Crypto.X25519.public eph in
    match Crypto.X25519.shared ~priv:eph ~public:recipient with
    | Error e -> invalid_arg ("Seal: " ^ e)
    | Ok shared ->
        let w = wrap_key ~shared ~ephemeral_pub ~recipient in
        `Assoc
          [
            ("key", `String (Keys.x25519 recipient));
            ("ephemeral", `String (Keys.x25519 ephemeral_pub));
            ( "wrapped",
              `String
                (B64.encode
                   (Crypto.aes_gcm_encrypt ~key:w ~nonce:zero_nonce content_key))
            );
          ]
  in
  `Assoc
    [
      ("alg", `String alg);
      ("recipients", `List (List.map2 entry recipients ephemerals));
      ("nonce", `String (B64.encode nonce));
      ("ciphertext", `String (B64.encode ciphertext));
    ]

(* Seal [plaintext] to the raw 32-byte X25519 public keys [recipients]. *)
let seal ~recipients plaintext =
  seal_with ~content_key:(Crypto.random 32) ~nonce:(Crypto.random 12)
    ~ephemerals:(List.map (fun _ -> Crypto.X25519.generate ()) recipients)
    ~recipients plaintext

let member name = function
  | `Assoc kvs -> (
      match List.assoc_opt name kvs with
      | Some v -> Ok v
      | None -> Error ("missing " ^ name))
  | _ -> Error ("not an object, looking for " ^ name)

let string_member name j =
  let* v = member name j in
  match v with `String s -> Ok s | _ -> Error (name ^ " is not a string")

let b64_member name j =
  let* s = string_member name j in
  B64.decode s

(* The raw recipient keys a sealed value names, in order. *)
let recipients sealed =
  let* l = member "recipients" sealed in
  match l with
  | `List entries ->
      List.fold_right
        (fun e acc ->
          let* acc = acc in
          let* k = string_member "key" e in
          let* raw = Keys.decode_x25519 k in
          Ok (raw :: acc))
        entries (Ok [])
  | _ -> Error "recipients is not a list"

(* Open [sealed] with the raw X25519 private key [priv]. *)
let open_ ~priv sealed =
  let* a = string_member "alg" sealed in
  let* () = if a = alg then Ok () else Error ("unknown alg " ^ a) in
  let me = Keys.x25519 (Crypto.X25519.public priv) in
  let* entries = member "recipients" sealed in
  let* entry =
    match entries with
    | `List l -> (
        match List.find_opt (fun e -> string_member "key" e = Ok me) l with
        | Some e -> Ok e
        | None -> Error "not sealed to this key")
    | _ -> Error "recipients is not a list"
  in
  let* eph_text = string_member "ephemeral" entry in
  let* ephemeral_pub = Keys.decode_x25519 eph_text in
  let* wrapped = b64_member "wrapped" entry in
  let* shared = Crypto.X25519.shared ~priv ~public:ephemeral_pub in
  let recipient = Crypto.X25519.public priv in
  let w = wrap_key ~shared ~ephemeral_pub ~recipient in
  let* content_key =
    Option.to_result ~none:"wrapped key does not open"
      (Crypto.aes_gcm_decrypt ~key:w ~nonce:zero_nonce wrapped)
  in
  let* nonce = b64_member "nonce" sealed in
  let* ciphertext = b64_member "ciphertext" sealed in
  let* plaintext =
    Option.to_result ~none:"ciphertext does not open"
      (Crypto.aes_gcm_decrypt ~key:content_key ~nonce ~adata:content_adata
         ciphertext)
  in
  try Ok (Yojson.Safe.from_string plaintext)
  with Yojson.Json_error e -> Error e
