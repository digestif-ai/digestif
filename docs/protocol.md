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

Fields are listed in the spec (`envelope`). `version` is 2: the revoke body carries `after_seq` and
`mail_read` (below). A relay refuses, and a node ignores, an envelope of any other version. Three
derived values:

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
| `Digestif-Key` | The signing device key, ed25519:<base64url>. Absent only on a bootstrap append (dinner, join, or a device message authored by the key it admits) whose own signatures prove it. |
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

A bootstrap append (a `dinner` or `join` body, or a `device` body whose `key` is the envelope's
author, below) may omit `Digestif-Key`: the signatures inside the body are the proof, checked against
the fold.

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

**device**, authored by an existing device key of the same identity or by the key it admits:

```json
{ "identity_key": "ed25519:...", "key": "ed25519:...", "role": "device | mail",
  "signature": "<identity key over JCS({identity_key, key, role})>" }
```

The identity key is derived from the recovery phrase just long enough to sign and is never stored.
A `mail` key is chainless: the relay accepts any `seq` it has not seen from it.

**revoke**:

```json
{ "target": "ed25519:<device or identity key>", "by": "ed25519:<identity key>",
  "after_seq": { "ed25519:<device key>": 41 },
  "mail_read": { "ed25519:<mail key>": [ "sha256:<envelope hash>" ] },
  "signature": "<by over JCS({target, by, after_seq, mail_read})>" }
```

A device message's authority is the identity signature inside it, so its envelope may be authored by
an admitted device of the same identity or by the new key itself. The second is how a member who
lost their only laptop gets a new one in: there is no other device left to post from.

A device key is revoked by its identity. An identity is revoked by itself or by the host whose
dinner admitted it. `after_seq` maps each device key the revoke stops (the target, or every device
key under a target identity) to the last `seq` of its honest chain, as the revoking node holds it; a
device key it stops and does not list has a cutoff of 0. `mail_read` maps each mail key the revoke
stops (the target, or every mail key under a target identity) to the hashes of that key's envelopes
the revoking node holds, a pre-signed answer it wrote and has not seen posted included; a mail key
it stops and does not list keeps none. A mail key is chainless,
so its author can write any `seq` and a `seq` cutoff cannot bound it: the hash list is the cutoff. A
key in `after_seq` that is not a device key the revoke stops, a key in `mail_read` that is not a
mail key it stops, an `after_seq` value that is not a non-negative integer, a `mail_read` value
that is not a list of envelope hashes, or a missing `after_seq` or `mail_read` makes the revoke
malformed. Two revokes stopping one key leave the lower cutoff, and for a mail key the hashes both
list.

Relays stop accepting from a revoked key. A node reads a revoked device key's envelopes at or below
its cutoff and none above it, wherever they fall in its merge order and whatever their
`created_at`, which is the author's clock and so the thief's once the key is stolen. A node reads a
revoked mail key's envelopes that `mail_read` lists and no others, on the same terms, so an honest
answer the revoking node had not fetched is lost with the thief's; the node fetches every relay
before it signs a revoke. The envelope size limit bounds `mail_read` to about 880 hashes across the
keys one revoke stops. Losing both a laptop and the recovery phrase means rejoining with a new
invite.

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
4. `device` signed by an admitted identity and authored by a device of that identity or by the key
   it admits: admit the key with its role.
5. `revoke` signed as above: mark the target, and for an identity every key under it, revoked, and
   record each stopped device key's cutoff from `after_seq` and each stopped mail key's from
   `mail_read`.

`card`, `relay` and `release_revocation` change no admission and require an admitted, unrevoked
author. Content appends require an admitted, unrevoked author. Fetch serves circle-state kinds in
full and content kinds with `epoch >= reader's join epoch`.

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
target.

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
- Revocation: appends from a revoked device are refused, and so is a revoke whose `after_seq` or
  `mail_read` is missing or names a key it does not stop; a node reads a revoked device's envelopes
  up to `after_seq` and a revoked mail key's that `mail_read` lists, and no others, whatever their
  `created_at`.
- Clock drift: a request skewed inside the window passes, outside fails; a replayed nonce fails.
- Bootstrap: a join from an unknown, spent or expired invite key is refused.
- Lost laptop: a `device` message authored by the new key itself is accepted when its identity
  signature verifies, and refused when it does not.
- Bootstrap read: an invite key reads the dinner that lists it; an unknown, spent or expired one,
  or a request signed by any other key, is not answered.
- Epoch: a newcomer fetches every circle-state envelope and no content from before their join.
- Release revocation: a relay serves it to every reader, a newcomer included, without checking its
  release signatures; a node records the key as revoked when a current release signer signed it and
  ignores it otherwise.
- Retract: only the author's identity may retract; the body is dropped and the envelope verifies.
- Limits: oversized envelopes and the 501st append in a day are refused.
- Mail key: a decision from a mail key with a gap in `seq` is accepted; one reusing a held `seq` is a
  fork.
- Answer links: `GET` on a link changes nothing; the first `POST` appends the decision, a second is
  refused as used, and one after `expires_at` is refused as expired; a wrong secret opens nothing.
- Mail: a second `POST /v0/mail` for one digest answers `already_sent` and mails nothing.
