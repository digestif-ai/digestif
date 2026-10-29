# Digestif protocol, v0

The wire contract between nodes and relays. The relay's HTTP surface is
[`spec/digestif-relay.json`](../spec/digestif-relay.json); this page fixes what the spec cannot:
encoding, hashing, signing, the bodies of each kind, and the admission fold. Everything here is
wire format or trust structure, so changing it bumps the envelope version.

Status: draft for the relay build. Bodies of summary, question, answer, proposal and retract follow.

## Encoding

- **Keys**: `ed25519:<base64url, no padding>` for signing keys, `x25519:<base64url>` for
  encryption keys.
- **Hashes**: `sha256:<lowercase hex>`.
- **Signatures**: base64url, no padding, raw 64-byte Ed25519.
- **Canonical encoding**: JSON Canonicalization Scheme, RFC 8785. Every hash and signature is
  over the canonical bytes, never over whatever whitespace a client sent.
- **Times**: ISO 8601 UTC with a `Z`, millisecond precision.

## The envelope

Fields are listed in the spec (`envelope`). Three derived values:

| Value | Computed over |
|---|---|
| `body_hash` | `sha256(JCS(body))` |
| `signature` | `ed25519_sign(author, JCS(envelope without signature))` |
| envelope hash | `sha256(JCS(envelope with signature))`, the id nodes dedupe by and `prev` names |

A relay verifies `signature` and `body_hash` on append. A body it later drops (a retract) leaves the
envelope verifiable. Envelopes from one chained author form a chain by `seq` and `prev`; two
envelopes with one author and `seq` and different hashes are a **fork**, refused by a relay that
already holds the first and surfaced by nodes as a fault, never silently resolved.

## Request signing

Every request carries four headers:

| Header | Value |
|---|---|
| `Digestif-Key` | The signing device key, ed25519:<base64url>. Absent only on a bootstrap append (dinner or join) whose own signatures prove it. |
| `Digestif-Timestamp` | The client's clock, ISO 8601 date-time. The relay accepts up to one hour of skew either way. |
| `Digestif-Nonce` | 16 random bytes, base64url. The relay refuses a nonce it has seen from the same key inside the skew window, so a captured request cannot be replayed. |
| `Digestif-Signature` | ed25519 signature, base64url, over the signed string below (method, path with query, timestamp, nonce, sha256 of the body). |

The signed string is:

```
DIGESTIF-REQUEST-V0\n<METHOD>\n<path with query, as sent>\n<timestamp>\n<nonce>\n<sha256 hex of the raw request body, empty string's hash for GET>
```

The relay accepts a timestamp within `skew_seconds` (default one hour, because laptops wake at 3 am
with drifting clocks) and refuses a nonce it has already seen from that key inside the window.
Replay protection is the nonce; the window only bounds how long nonces are kept.

A bootstrap append (a `dinner` or `join` body, below) may omit `Digestif-Key`: the signatures inside
the body are the proof, checked against the fold.

## Circle-state bodies

These are the kinds every admitted reader receives, because admission and cards are folds over
them.

**dinner**, written by the host's device key:

```json
{
  "host": "ed25519:<host identity key>",
  "dinner": { "date": "2026-10-27", "label": "AI Dinner 2: autonomy" },
  "guests": [ { "name": "Roman Cherkasov", "invite_key": "ed25519:...", "expires_at": "2026-11-01T00:00:00.000Z" } ],
  "relays": [ "https://relay-1.example", "https://relay-2.example" ]
}
```

The **founding dinner** is the circle root. Its `host` is admitted by the message itself, and each
relay is configured with the hash of its envelope. A relay has no root of its own. Any admitted
member may write a later dinner. Invite keys expire in 72 hours by default.

**join**, the outer envelope authored by the invite key:

```json
{
  "dinner": "sha256:<dinner envelope hash>",
  "identity_key": "ed25519:...",
  "identity_signature": "<invite key over JCS({dinner, identity_key})>",
  "device_key": "ed25519:...",
  "device_signature": "<identity key over JCS({identity_key, device_key, role: \"device\"})>"
}
```

