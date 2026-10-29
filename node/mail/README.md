# digestif_mail

The node's half of mail and the phone (docs/protocol.md: Sealing, The mail key, Asks and decisions,
The digest, Answer links, Mailer routes, The phone).

| Module | What it does |
|---|---|
| `Seal` | The one sealing construction: X25519, HKDF-SHA256, AES-256-GCM, any number of recipients |
| `Ask` | Ask and decision bodies, sealed to the member's own key |
| `Link` | Pre-signs one decision per option with the chainless mail key and seals it under a link secret |
| `Digest` | Writes the digest and the `POST /v0/mail` request; `render` is the mailing relay's half |
| `Device` | Device bodies for a mail key and a phone key |
| `Phone` | Pairing codes and the enrollment that hands a phone the member's encryption key |

`webcrypto/mail.mjs` is the same constructions in WebCrypto alone, with no dependency, for the
mailing relay's Worker (opening digests, mail requests and answer links, checking a decision before
it appends it) and for the phone web app (keys, pairing code, enrollment, sealing a decision).
`test/vectors.json` holds fixed-input outputs of the OCaml side, and `dune build @runtest` checks
that the WebCrypto side opens every one of them.

Callers seed the random generator once (`Mirage_crypto_rng_unix.use_default ()`), keep the mail
key's sequence counter so no number is reused, and keep link secrets only until the mailing relay
accepts the mail request.
