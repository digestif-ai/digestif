# digestif_mail

The node's half of mail and the phone (docs/protocol.md: Sealing, The mail key, Items,
The digest, Answer links, Mailer routes, The phone).

| Module | What it does |
|---|---|
| `Seal` | The one sealing construction: X25519, HKDF-SHA256, AES-256-GCM, any number of recipients |
| `Ask` | The node's own choices and the pick that answers one |
| `Link` | Pre-signs one decision per option with the chainless mail key and seals it under a link secret |
| `Digest` | Writes the digest and the `POST /v0/mail` request; `render` is the mailing relay's half |
| `Device` | Device bodies for a mail key and a phone key |
| `Phone` | Pairing codes and the enrollment that hands a phone the member's encryption key |

`webcrypto/mail.mjs` is the same constructions in WebCrypto alone, with no dependency, for the
mailing relay's Worker (opening digests, mail requests and answer links, checking a decision before
it appends it) and for the phone web app (keys, pairing code, enrollment, sealing a decision,
request signing and envelope signing). `webcrypto/mail.d.mts` types it for TypeScript callers.
`test/vectors.json` holds fixed-input outputs of the OCaml side, and `dune build @runtest` checks
that the WebCrypto side opens every one of them.

`webcrypto/deny.mjs` is the deny layer for the phone web app: the member's deny list and the built-in
detectors of `node/web/deny.ml` and `node/web/financial.ml`, matched over the text's UTF-8 bytes
with ocaml-re's character classes, so the phone refuses exactly what the node refuses.
`test/deny_cases.json` holds the cases; `node/web/test` runs every one against `Deny.check` and
`dune build @runtest` runs every one against `deny.mjs`. `webcrypto/bip39-english.mjs` is the
BIP39 wordlist it reads a recovery phrase with, checked against `node/core/bip39_english.txt`.

The library builds on `digestif_core` for canonical JSON, base64url, keys and envelopes. Callers
keep the mail key's sequence counter so no number is reused, and keep link secrets only until the
mailing relay accepts the mail request; `node/daily` (the `digestif_daily` library) is the node's
caller, and does both.