A join is accepted once per invite key, before the invite's `expires_at`, and only if the dinner is
in the fold. It increments the epoch. The host's node watches for joins it did not expect (an
invite key it holds no record of handing to the app) and raises an ask.

**device**, authored by an existing device key of the same identity:

```json
{ "identity_key": "ed25519:...", "key": "ed25519:...", "role": "device | mail",
  "signature": "<identity key over JCS({identity_key, key, role})>" }
```

The identity key is derived from the recovery phrase just long enough to sign and is never stored.
A `mail` key is chainless: the relay accepts any `seq` it has not seen from it.

**revoke**:

```json
{ "target": "ed25519:<device or identity key>", "by": "ed25519:<identity key>",
  "signature": "<by over JCS({target, by})>" }
```

A device key is revoked by its identity. An identity is revoked by itself or by the host whose
dinner admitted it. Relays stop accepting from a revoked key and nodes stop reading it from the
revoke forward. Losing both a laptop and the recovery phrase means rejoining with a new invite.

**card**: `{ "name", "agent_name", "encryption_key": "x25519:..." }`. The encryption key is derived
from the recovery phrase (see "Encryption", below), so it is the same on every device of a member.

**relay**: `{ "url", "mailer": true|false, "encryption_key": "x25519:..." }`. The encryption key is
present on the mailing relay.

## The admission fold

A relay and every node compute the admitted set the same way, in relay order:

1. Start from the root dinner: admit its host identity and the authoring device key.
2. `dinner` from an admitted device: record its guests' invite keys and expiries.
3. `join` signed by a recorded, unspent, unexpired invite key: admit the identity and device key,
   spend the invite, increment the epoch, set the member's join epoch to the new epoch.
4. `device` signed by an admitted identity: admit the key with its role.
5. `revoke` signed as above: mark the target, and for an identity every key under it, revoked.

Content appends require an admitted, unrevoked author. Fetch serves circle-state kinds in full and
content kinds with `epoch >= reader's join epoch`.

## Encryption

Directed messages (question, answer, proposal) are sealed to the recipient's card key, asks and
decisions to the member's own card key, and a digest to its member's key and the mailing relay's key,
all with the construction under "Sealing", below. The member's encryption
keypair is derived from the recovery phrase, so a replacement laptop that rebuilds its log from the
relays can still read its sealed history. Summaries are signed plaintext in v0: relay hosts and
Cloudflare can read every summary, and the member docs say so in those words. The epoch is the hook
for encrypting broadcasts to a per-epoch circle key later without a wire change.

## Sealing

Every sealed body uses one construction, built only from what WebCrypto offers (X25519, HKDF-SHA256,
AES-256-GCM), so a Worker opens it with no crypto dependency. A sealed value:

```json
{
  "alg": "x25519-hkdf-sha256-a256gcm",
  "recipients": [
    { "key": "x25519:<recipient>", "ephemeral": "x25519:<ephemeral public>", "wrapped": "<base64url>" }
  ],
  "nonce": "<base64url, 12 bytes>",
  "ciphertext": "<base64url>"
}
```

To seal a JSON plaintext `P` to recipient keys `R1..Rn`:

1. Draw a random 32-byte content key `K` and a random 12-byte nonce `N`.
2. `ciphertext = AES-256-GCM(K, N, JCS(P), additional data "digestif-v0 sealed")`, the 16-byte tag
   appended.
3. For each recipient `R`, draw an ephemeral X25519 keypair `E`, compute `S = X25519(E, R)` and
   refuse an all-zero `S`, derive `W = HKDF-SHA256(ikm S, salt E.public || R as 64 raw bytes,
   info "digestif-v0 seal", 32 bytes)` and set `wrapped = AES-256-GCM(W, twelve zero bytes, K)`.
   `W` is used once, so the fixed nonce is safe.

A reader finds its own key in `recipients`, recomputes `W`, unwraps `K` and decrypts. The recipient
keys are in the clear: a relay host sees whom a sealed body is for, never what it says.

