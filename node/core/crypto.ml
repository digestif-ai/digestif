(* The primitives, in one place: SHA-256 for hashes, Ed25519 for signatures, X25519 for the
   encryption key, HMAC-SHA512 and PBKDF2 for the recovery phrase, and the system RNG. *)

module Ed = Mirage_crypto_ec.Ed25519
module X = Mirage_crypto_ec.X25519

let rng_ready = lazy (Mirage_crypto_rng_unix.use_default ())
let random n = Lazy.force rng_ready; Mirage_crypto_rng.generate n
let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))
let sha256_hex s = Digestif.SHA256.(to_hex (digest_string s))
let sha512 s = Digestif.SHA512.(to_raw_string (digest_string s))
let hmac_sha512 ~key msg = Digestif.SHA512.(to_raw_string (hmac_string ~key msg))
let hmac_sha256 ~key msg = Digestif.SHA256.(to_raw_string (hmac_string ~key msg))

let xor a b = String.init (String.length a) (fun i -> Char.chr (Char.code a.[i] lxor Char.code b.[i]))

(* PBKDF2 (RFC 8018) over HMAC-SHA512, as BIP39 specifies for the seed. *)
let pbkdf2_sha512 ~password ~salt ~iterations ~length =
  let hlen = 64 in
  let blocks = (length + hlen - 1) / hlen in
  let block i =
    let be32 = String.init 4 (fun k -> Char.chr ((i lsr (8 * (3 - k))) land 0xff)) in
    let u = ref (hmac_sha512 ~key:password (salt ^ be32)) in
    let t = ref !u in
    for _ = 2 to iterations do
      u := hmac_sha512 ~key:password !u;
      t := xor !t !u
    done;
    !t
  in
  let out = String.concat "" (List.init blocks (fun i -> block (i + 1))) in
  String.sub out 0 length

(* An Ed25519 signing key is its 32-byte seed. *)
type signing_key = { seed : string; priv : Ed.priv; pub : string }

let signing_key_of_seed seed =
  match Ed.priv_of_octets seed with
  | Ok priv -> Ok { seed; priv; pub = Ed.pub_to_octets (Ed.pub_of_priv priv) }
  | Error e -> Error (Format.asprintf "ed25519 seed: %a" Mirage_crypto_ec.pp_error e)

let signing_key_of_seed_exn seed =
  match signing_key_of_seed seed with Ok k -> k | Error e -> invalid_arg e

let generate_signing_key () = signing_key_of_seed_exn (random 32)
let sign k msg = Ed.sign ~key:k.priv msg

let verify ~pub ~signature msg =
  match Ed.pub_of_octets pub with
  | Error _ -> false
  | Ok key -> String.length signature = 64 && Ed.verify ~key signature ~msg

(* An X25519 key is its 32-byte secret; the public half is derived. *)
type encryption_key = { secret : string; public : string }

let encryption_key_of_secret secret =
  match X.secret_of_octets secret with
  | Ok (_, public) -> Ok { secret; public }
  | Error e -> Error (Format.asprintf "x25519 secret: %a" Mirage_crypto_ec.pp_error e)

let x25519_shared ~secret ~public =
  match X.secret_of_octets secret with
  | Error e -> Error (Format.asprintf "x25519 secret: %a" Mirage_crypto_ec.pp_error e)
  | Ok (s, _) -> (
      match X.key_exchange s public with
      | Ok shared -> Ok shared
      | Error e -> Error (Format.asprintf "x25519: %a" Mirage_crypto_ec.pp_error e))
