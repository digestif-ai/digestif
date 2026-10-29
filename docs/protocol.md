# Digestif protocol, v0

The wire contract between nodes and relays. The relay's HTTP surface is
[`spec/digestif-relay.json`](../spec/digestif-relay.json); this page fixes what the spec cannot:
encoding, hashing, signing, the bodies of each kind, and the admission fold. Everything here is
wire format or trust structure, so changing it bumps the envelope version.

Status: draft for the relay build. Bodies of the content kinds and the mailer routes follow.

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

Every request carries `Digestif-Key`, `Digestif-Timestamp`, `Digestif-Nonce` and
`Digestif-Signature`. The signed string is:

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

A device message's authority is the identity signature inside it, so its envelope may be authored by
an admitted device of the same identity or by the new key itself. The second is how a member who
lost their only laptop gets a new one in: there is no other device left to post from.

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

Content appends require an admitted, unrevoked author.

A node reads several relays whose orders differ, so it folds the union in one order every node
agrees on: the root dinner, then every other circle-state envelope by `(created_at, hash)`, applied
in passes until a pass applies nothing. An envelope whose prerequisite has not arrived (a join
before its dinner, a device before its identity) waits for a later pass instead of failing. The
same order defines "from the revoke forward" for a node, and a join's `created_at` is what its
invite's expiry is judged against. Relays enforce both against their own clocks and append order.

## Recovery phrase

The phrase is 24 BIP39 English words (256 bits of entropy with its checksum). Both member keys
derive from the BIP39 seed, with no passphrase:

| Value | Derivation |
|---|---|
| seed | `PBKDF2-HMAC-SHA512(phrase, "mnemonic", 2048 iterations, 64 bytes)` |
| identity key | Ed25519 key whose 32-byte seed is `HMAC-SHA512(key = "digestif-v0 identity", seed)[0..32]` |
| encryption key | X25519 key whose 32-byte secret is `HMAC-SHA512(key = "digestif-v0 encryption", seed)[0..32]` |

Changing either derivation changes every member's keys, so it bumps the envelope version.

## Retract body

`{ "target": "sha256:<envelope hash>" }`. A node drops the target's body, keeps its envelope as a
tombstone that still verifies, and ignores a retract whose author's identity did not write the
target. Fetch serves circle-state kinds in full and
content kinds with `epoch >= reader's join epoch`.

## Encryption

Directed messages (question, answer, proposal) are sealed to the recipient's card key, and a digest
to its member's key and the mailing relay's key, as X25519 sealed boxes. The member's encryption
keypair is derived from the recovery phrase, so a replacement laptop that rebuilds its log from the
relays can still read its sealed history. Summaries are signed plaintext in v0: relay hosts and
Cloudflare can read every summary, and the member docs say so in those words. The epoch is the hook
for encrypting broadcasts to a per-epoch circle key later without a wire change.

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