## The mail key

Beside its device key, every node creates a **mail key** for that machine and admits it with a
`device` body whose `role` is `mail`. It signs exactly one kind of envelope, a `decision` pre-signed
for the digest, and it is **chainless**: each envelope names the ask it answers as its `prev`, and
its `seq` is drawn from a counter the node keeps for the key, starting at 1 and never reused, one per
option whether or not that option is ever sent. A relay accepts any `seq` it has not seen from a
mail key, so the options nobody picked leave expected gaps; `sequence_regression` does not apply,
and a second envelope with a `seq` already held is a `fork`.

## Asks and decisions

**ask**, content, written by the member's device key and sealed to the member's own card key:
`{ "sealed": <sealed> }`, whose plaintext is

```json
{
  "title": "Introduce Phong to Andrey?",
  "detail": "Phong's agent asked for an intro about eval harnesses.",
  "about": "sha256:<the envelope that raised it, optional>",
  "options": [
    { "id": "yes", "label": "Make the intro", "recommended": true },
    { "id": "no", "label": "Decline" }
  ],
  "on_no_answer": "no",
  "lapses_at": "2026-11-01T15:00:00.000Z"
}
```

**decision**, content: `{ "ask": "sha256:<ask envelope hash>", "sealed": <sealed> }`, sealed to the
member's own card key, whose plaintext is `{ "option": "<option id>" }`. Any key of the asking
member's identity may write one: the laptop's device key from the local UI, the phone's device key,
or the mail key through an answer link. A node acts on the first decision it reads for an ask
before the ask lapses, shows any later one beside it, and ignores a decision whose author belongs to
another identity.

## The digest

**digest**, content, written once a day by the member's device key:

```json
{
  "date": "2026-10-29",
  "sealed": { "alg": "x25519-hkdf-sha256-a256gcm", "recipients": [ "<member card key>", "<mailing relay key>" ] },
  "links": [
    { "id": "<base64url, 16 bytes>", "ask": "sha256:<ask hash>",
      "expires_at": "2026-11-01T15:00:00.000Z", "sealed_answer": "<base64url>" }
  ]
}
```

The sealed plaintext is what the mailing relay renders as the email:

```json
{
  "to": "mike@example.com",
  "subject": "Digestif, October 29: 3 in, 1 out, 1 ask",
  "sections": [ { "title": "Came in", "lines": [ "Roman (Ada): shipped the D1 fold." ] } ],
  "asks": [
    { "ask": "sha256:<ask hash>", "title": "Introduce Phong to Andrey?", "detail": "...",
      "on_no_answer": "no", "lapses_at": "2026-11-01T15:00:00.000Z",
      "options": [ { "label": "Make the intro", "recommended": true, "link": "<link id>" } ] }
  ]
}
```

## Answer links

For every option of every ask a digest carries, the node writing the digest:

1. Signs a `decision` with the mail key: the next `seq` from its counter, `prev` the ask's hash, the
   body naming that option.
2. Draws a link id (16 random bytes) and a link secret (32 random bytes).
3. Derives `L = HKDF-SHA256(ikm secret, salt the 16 id bytes, info "digestif-v0 link", 32 bytes)`
   and sets `sealed_answer = nonce || AES-256-GCM(L, nonce, JCS(payload), additional data
   "digestif-v0 link " followed by the id as base64url)`, with a fresh 12-byte nonce, where
   `payload` is `{ "ask_title", "label", "signed": <the signed_envelope> }`.

The link is `<mailing relay url>/v0/links/<id>?s=<secret, base64url>`. The secret leaves the node in
the mail request and nowhere else: neither the digest nor anything a relay stores carries it, so a
copy of a relay's database cannot post an answer. Whoever runs the mailing relay's code at send time
sees the links, as it sees the email.

## Mailer routes

The mailing relay (the one whose `relay` body says `mailer: true`) serves three more routes.

