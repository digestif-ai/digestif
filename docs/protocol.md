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

The **bootstrap read**, `GET /v0/invites/<invite key>`, is the one read a key outside the admitted
set may make. It is signed by the invite key named in the path and answers the dinner envelope,
with its body, that lists that invite key, while the invite is unspent and unexpired; otherwise
404, one answer for all three. A guest's app makes it before writing its join, because the join
names the dinner's hash and goes to every relay the dinner lists.

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
in the fold. It increments the epoch. The join's envelope is the invite key's only one: `seq` 1, no
`prev`, `epoch` 0, since the guest cannot read the circle's epoch before it is admitted; the epoch
the join creates is the fold's. The host's node watches for joins it did not expect (an invite
whose guest the host's person has not recorded hearing from) and raises an ask (see "Invites",
below).

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

## Invites

The host's node writes one invite per guest and hands it over as an **invite code** in the invite
email. The code is not signed and never travels to a relay; it is how the private half of the
invite key reaches the guest's app.

- **Secret**: 16 random bytes. The invite key's Ed25519 seed is
  `sha256("DIGESTIF-INVITE-V0\n" || secret)`, so the dinner lists the public half and only the code
  holder can sign as it.
- **Code**: the secret as 26 symbols of Crockford base32 (most significant bit first, two leading
  zero bits), then one check symbol, the secret read as a big-endian number modulo 37 in Crockford's
  check alphabet (`0`-`9`, `A`-`Z` less `I L O U`, then `* ~ $ = U`). Written in groups of four
  joined by `-`.
- **Invite text**: `<relay>/<code>`, where the relay is the first one the dinner lists, written
  without `https://` (an `http://` relay, for local testing, keeps its scheme). For example
  `relay-1.example/7KQ2-M9XA-3TRD-0BNE-W5HC-Y1PG-VJ4`.
- **Link**: `digestif://join/<invite text>`. The app takes the invite text by paste or through the
  link; nothing relies on a URL fragment or a QR code.
- **Parsing** forgives case, spaces, missing or extra `-`, `O` for `0` and `I` or `L` for `1`, and
  refuses a code whose check symbol does not match, so a mistyped code is refused rather than
  signing as a key nobody invited.

The app reads the dinner through the bootstrap read, checks that the dinner envelope verifies and
lists its invite key unexpired, writes the join, and appends it to every relay the dinner lists.

The host's node keeps a record per invite: sent, expected (the host's person recorded hearing from
the guest that they installed), joined, or revoked. Every join on one of its invites reaches the
host's person. An expected join is shown in the feed and the digest. Any other is an ask, keyed
`join:<invite key>`: confirm the identity, or revoke it. The ask lapses after 72 hours, and an
unanswered ask revokes, because a guest revoked by mistake is invited again in a minute and a
stranger left in the circle reads everything from the join forward. A second identity on one
invite (two relays each accepted a different join) is the same ask.

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
- Bootstrap read: an invite key reads the dinner that lists it; an unknown, spent or expired one,
  or a request signed by any other key, is not answered.
- Epoch: a newcomer fetches every circle-state envelope and no content from before their join.
- Retract: only the author's identity may retract; the body is dropped and the envelope verifies.
- Limits: oversized envelopes and the 501st append in a day are refused.
