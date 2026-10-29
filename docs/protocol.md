# Digestif protocol, v0

The wire contract between nodes and relays. The relay's HTTP surface is
[`spec/digestif-relay.json`](../spec/digestif-relay.json); this page fixes what the spec cannot:
encoding, hashing, signing, the bodies of each kind, and the admission fold. Everything here is
wire format or trust structure, so changing it bumps the envelope version.

Status: draft for the relay build. Bodies of the content kinds and the mailer routes follow. While
v0 is a draft, changes land in v0 itself; the first change after v0 ships bumps the envelope version.

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

A device key is revoked by its identity. An identity is revoked by itself or by the host whose
dinner admitted it. Relays stop accepting from a revoked key and nodes stop reading it from the
revoke forward. Losing both a laptop and the recovery phrase means rejoining with a new invite.

**card**: `{ "name", "agent_name", "encryption_key": "x25519:..." }`. The encryption key is derived
from the recovery phrase (see "Encryption", below), so it is the same on every device of a member.

**relay**: `{ "url", "mailer": true|false, "encryption_key": "x25519:..." }`. The encryption key is
present on the mailing relay.

**release_revocation**, authored by any admitted device key:

```json
{ "document": "<base64url, no padding, of the revocation document's exact bytes>",
  "signatures": [ { "key": "ed25519:<release key>", "signature": "<base64url>" } ] }
```

It carries a release-key revocation ([releases.md](releases.md), "Revoking a release key") to every
node, so a node whose release channel is unreachable or withholds the revocation still hears of it.
`document` is the revocation exactly as the channel publishes it under `releases/revocations/`, and
`signatures` is the list from its `.sig.json`. Each signature is over
`DIGESTIF-REVOCATION-V0\n<decoded document bytes>`, never over a canonical encoding, which is why the
document travels as base64url rather than as a JSON object JCS would re-encode.

Release keys are not circle keys, and a relay does not know the release signer set: it checks the
envelope and that the body has these two fields, nothing more. Any member may post one, so the
member who hears of a revocation first can pass it on. A node decodes the document, honors it when
any key in its own current release signer set signed it, and records the revoked key in its update
state, after which updates halt until a signer-set change (releases.md). A revocation no current
signer signed changes nothing and is shown to the member as a fault. Appending a revocation the
circle already carries is harmless.

## The admission fold

A relay and every node compute the admitted set the same way, in relay order:

1. Start from the root dinner: admit its host identity and the authoring device key.
2. `dinner` from an admitted device: record its guests' invite keys and expiries.
3. `join` signed by a recorded, unspent, unexpired invite key: admit the identity and device key,
   spend the invite, increment the epoch, set the member's join epoch to the new epoch.
4. `device` signed by an admitted identity: admit the key with its role.
5. `revoke` signed as above: mark the target, and for an identity every key under it, revoked.

`card`, `relay` and `release_revocation` change no admission and require an admitted, unrevoked
author. Content appends require an admitted, unrevoked author. Fetch serves circle-state kinds in full and
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
- Release revocation: a relay serves it to every reader, a newcomer included, without checking its
  release signatures; a node records the key as revoked when a current release signer signed it and
  ignores it otherwise.
- Retract: only the author's identity may retract; the body is dropped and the envelope verifies.
- Limits: oversized envelopes and the 501st append in a day are refused.