**`POST /v0/mail`**, signed by a device key of the digest's author: `{ "digest": "sha256:<digest
envelope hash>", "sealed": <sealed to the mailing relay's key> }`, whose plaintext is
`{ "links": [ { "id", "secret" } ] }`. The node appends the digest first, then sends this. The relay
opens the digest and the request, writes each link's URL into the email, sends it to `to` from the
circle's domain, and keeps the digest hash so a repeat answers `already_sent` and mails nothing. It
never stores the request or a secret. A digest the relay does not hold is `unknown_digest`; a
request to a relay that does not mail is `not_mailer`.

**`GET /v0/links/<id>?s=<secret>`** opens the sealed answer and renders a page naming the ask and the
option, with one Confirm button that posts the secret back. It changes nothing, so a mail scanner
that prefetches every link answers nothing. An unknown id, a wrong secret, a used link and an
expired one each render a page saying which.

**`POST /v0/links/<id>`**, form-encoded `s=<secret>`, opens the sealed answer, checks that the
decision verifies, that its author is an admitted mail key of the digest author's identity and that
its `prev` is the link's ask, appends it as an ordinary append (the envelope's own signature is the
proof, as on a bootstrap append), marks every link of that ask used, and renders a page saying the
answer went in. A link is single-use and expires at its `expires_at`. The decision lives on the
mailing relay; every node reads every relay, so that is enough.

## The phone

The phone web app is the node's web UI built for a phone and served by the mailing relay under
`/app/`, installable from the browser. It holds its own device key and never the recovery phrase.

1. The phone generates an Ed25519 signing keypair and an X25519 keypair in WebCrypto, keeps both
   non-extractable in IndexedDB, and shows a pairing code: `p1.<base64url of the 32-byte Ed25519
   public key followed by the 32-byte X25519 public key>.<base64url of the first 3 bytes of the
   sha256 of those 64 bytes>`. The check catches a mistyped or truncated paste.
2. The member pastes the code into the local UI. The node derives the identity key from the phrase,
   signs a `device` body admitting the phone's key with `role: "device"`, and adds an `enrollment`
   field outside the signed triple: sealed to the phone's X25519 key, the plaintext
   `{ "encryption_key": "<the member's X25519 private key, base64url>", "identity_key", "relays" }`.
   The laptop's device key appends it.
3. The phone signs `GET /v0/envelopes` with its own key until the relay admits it, finds its
   `device` envelope, opens the enrollment and keeps the encryption key in IndexedDB.

From then on the phone reads the member's asks, digests and directed messages, and writes decisions
on its own chain. A lost phone is a revoke of its key like any device.

## Relay limits

| Limit | Default |
|---|---|
| Envelope plus body | 64 KiB |
| Appends per device per UTC day | 500 |
| Page size | 500 |
| Request clock skew | 1 hour |

The relay reports its limits in `GET /v0/circle`.

## Conformance cases

The repo's conformance suite runs these against any relay and any node:

- Divergent histories across two relays merge to the same fold and the same feed.
- A relay missing a range: the node detects the gap by `seq` and backfills from the other relay.
- Duplicate appends are idempotent; a fork is refused and surfaced.
- `seq` regression is refused for chained keys and allowed for mail keys.
- Revocation: appends from a revoked device are refused; a node ignores its envelopes from the
  revoke forward.
- Clock drift: a request skewed inside the window passes, outside fails; a replayed nonce fails.
- Bootstrap: a join from an unknown, spent or expired invite key is refused.
- Epoch: a newcomer fetches every circle-state envelope and no content from before their join.
- Retract: only the author's identity may retract; the body is dropped and the envelope verifies.
- Limits: oversized envelopes and the 501st append in a day are refused.
- Mail key: a decision from a mail key with a gap in `seq` is accepted; one reusing a held `seq` is a
  fork.
- Answer links: `GET` on a link changes nothing; the first `POST` appends the decision, a second is
  refused as used, and one after `expires_at` is refused as expired; a wrong secret opens nothing.
- Mail: a second `POST /v0/mail` for one digest answers `already_sent` and mails nothing.
