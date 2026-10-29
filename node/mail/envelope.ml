(* The envelope fields and the three derived values (docs/protocol.md, The envelope), enough to sign
   what this library writes and to check what it reads back. *)

type t = {
  author : string;
  seq : int;
  prev : string option;
  created_at : string;
  epoch : int;
  kind : string;
  body_hash : string;
}

let version = 0

let unsigned_json e =
  `Assoc
    ([
       ("version", `Int version);
       ("author", `String e.author);
       ("seq", `Int e.seq);
       ("created_at", `String e.created_at);
       ("epoch", `Int e.epoch);
       ("kind", `String e.kind);
       ("body_hash", `String e.body_hash);
     ]
    @ match e.prev with Some p -> [ ("prev", `String p) ] | None -> [])

let body_hash body = Keys.hash (Jcs.encode body)

(* Sign [body] as [kind] with [key]; returns the signed_envelope JSON and its envelope hash. *)
let sign ~key ~seq ?prev ~created_at ~epoch ~kind body =
  let e =
    {
      author = Keys.ed25519 (Crypto.Ed25519.public key);
      seq;
      prev;
      created_at;
      epoch;
      kind;
      body_hash = body_hash body;
    }
  in
  let unsigned = unsigned_json e in
  let signature = B64.encode (Crypto.Ed25519.sign key (Jcs.encode unsigned)) in
  let envelope =
    match unsigned with
    | `Assoc kvs -> `Assoc (kvs @ [ ("signature", `String signature) ])
    | j -> j
  in
  let hash = Keys.hash (Jcs.encode envelope) in
  (`Assoc [ ("envelope", envelope); ("body", body) ], hash)

let ( let* ) = Result.bind

(* Verify a signed_envelope: the signature over the envelope without it, and the body hash. Returns
   the envelope, its body and its hash. *)
let verify signed =
  let* envelope = Seal.member "envelope" signed in
  let* body = Seal.member "body" signed in
  let* author = Seal.string_member "author" envelope in
  let* public = Keys.decode_ed25519 author in
  let* signature = Seal.b64_member "signature" envelope in
  let unsigned =
    match envelope with
    | `Assoc kvs -> `Assoc (List.filter (fun (k, _) -> k <> "signature") kvs)
    | j -> j
  in
  let* () =
    if Crypto.Ed25519.verify ~public signature (Jcs.encode unsigned) then Ok ()
    else Error "bad_signature"
  in
  let* bh = Seal.string_member "body_hash" envelope in
  let* () =
    if bh = body_hash body then Ok () else Error "body_hash does not match"
  in
  Ok (envelope, body, Keys.hash (Jcs.encode envelope))
