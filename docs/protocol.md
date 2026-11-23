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
envelope verifiable. A node verifies both again on every envelope a relay serves, since a relay may
skip its check or forge an envelope, and records one that fails as an `invalid_envelope` fault that it
never folds or shows. Envelopes from one chained author form a chain by `seq` and `prev`; two
envelopes with one author and `seq` and different hashes are a **fork**, refused by a relay that
already holds the first and surfaced by nodes as a fault, never silently resolved.

**A refused envelope never existed.** A node keeps each envelope it signs until a relay takes it.
When a relay that reads the node as admitted refuses one of the node's own envelopes for good (a
422 `not_admitted`, `malformed`, `bad_signature`, `sequence_regression`, `too_large`,
`wrong_circle` or `retract_not_author`; never a `fork`, a 401 or a 429), and no relay holds that
envelope or any later one of its chain, the node drops it and re-signs every later envelope of the
chain one `seq` lower, each naming as `prev` the envelope now before it, the last one a relay
accepted first. The chain other nodes read has no gap and no trace of the refused envelope, so it
is never surfaced as a fault. An envelope any relay holds is never dropped or re-signed, since
another node may already have read it, and neither is a bootstrap envelope (a dinner, a join, a
self-authored `device` message), which a relay that does not know the circle yet refuses. A mail
key is chainless, so a refused mail envelope is dropped and nothing after it changes. A later
digest whose links name a choice re-signed this way is dropped rather than re-signed, since each
link's pre-signed decision names the old choice as its `prev` under a secret the node no longer
holds; the choices it carried are carried by a fresh digest, written on the node's next pass.
The node that drops one of its own envelopes records it as a `dropped_own` fault, which stays open
(`digestif faults`), since what the envelope carried is lost; the one drop resolved as it is raised
is a `device` message for a key the circle already admits, which carries nothing. A digest the node
drops this way gives back what it took as read: the next day's digest carries its notes again, and
its Inbox items are still open. DIG-202

## Request signing

Every request carries four headers:

| Header | Value |
|---|---|
| `Digestif-Key` | The signing device key, ed25519:<base64url>. Absent only on a bootstrap append (circle, dinner, join, or a device message authored by the key it admits) whose own signatures prove it. |
| `Digestif-Timestamp` | The client's clock, ISO 8601 date-time. The relay accepts up to one hour of skew either way. |
| `Digestif-Nonce` | 16 random bytes, base64url. The relay refuses a nonce it has seen from the same key inside the skew window, so a captured request cannot be replayed. |
| `Digestif-Signature` | ed25519 signature, base64url, over the signed string below (method, path with query, timestamp, nonce, sha256 of the body). |

The signed string is:

```
DIGESTIF-REQUEST-V0\n<METHOD>\n<path with query, as sent>\n<timestamp>\n<nonce>\n<sha256 hex of the raw request body, empty string's hash for GET>
```

The relay accepts a timestamp within `skew_seconds` (default one hour, because laptops wake at 3 am
with drifting clocks) and refuses a nonce it has already seen from that key inside the window.
Replay protection is the nonce; the window only bounds how long nonces are kept. A header over 128
characters is refused (`401 bad_signature`) before anything is verified. The relay checks that the
signer is admitted before it records the nonce, so a key the circle never admitted stores nothing.

A bootstrap append (a `circle`, `dinner` or `join` body, or a `device` body whose `key` is the
envelope's author, below) may omit `Digestif-Key`: the signatures inside the body are the proof,
checked against the fold. Before the fold runs, the relay refuses (`422 not_admitted`) one whose key
the circle does not know: a join whose invite key no accepted circle root or dinner lists, a
self-authored `device` whose identity was never admitted, or a `circle` or `dinner` whose author is
not an admitted device. The circle root is the one bootstrap append that rests on nothing.

The **bootstrap read**, `GET /v0/invites/<invite key>`, is the one read a key outside the admitted
set may make. It is signed by the invite key named in the path and answers the envelope (the
circle root or a dinner), with its body, that lists that invite key, while the invite is unspent and unexpired; otherwise
404, one answer for all three, and a 404 spends no nonce. A guest's app makes it before writing its join, because the join
names the dinner's hash and goes to every relay the dinner lists.

## Circle-state bodies

These are the kinds every admitted reader receives, because admission and cards are folds over
them.

**circle**, the root of a circle founded on its own, written by the founder's device key:

```json
{
  "host": "ed25519:<founder identity key>",
  "circle": { "name": "Auto dealership roll-up" },
  "guests": [ { "name": "Ashmer Aslam", "invite_key": "ed25519:...", "expires_at": "2026-11-21T00:00:00.000Z" } ],
  "relays": [ "https://relay-1.example" ],
  "admins": [ { "name": "Mike Bryzek", "key": "ed25519:<founder's admin key>", "identity": "ed25519:<founder identity key>" } ]
}
```

A `circle` is valid only as the circle root, and each relay is configured with the hash of its
envelope; any other `circle` envelope names a circle this one is not, and is refused
`wrong_circle`. Its `host` is admitted by the message itself. `circle.name` is the circle's name and
is not blank. `guests` lists the circle's first guests exactly as a dinner does, admitted by their
invite keys alone, and may be empty or absent: the founder invites everyone else later, with the
admins' signed admission, in a dinner message. A circle root carries no date and no dinner.

`admins` is the circle's own signer set, and every circle root names it: a non-empty list of
`{ name, key, identity }`, each key an ed25519 admin key, none twice. `digestif circle found` names the
founder's (the `public_key` of their `signer.json`, or `--admin-key`). Those admins, and not the
release signers, sign every later invite's `digestif-admission-v0` and every change of their own set
(Approvals), so the release signers never sign for, or learn who is in, a circle they are not in.
Only a founding dinner is judged by the release signer set. The set may start from one key, its
founder's; a change of it names at least two, as every signer-set change does. A missing or
malformed `admins` makes the root malformed, so a circle root written before the field was defined
admits nobody and its circle is founded again.

An admin entry's `identity`, optional, is the circle identity of the admin who holds the key: it is
how a relay and a node tell which member is a sitting admin, which the revoke rule reads (**revoke**,
below) and a Keep is judged by (Member review). A root naming one admin with no `identity` binds that
admin's key to its `host`, since only the founder writes the root. A `digestif-signers-v0` entry
carries the same field ([releases.md](releases.md), "Changing the signer set"), and each set change
binds every key it names afresh; an entry without one leaves its key unbound. A key is bound to one
identity, and an identity to any number of keys.

**dinner**, written by the host's device key:

```json
{
  "host": "ed25519:<host identity key>",
  "dinner": { "date": "2026-10-27", "label": "AI Dinner 2: autonomy" },
  "guests": [ { "name": "Roman Cherkasov", "invite_key": "ed25519:...", "expires_at": "2026-11-01T00:00:00.000Z",
                "admission": { "document": "<base64url>", "signatures": [ { "key": "ed25519:<release key>", "signature": "<base64url>" } ] } } ],
  "relays": [ "https://relay-1.example", "https://relay-2.example" ]
}
```

A circle founded at a dinner has that **founding dinner** as its root instead of a `circle`: its
`host` is admitted by the message itself, the circle is opened on each relay at its own address by
its founding append, and it folds exactly as a circle root does, its label read as the circle's name. A relay has no
root of its own. Any admitted member may write a later dinner, but after the circle's admission cutover a guest entry counts only
when its `admission` is a `digestif-admission-v0` every key of the signer set signed (Approvals,
below; The admission fold), so in practice the starting admin's node writes every dinner once the
admins signed its guest's admission. A dinner written to carry an admins' invite outside any dinner
takes the day it was written as its `date` and the circle's name as its `label`. Invite keys expire
in 72 hours by default, counted from when the root or the dinner is written.

**join**, the outer envelope authored by the invite key:

```json
{
  "dinner": "sha256:<hash of the circle root or dinner that lists the invite key>",
  "identity_key": "ed25519:...",
  "identity_signature": "<invite key over JCS({dinner, identity_key})>",
  "device_key": "ed25519:...",
  "device_signature": "<identity key over JCS({identity_key, device_key, role: \"device\"})>"
}
```

A join is accepted once per invite key, before the invite's `expires_at`, and only if the circle
root or dinner its `dinner` names is in the fold. It increments the epoch. The join's envelope is the invite key's only one: `seq` 1, no
`prev`, `epoch` 0, since the guest cannot read the circle's epoch before it is admitted; the epoch
the join creates is the fold's. The host's node watches for joins it did not expect (an invite
whose guest the host's person has not recorded hearing from) and raises a `join` choice (see
"Invites", below).

**device**, authored by an existing device key of the same identity or by the key it admits:

```json
{ "identity_key": "ed25519:...", "key": "ed25519:...", "role": "device | mail",
  "signature": "<identity key over JCS({identity_key, key, role})>" }
```

The identity key is derived from the recovery phrase just long enough to sign and is never stored.
A `mail` key is chainless: the relay accepts any `seq` it has not seen from it.

**revoke**:

```json
{ "target": "ed25519:<device or identity key>", "by": "ed25519:<identity key, a dinner's device key, or an admin key>",
  "after_seq": { "ed25519:<device key>": 41 },
  "mail_read": { "ed25519:<mail key>": [ "sha256:<envelope hash>" ] },
  "signature": "<by over JCS({target, by, after_seq, mail_read})>" }
```

A device message's authority is the identity signature inside it, so its envelope may be authored by
an admitted device of the same identity or by the new key itself. The second is how a member who
lost their only laptop gets a new one in: there is no other device left to post from.

A device key is revoked by its identity. An identity is revoked by itself, by the host whose dinner
admitted it, until 7 days after its join by the device key that wrote that dinner, or by any key in
the circle's admin signer set, of an identity whose own admin key is not in that set. A revoke
whose `by` is a device key is authored by that key and stops an identity only; it is how the host's
node revokes an unpicked join choice with no one at the keyboard (see "Invites"), since the identity
key needs the recovery phrase. The window keeps a device key, which lives on disk, to newcomers its
own dinner let in; evicting anyone else takes the phrase. A node judges the 7 days by the join's and
the revoke's `created_at`, a relay by its own clock.

A revoke whose `by` is an admin key is how the admins remove a member (docs/design.md, Member
review): `digestif-update remove <identity>` signs it with the admin key, which the node never
holds, and the admin's own node posts it, as it does an approval's signature. It counts when, in
the signer set the fold holds at that point (the circle root's `admins`, or the release signer set
in a circle founded at a dinner, changed by each `signer_set` that verifies against it, The
admission fold): `by` is a key of the set; no key of the
set is revoked; every key of the set is bound to an identity (circle, above); the envelope's
author is an admitted, unrevoked device of the identity `by` is bound to; and the target is an
admitted identity no key of the set is bound to. A sitting admin is therefore never revoked by
another admin: their key leaves the set first, by a `removal` approval (Approvals), and a revoke
of an identity whose key is still in the set would halt every admission and release while it
stood. A set with an unbound key revokes nobody this way, since it cannot tell a sitting admin
from a member; the next set change binds every key. A relay judges the rule by the set it folds,
from any client: a hand-built envelope and an older node's are refused alike. `after_seq` maps each device key the revoke stops (the target, or every device
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
`document` is the revocation exactly as the channel publishes it under `revocations/`, and
`signatures` is the list from its `.sig.json`. Each signature is over
`DIGESTIF-REVOCATION-V0\n<decoded document bytes>`, never over a canonical encoding, which is why the
document travels as base64url rather than as a JSON object JCS would re-encode.

Release keys are not circle keys, and a relay does not know the release signer set: it checks the
envelope and that the body has these two fields, nothing more. The same holds for `release_recall`,
below. Any member may post one, so the
member who hears of a revocation first can pass it on. A node decodes the document, honors it when
any key in its own current release signer set signed it, and records the revoked key in its update
state, after which updates halt until a signer-set change (releases.md). A revocation no current
signer signed changes nothing and is shown to the member as a fault. Appending a revocation the
circle already carries is harmless.

**release_recall**, authored by any admitted device key, has the same body:

```json
{ "document": "<base64url, no padding, of the recall document's exact bytes>",
  "signatures": [ { "key": "ed25519:<release key>", "signature": "<base64url>" } ] }
```

It carries a recall of one release ([releases.md](releases.md), "A recall") to every node within a
sync, where the channel alone takes up to a day. `document` is the recall exactly as the channel
publishes it under `recalls/`, and `signatures` is the list from its `.sig.json`; each signature is
over `DIGESTIF-RECALL-V0\n<decoded document bytes>`. A node stores nothing from it: on every update
pass it counts the circle's recalls with the channel's, each only while a key in its own current,
unrevoked release signer set signed it, and a document that does not parse is shown to the member
as a fault. Appending a recall the circle already carries is harmless.

**relay_release**, authored by any admitted device key, has the same body:

```json
{ "document": "<base64url, no padding, of the relay release manifest's exact bytes>",
  "signatures": [ { "key": "ed25519:<release key>", "signature": "<base64url>" } ] }
```

It announces one signed relay release to every node. `document` is the release's manifest
(`digestif-relay-release-v1`) exactly as its GitHub release `relay-v<version>` holds it, and
`signatures` is the list from its `manifest.sig.json`; each signature is over
`DIGESTIF-RELAY-RELEASE-V0\n<decoded document bytes>`. A relay checks the envelope and the two
fields, nothing more, as for the other two release kinds, and serves it in full to every reader, so
a node that joins after a release still learns of it. Each node judges it against its own release
signer set, and the newest relay release is the counting announcement with the highest version.
Appending an announcement the circle already carries is harmless.

**signer_set**, authored by any admitted device key, has the same body:

```json
{ "document": "<base64url, no padding, of the digestif-signers-v0 document's exact bytes>",
  "signatures": [ { "key": "ed25519:<release key>", "signature": "<base64url>" } ] }
```

It carries a change of the signer set that holds the circle's admins to every node and to the
relay: the release signer set ([releases.md](releases.md), "Changing the signer set") in a circle
founded at a dinner, or, in a circle whose root is a `circle`, that circle's own `admins`, which no release, channel or other
circle reads, and whose changes no node adopts into its update state or posts to the channel. `document` is the new set exactly as
the signers signed it, and each signature is over `DIGESTIF-SIGNERS-V0\n<decoded document bytes>`.
It is accepted under the three conditions of a signer-set change: every key of the set it replaces
signed it, every key of the set it names signed it, and that set has at least two keys, none twice
and none revoked. The release signer set is one per release channel, so a change made in one circle it judges
holds in every such circle on the channel. The node that records an approval's last signature posts it; a node that
adopts one from the channel's `signers/` and finds its circle without it posts it there too, so
every relay folds the same chain. Posting grants nothing: each node and each relay adopts it only
when it verifies against the signer set it holds, the relay starting from the
`release-signers.json` its own build carries, and a node first started by an older build reaches
the current set by folding the chain, each link checked against the set before it. A relay refuses
one without a `document` and a `signatures` list. Appending a set the circle already carries is
harmless.

**prompt**, authored by any admitted device key: `{ "suggestion": "sha256:...", "text": "...",
"change": "..." }`. It makes `text` the circle's live nightly note prompt, which every member's
note is written with from then on, in place of the release's `behaviors/prompts/nightly-note.md`.
The adopted suggestion's author's node writes it once its fold adopts the suggestion (above);
nobody else does. It is circle state so a member who joins later is served it and writes with the
same prompt. A relay checks only that `suggestion` and `text` are strings. A node takes the newest
prompt envelope that stands: when the node can read the suggestion it names (the node's member
judges it), the suggestion must be adopted in this node's own fold, written by the prompt's author,
with the same text; a node that cannot read it (it is sealed to its judges, or predates the node's
join) takes the prompt on its signature.

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

The host's node keeps a record per invite: sent, joined, or revoked. Every join on one of its
invites reaches the host's person. The first join on a sent invite is the guest the host invited,
since the fold admits a join only on an unexpired, unspent invite key: it is shown in the feed and
the digest, and nothing is asked. A second identity on an invite that already admitted one (two
relays each accepted a different join) is the node's `join` choice (Items), keyed `join:<invite key>` on the node: confirm the identity, or revoke it. Its
deadline is 72 hours after the host's node raises it, and no later than 6 days after the join's
`created_at`, and its default is revoke, because a guest revoked by mistake is invited again in a
minute and a stranger left in the circle reads everything from the join forward. The node signs that
revoke itself, with the device key that wrote the dinner (see the revoke body), so the deadline
needs no phrase and no person. A node that first acts on a passed deadline more than 7 days after
the join cannot sign it that way: it keeps the choice open, leads the digest with it, and revoking
then takes the phrase. A ledger an earlier release wrote may record an invite as `expected`, which
reads as sent, and a first-join choice an earlier release raised is answered `confirm` by the next
sync.

## The admission fold

A relay and every node compute the admitted set the same way, in relay order:

1. Start from the root, a `circle` or, for a circle founded at a dinner, a `dinner`: admit its host
   identity and the authoring device key, and record its guests' invite keys and expiries. A
   `circle` anywhere else is refused `wrong_circle`. A `circle` root sets the signer set step 2
   judges by to the keys its `admins` names.
2. `dinner` from an admitted device: record its guests' invite keys and expiries. A dinner after
   the circle's admission cutover records a guest only when its `admission` is a
   `digestif-admission-v0` naming this circle and that invite key, signed by every key of the signer
   set the fold holds at that point, and records none while a revoked key is in that set. A relay
   refuses such a dinner whole, `not_admitted`, so its writer learns at once that it admitted nobody.
   The relay's fold starts from the `release-signers.json` its own build carries, unless the root
   is a `circle`, whose own `admins` it starts from, and changes by each `signer_set` and `release_revocation` that verifies
   against the set it holds. The root is unchanged: its host is admitted by the message itself, and
   its guests by their invite keys.
3. `join` signed by a recorded, unspent, unexpired invite key: admit the identity and device key,
   spend the invite, increment the epoch, set the member's join epoch to the new epoch.
4. `device` signed by an admitted identity and authored by a device of that identity or by the key
   it admits: admit the key with its role.
5. `revoke` signed as above, by an identity, inside the window by the device key that wrote the
   target's dinner, or by an admin key of the signer set the fold holds at that point, of an
   identity no key of that set is bound to: mark the target, and for an identity every key under it, revoked, and
   record each stopped device key's cutoff from `after_seq` and each stopped mail key's from
   `mail_read`.

6. `signer_set` from an admitted device, verified against the signer set the fold holds: the set it
   names is the one later dinners are judged by. `release_revocation` verified against that set
   marks its key revoked in it.

`card`, `relay`, `release_recall` and `relay_release` change no admission and require an admitted, unrevoked
author, as do `signer_set` and `release_revocation`.

**The admission cutover.** A circle already holds dinners that admitted guests before the rule
above, and every node and relay folds them again from the start. The relay records the circle's
head `relay_id` when it first runs the rule and serves it as `admission_cutover` in `GET
/v0/circle`: a dinner at or before that position admits as it always did, by its guests' invite
keys alone, and one after it needs a signed admission. A node judges dinners by the cutover of the
relays it reads, so a stale node's unsigned dinner after it admits nobody. Content appends require an admitted, unrevoked author. Fetch serves circle-state kinds in
full and content kinds with `epoch >= reader's join epoch`.

A node reads several relays whose orders differ, so it folds the union in one order every node
agrees on: the root, then every other circle-state envelope by `(created_at, hash)`, applied
in passes until a pass applies nothing. An envelope whose prerequisite has not arrived (a join
before its dinner, a device before its identity) waits for a later pass instead of failing. The
same order defines "from the revoke forward" for a node, and a join's `created_at` is what its
invite's expiry is judged against. A relay enforces the order by its append order, and judges a
join's expiry by who sent it:

- A join the guest sends unsigned, the bootstrap append, is judged at the relay's own clock. The
  join's `created_at` is the guest's word and nothing checks it, so a lapsed invite key cannot
  backdate its way in.
- A join an admitted, unrevoked device or mail key pushes with a signed request is judged by the
  join's `created_at`, as a node judges it. An admitted node holds only joins some relay accepted
  in time, so the push replicates a valid join to a relay that did not see it, such as a second
  relay seeded after the invite window closed. A push signed by a revoked or unknown key is
  refused `not_admitted`.

An admitted node makes that push. Each sync, after it reads a relay that admits it, it pushes to
that relay the root and every `dinner` its own fold applied that the relay did not return, unsigned, then every
such join, signed with its device key, then the self-authored `device` messages its fold applied
that the relay lacks, unsigned as their author's bootstrap would be, each in `(created_at, hash)`
order. This is how a second relay gets the members the first one admitted, and the dinners their
joins name when the host's own node never pushed one there. A replicated dinner is judged against
its host device's chain on that relay: one behind a later envelope the relay holds from that device
is refused `sequence_regression`, and the joins naming it `not_admitted`. A `device` message another device of the identity wrote
is pushed by its author's node, which that join has admitted there. A relay that refuses a
replicated envelope gets it again on the next sync; the node records a `replicate_refused` fault
with the relay's reason and never drops the envelope, which is not its own.

A relay replays its own log with the clock each join was judged at, so the split holds across a
refold. Two relays that accepted different joins for one invite are the `join:<invite key>` choice.

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

## Content bodies

**summary**, content, plaintext: `{ "text": "...", "voice": "agent", "reply_to": "sha256:...",
"stage": "active", "prompt": "sha256:...", "suggestion": "sha256:..." }`. `voice` is `person` when the member wrote it in the Post to the circle form (`/feed/new`) and `agent`
when their agent did; a reader treats a missing or unknown voice as `agent`. `reply_to`, optional,
names the message it follows. A member's note is a summary in the agent's voice.

`stage` is the author's stage when it was written (docs/design.md, Stages and the status note):
`onboarding`, `active` or `paused`. Every summary carries it, and it is how every other member
learns a member's stage, so Members shows a member Paused, or Active again after Unpause, from
their newest summary. A reader treats a missing or unknown stage as `active`.

`prompt`, on a note, is the id of the nightly note prompt that wrote it: `sha256:` and the lowercase
hex SHA-256 of the prompt's text exactly as the writer was given it, whether that is the release's
`behaviors/prompts/nightly-note.md` (trimmed) or the circle's live prompt (**prompt**, above). An
edit carries the id of the version it edited. `suggestion`, present only on a note written in two
versions for a suggestion its author judges, names that suggestion's envelope hash; with `prompt`
it is the author's pick in that suggestion's round (**suggestion**, below). A reader that does not
know either field ignores it.

A **status note** is a summary with a `status` and no `text`: `{ "status": "nothing_to_share",
"voice": "agent", "stage": "active" }`. It says nothing from the record and needs no approval,
which is what makes it safe to send unchecked, so it carries no words of its own: a reader renders
the fixed words from `status` and the author's card (the first word of its name, and its agent
name), and ignores any `text` beside a `status`. The words are the agent's, about its member, and
name the member again where a pronoun would go: a card carries no pronouns.

| `status` | Fixed words | Sent when |
|---|---|---|
| `paused` | <first name> has paused Digestif. | The member has just paused; sent at once, with `stage` `paused`. |
| `waiting_for_approval` | No note from <first name> today; it's waiting for <first name>'s approval. | The clock ran out with a note waiting whose version passed its checks. |
| `could_not_run` | No note from <first name> today; <agent name> couldn't run. | The clock ran out with the last work run failed, or a note whose first version has not passed its checks. The reason never travels. |
| `nothing_to_share` | Nothing from <first name> today. | The clock ran out with no note written since the last one went out. |

The first row that holds decides it. A reader shows a status note as one muted line under the
author's agent, named as every agent-voiced message is (Athena (Mike Bryzek's agent)), never as a
card, and a reading agent's run skips status notes in code. There is no
other daily message and no tick on the wire.

## Items

An **item** is anything one member of the circle needs another to know, answer or decide
(docs/design.md, Inbox). It is one of three kinds, by what it asks of the person reading it: a
**question**, answered in words; a **choice**, settled by picking one of its options; a
**notice**, which asks nothing. Three envelope kinds carry an item and what is done to it, `item`,
`item_answer` and `item_close`, and a pick on a choice is a `decision` (Picks, below). Everything
else about an item is one reader's own and never leaves their node: a draft before it is sent,
the reader's status (New, Read), their Archive, and what their agent's reading
run did with it (Reviewed and its review line).

### To

Every item is addressed to the circle or to named members, and the body says which:

- **The circle**: `{ "to": "circle", "item": <item> }`, signed plaintext like a summary. Every
  admitted reader whose join epoch is at or before the envelope's reads it, and relay hosts can
  read it too, as they read every summary. The author's node passes the item through the deny
  layer before signing, as it does a note.
- **Named members**: `{ "to": [ "ed25519:<identity>", ... ], "sealed": <sealed> }`, sealed (see
  "Sealing") to each named member's card key and the author's own, whose plaintext is the item.
  `to` names the identities in the clear, as the recipient keys already do. It never names the
  author, except on an item addressed to the member alone (their node's own items, and work from
  their agent), whose `to` is their own identity and nothing else. An empty `to` is malformed.

### The item

```json
{
  "kind": "choice",
  "subject": "behavior",
  "voice": "agent",
  "title": "Install Roman's eval-harness behavior?",
  "detail": "It runs the eval suite before each note and names regressions in Stuck on.",
  "about": "sha256:<the envelope it came from, optional>",
  "quote": "<the words of that envelope that produced it, optional>",
  "options": [
    { "id": "install", "label": "Install" },
    { "id": "not_now", "label": "Not now", "recommended": true }
  ],
  "default": "not_now",
  "deadline": "2026-11-13T15:00:00.000Z"
}
```

- `kind` is `question`, `choice` or `notice`. A node ignores an item of a kind it does not know,
  since it cannot tell what the item asks of its reader.
- `title` is a non-empty string and `detail` a string, empty when the title says it all.
- `voice` is who wrote the words that went out: `person` when the member wrote them, or edited
  their agent's draft before sending it; `agent` when their agent did, whether the agent sent it
  within its guards (docs/design.md, The Inbox agent) or the member sent the draft unchanged;
  `node` when the member's node did. An item in the `node` voice is always addressed to the member
  alone. A reader treats a missing or unknown voice as `agent`.
- `subject`, optional, names which of the circle's uses the item serves (the table below). The
  node's code acts on a subject (installing a behavior, unpausing); a reader that does not know one
  shows the item by its kind alone. A new subject needs no envelope version.
- `about`, optional, names the envelope the item came from: the note whose Questions part asked
  it, or the message a work notice or a credit was written from.
- `quote`, optional and only beside `about`, is the words of that message that produced the item,
  as the message holds them: the question as the note's Questions part asks it, or the passage the
  Inbox agent took a work notice, a practice or a credit from. A reader holding that message shows
  the paragraph around the words with them marked, and only the link when the message does not
  hold them; it never shows a quote alone. A share, an intro and a behavior carry none, since they
  reach members the message may never have reached. A reader that does not know the field ignores
  it, as it does any field it does not know.
- On a `credit` only: `adopted`, optional, how the idea was adopted: `as_work` (filed in the
  member's tracker) or `as_how_agent_works` (saved, as one line, to their agent's practices). A
  reader branches on it and reads a credit with none as `as_work`. Another subject never carries
  it.
- On a `work` notice and a `credit` only: `link`, optional, where the idea was filed, or already
  was: a URL, an owner/repo#n or a tracker key such as ISS-120. A reader shows a URL or an
  owner/repo#n as a link and a key as text. Another subject never carries it, and a reader that
  does not know the field ignores it.
- On a choice only: `options`, at least two, each with an `id` unique within the item, a `label`,
  and `recommended` on at most one; `default`, the id of the option that stands with no pick; and
  `deadline`, optional, when the default takes effect, in the Z form (Encoding, Times) with no
  fraction or a fraction of one to three digits; seconds of 60, an offset, no zone and a bare date
  are not that form. A choice whose
  `deadline` is present and not in the Z form is malformed. A choice with no `deadline` stands on
  its default for as long as nobody picks. The subject sets both, never the person writing the item.
  A choice whose `default` names no option is malformed.
- An item whose envelope's `created_at` is not in the Z form (Encoding, Times) is malformed, of
  every kind: a question's lapse is counted from it. No reader shows it, and nothing on it counts.

The agent's words of a draft its member edited stay on the author's node, beside the item: the
wire carries only what was sent, so words the member took out never reach a reader.

| `subject` | Kind | Written by | To |
|---|---|---|---|
| none | question or notice | the member, on Post | the circle or named members |
| `note_question` | question | the agent, from its note's Questions part, sent with the note; `about` names the note | the circle |
| `intro` | notice | the agent's draft, sent by the member | the two members it introduces |
| `share` | question or notice | the agent's draft, past the member's Rules, sent by the member | the members it reaches |
| `work` | notice | the member's Inbox agent; `about` names the message it came from | the member alone |
| `practice` | notice: "Adopted a practice from <member>: <the practice>" once the member's agent adopted it, and for several lines one run adopts from one message one notice, "Adopted <n> of <member>'s practices", its detail one line per practice; else the node's choice "A practice you could adopt, from <member>: <the practice>", Adopt or Not now, default Not now a week after the run, its detail saying that Adopt also credits the member, or keeps that credit as a draft. Adopt saves it as the agent's adopting does. `about` names the message it was seen in | the member's Inbox agent; the choice, the node | the member alone |
| `credit` | notice: "<member> is adopting your idea: <the idea>", with `adopted`. `as_work`: the idea's title, its detail naming the author's message of that day, what was taken from it when the agent says (one line, sent only when the checks pass it whole), and the link to the work its agent filed. Several ideas one run filed from one message are one `as_work` credit, "<member> is adopting <n> of your ideas", with no `link`: its detail is the message's day and then one line per idea, its title, the link to the work filed for it and what was taken, and a reader shows it as it shows any credit's title and detail. `as_how_agent_works`: the line saved, its detail "Taken into how their agent works, from your <note or item> of <day>.", no link, sent only once the line is saved; several lines one run saves from one message are one `as_how_agent_works` credit, "<member> is adopting <n> of your ideas", its detail "Taken into how their agent works, from your <note or item> of <day>:" and then one line per practice saved, sent only when every line's own credit would have been, else one draft. `about` names the message the idea came from | the member's Inbox agent, sent within its guards, else a draft the member sends | the idea's author |
| `behavior` | choice: Install or Not now, default Not now | the agent's draft, sent by the member who shares it | the circle or named members |
| `suggestion` | choice: the suggested prompt or the current one, picked blind (Prompt suggestions, below) | the member, on Post | the suggestion's judges |
| `join` | choice: confirm or revoke, default revoke (Invites) | the node | the member alone |
| `paused` | choice: Unpause or Stay paused, default Stay paused | the node | the member alone |
| `note_ready`, `could_not_run`, `pause_coming` | notice, each saying only what the digest line it replaces says | the node | the member alone |
| `repositories` | notice | the node | the member alone, and local |
| `folder_access` | notice: "Digestif cannot open <folder>, where <n> of your session projects are", one per folder (Folder access, docs/design.md) | the node | the member alone, and local |
| `skipped_projects` | notice: how many projects the newest reading did not read, and each folder it could not judge with why, leaving out a folder a `folder_access` notice already tells of | the node | the member alone, and local |
| `inbox_agent_failed` | notice: "Your Inbox agent's last run failed.", its detail the error in the member's words; one a failure streak, reworded in place by a later failure of it, settled once a run succeeds; its `path` the run's log, `/settings/inbox-agent/log` | the node | the member alone, and local |
| `send_invite` | notice: "Send <guest>'s invite.", one per invite every admin signed, on the node that wrote its dinner (Approvals); its page shows the email the admins signed with its install command and expiry filled in and its `mailto:` link, rendered from the host's ledger when it is read and never stored in the item. settled once the member marks it sent, or once the guest joined, the invite was revoked or it expired | the node | the member alone, and local |

**A local item is never on the wire.** Local is a property of the subject, fixed in the node's
code and never set per item: `repositories`, `folder_access`, `skipped_projects`,
`inbox_agent_failed` and `send_invite` are the local subjects, because their words could name what
is on the member's machine or, for `send_invite`, carry an invite code. A node never appends a
local item, never writes a `decision` on one and never carries one in a digest.

### Prompt suggestions

A member suggests a whole nightly note prompt as a choice whose subject is `suggestion`: `title`
is one line saying what it changes, `detail` is the prompt and keeps the `{{always_on_rules}}`
placeholder, `options` are `suggested` and `current`, `default` is `current`, and there is no
`deadline`. It is addressed to the members who judge it beside its author, sealed to them like
every named item; its author always judges it and is never named in `to`, except on a suggestion
only they judge, whose `to` is their own identity. Its envelope hash is the suggestion's id, and
the author withdraws it with a retract.

Every judge's node folds the same suggestion and picks out of the same record, so every judge
reaches the same outcome. A **pick** is a note whose `suggestion` names it, signed by a judge
after the suggestion's `created_at`: the suggested version when its `prompt` is the id of the
suggestion's text, the current version otherwise. A decision naming a suggestion counts for
nothing: the judge picks blind, on the note's approval page. A **round** is each judge's next pick
in order: round 1 is each judge's first pick, round 2 each one's second. A round is decided once
every judge has picked in it: every pick the suggested version adopts the suggestion, every pick
the current one closes it as not adopted, and a split runs the pair again in the next round. The
choice closes when a round decides it. A judge's notes judge one suggestion at a time, the oldest
still judging that names them; a later one waits, New in their Inbox. A retracted suggestion is
withdrawn, and a pick after its decision counts for nothing. Adoption is circle-wide: the author's
node writes the `prompt` envelope (Content bodies) and every member's note is written with it.

### Answers

**item_answer**, content, answers a question, or replies to a notice or a choice, in the words of one
of its readers: anyone it is addressed to, or its author adding to their own item. A reply joins the
item as an answer does, so a conversation is one item. Its body follows the item's To:

- On a circle item, signed plaintext through the deny layer: `{ "item": "sha256:<item
  envelope hash>", "text": "...", "voice": "person" }`.
- On a named item: `{ "item": "sha256:...", "to": [ ... ], "sealed": <sealed> }`, where `to`
  is the item's own and the body is sealed to every reader of the item (the identities
  `to` names and the item's author), whose plaintext is `{ "text": "...", "voice": "person" }`.

`voice` is `person` when the answerer wrote it and `agent` when their agent answered within their
brief and Rules (docs/design.md, The Inbox agent); a reader treats a missing or unknown voice as
`agent`. A node shows an answer, on the item's page, in `GET /items/:id` and in the digest, only
when its author is a reader of the item. A node writes no answer on a question it holds closed: the
web API refuses it with `closed`. A reply on a closed notice or choice is shown and reopens nothing,
since closing is the author's (Closes, below). An answer an earlier node or a peer signed on a
question that has since closed stays listed.

Whether a follow-up counts is stored on its row when it and its item are both on the node. It
counts when the admission fold reads its envelope from its author (a device or mail key, admitted,
and not revoked or inside the revoked key's cutoff, The admission fold) and its author is a reader.
The stored result is decided again only when the fold's reading of its author's key changes, which
is a revocation with a cutoff (or an admission), and only for the follow-ups that key signed, so it
is the same on every node whatever order the envelopes arrived in and whatever the clocks say. An answer from a member who has since left keeps
counting, one signed past their cutoff does not (on a node that saw the revoke late as on one that
saw it first), and one from a key never admitted never does. A later read or a restart changes no
result.

Only a follow-up whose author is a reader is new activity. A reply is new activity for the item's
author, each member it names and each reader who has answered it, other than its own author. A
reply on a choice is not a pick and ends no wait.

A node signs no `item_answer` whose only reader is its author: the web API refuses a reply on an
item the member wrote to themselves alone with `to_self`. A reply signed by an earlier node stays listed.

**Older readers.** A node before 0.1.93 (ISS-88476) keeps a reply on a notice or a choice, lists it
in `GET /items/:id` and shows it on no page. It fails nothing. On the member's own notice or choice
it marks the item New and counts the reply as an answer, so once they open it the item is Done.

### Picks

A pick on a choice is a **decision** whose body names the choice:
`{ "item": "sha256:<choice envelope hash>", "sealed": <sealed> }`, sealed to the picker's own card
key and the choice author's, whose plaintext is `{ "option": "<option id>" }`. Any key of the
picker's identity may write one, the mail key included through an answer link, whose `prev` is
then the choice's hash. A node reads the first decision of each reader before the choice's
`deadline` (at any time on a choice with none), shows any later one beside it, and ignores a
decision whose author is not a reader of the choice or whose option the choice does not offer. A
decision whose `created_at` is not in the Z form (Encoding) counts for nothing: it is kept, and it is
neither a reader's first pick nor before any deadline. Only the pick that counts is new activity.

- A choice addressed to one member closes on that member's first pick.
- A choice addressed to several members or to the circle is each reader's own: a pick makes it
  settled for its picker and settles it for them alone. It closes when every member it names has
  picked, or at its `deadline`, where each reader who did not pick stands on the `default`. A
  circle choice closes only at its deadline.
- A `suggestion` choice closes as its rounds decide (Prompt suggestions, above), never by these
  rules.

**A choice the member settles on the machine is closed by its decision**: when an
act on the machine makes the node's own choice moot (an unpause on the machine settles the
`paused` choice), the node writes that choice's decision with its device key, naming the option
the act amounts to (`unpause`). The phone and the answer links then read the choice as picked, and
no other envelope is needed.

**An Acknowledge is a decision on a notice**, the one decision a notice takes: `{ "item":
"sha256:<notice envelope hash>", "sealed": <sealed> }`, sealed to the acknowledging member's own
card key alone, whose plaintext is `{ "option": "acknowledge" }`. It is how an Acknowledge link in
the digest (Answer links) reaches the member's node, which reads it as an Archive for that member and
for no one else; a notice's author never reads it, and a node ignores one by any other identity. On the
machine an Acknowledge stays the member's own and writes nothing.

The node's own choices are the ones the table names (`join`, `paused`), each addressed to the
member alone and sealed to their key. The node keeps what it is waiting for (the options, the
recommended one, the default and the deadline) beside the choice and acts on the first pick it
reads by any key of the member's identity before the deadline; at the deadline the default
stands. It acts on a pick exactly as it acts on an ask's decision, and a pick naming the choice
under `item` stands for a decision naming an ask under `ask` wherever "Asks and decisions" reads
one.

### Closes

**item_close**, content, closes or reopens an item. Only a key of the item author's identity
writes one; a node ignores any other. Its body follows the item's To, as an answer's does:

- On a circle item, signed plaintext: `{ "item": "sha256:...", "closed": true, "answer":
  "sha256:<item_answer envelope hash, optional>", "voice": "agent" }`.
- On a named item: `{ "item": "sha256:...", "to": [ ... ], "sealed": <sealed> }`, sealed to every
  reader of the item, whose plaintext is `{ "closed": true, "answer": "sha256:...", "voice":
  "agent" }`.

`closed` is `false` to reopen. `answer`, on a question only, names the answer that unblocked it;
one that names no answer to that question is read as absent. `voice` is `agent` when the asker's
agent closed it (docs/design.md, How a question closes) and `person` when the author did. The close
that stands is the newest `person` one by the time its `created_at` names, then hash, and with
none, the newest `agent` one. The time decides, never the text: the Z form takes zero to three
fraction digits, so `00.5Z` is later than `00Z` though it sorts before it as bytes; the others are kept beside it, so the asker's call overrules the agent's and
both stay readable. A close or reopen whose `created_at` is not in the Z form counts for nothing: it
is kept and never stands.

Some closes need no envelope, because every node reads them from the same record:

- A question with no answer seven days after its `created_at` closes by itself. Only an answer
  whose `created_at` is in the Z form (Encoding) and before that moment counts, whenever it
  reaches a node. An answer signed later, or whose `created_at` is not in the Z form, is kept and
  shown and reopens nothing; the author can still reopen the question. An answer whose `created_at`
  is not in the Z form counts for nothing on any item, a question that has not lapsed included.
  Answers are listed in time order, any whose `created_at` is not in the Z form after them.
- A choice closes as Picks says, its default standing at its deadline.
- A reopen by the author that stands starts a new week from its `created_at`. A reopened question
  closes by itself again at the end of that week unless someone other than its author answered
  inside it: an answer whose `created_at` is in the Z form, at or after the reopen and before the
  week ends. An answer signed before the week ends counts, one signed before the reopen included;
  one signed later is kept and shown and reopens nothing, as for the first week, and the author can
  reopen it again. A reopened choice keeps its deadline and closes at the earlier of its deadline
  and the end of that week, whoever has picked, since a reader reads no other reader's pick.
- A pick whose `created_at` is not in the Z form counts for nothing (Picks), so it neither settles a
  choice nor keeps one open.

A notice never needs closing; its author may close one anyway, which takes it out of no reader's
Inbox. A closed item is settled for every reader. The author withdraws an item outright with a
retract, which drops its body as for any content.

### Status on each reader's node

A reader's status is their node's alone, and nothing about it travels:

| Status | Holds while |
|---|---|
| Draft | The author has written the item and not sent it. A draft never leaves the author's node. |
| New | The item reached the reader and they have not opened it, or new activity since they last opened it: someone else who reads it answered or replied, or a pick that counts, on an item that is theirs, names them or that they answered; the clock closed their own question or choice; or they marked it unread. |
| Read | The reader opened it. Their agent's reading run never makes an item Read. |

## Approvals

An **approval** is a request every admin must sign: an invite or a change of the signer set
([releases.md](releases.md), "Approvals"). The admins are the keys of the signer set that judges the
circle's admissions: a circle root's own `admins`, or, for a circle founded at a dinner, the
release signer set. Each signs with their admin key (a release signer's is their release key), never their device key, so the approval is counted by the same
rule as a release: every key signed.

**approval**, written by the starting admin's device key:
`{ "to": [ "ed25519:<identity>", ... ], "sealed": <sealed> }`, sealed (see "Sealing") to every
admin's card key, the author's included, and, on a promotion or a replacement, to the member whose
key it adds, all named in `to` as for an item. Its id is the envelope's hash. The plaintext:

```json
{ "kind": "invite | promotion | removal | replacement",
  "created_at": "2026-11-14T15:00:00.000Z",
  "member": "ed25519:<identity, on a promotion, a removal or a replacement>",
  "document": "<base64url of the document's exact bytes, absent until a promotion's new key signs>",
  "removed_key": "ed25519:<release key, on a removal or a replacement>",
  "added_key": "ed25519:<release key, on a replacement>" }
```

A replacement names both keys before its document exists, since the new key's holder signs first
and that signature completes it. A node reads an approval that names a field it does not know.
Every admin's node files its member an Inbox item for each approval it reads (subject `approval`,
the command `digestif-update approve <id>` in its detail), settled once they answered it or it ended.

- An **invite**'s document is a `digestif-admission-v0`:

  ```json
  { "format": "digestif-admission-v0", "circle": "sha256:<circle root hash>",
    "created_at": "2026-11-14T15:00:00.000Z",
    "guest": { "name": "Priya Raman", "email": "priya@raman.dev" }, "role": "member | admin",
    "invite_key": "ed25519:<the invite key's public half>",
    "subject": "Join the Sunday circle on Digestif", "body": "<the email's body, its install command and expiry lines marked>" }
  ```

  Each signature is over `DIGESTIF-ADMISSION-V0\n<document bytes>`. The starting admin's node made
  the invite key and keeps its secret half, as a host's node does. `circle` binds the admission to
  one circle, so it is never replayed into another on the same channel.
- A **promotion**, a **removal** and a **replacement**'s document is a `digestif-signers-v0`, the
  whole new signer set ([releases.md](releases.md), "Changing the signer set"), signed over
  `DIGESTIF-SIGNERS-V0\n<document bytes>`. A promotion is the current set plus the member's key and
  a replacement the current set with one key in place of another; neither document exists until
  the new key's holder signs first, which names their key and completes it. A removal is the
  current set less one key, and the removed admin signs it too. Every entry of the document names
  its holder's `identity` (circle, above): a promotion's new entry the approval's `member`, a
  replacement's new entry the identity the replaced key was bound to, and every other entry the
  identity the current set binds its key to, so the admins' signatures bind each key afresh.

**approval_answer**, written by any of the approval's readers:
`{ "approval": "sha256:<approval envelope hash>", "sealed": <sealed> }`, sealed to the approval's
readers. The plaintext is a signature or a decline:

```json
{ "answer": "signature", "key": "ed25519:<release key>", "signature": "<base64url>",
  "document": "<base64url, only on the new key's first signature of a promotion or a replacement>" }
{ "answer": "decline" }
```

A signature is made by `digestif-update approve` with the release key and handed to the local node,
which never holds the key; a decline needs none, since it grants nothing, and is signed with the
device key alone like a pick. Every reader's node folds the answers into the approval's state:

- **Signed** once every key the document needs signed it: every key of the current set, and on a
  set change every key of the new one. The node that records the last signature posts the result:
  a `signer_set` for a set change; for an invite, the starting admin's node writes the dinner with
  the signed admission beside the guest, the next time it runs if it is offline, and puts the
  email the admins signed in front of that admin to send from their own address (a `send_invite`
  notice, Items).
- **Declined** on any reader's decline. Nothing is sent and the set stays.
- **Expired** seven days after the approval's `created_at` without the last signature, judged by
  every node from that field, so nothing polls.
- **Halted** when a revoked key enters the signer set while it waits. While a revoked key is in the
  set no node starts an approval but a removal or a replacement, and no admission counts.

A signature whose key the document does not need, or that does not verify, is ignored and shown as
a fault. An approval is never restarted in place: the starting admin starts a new one.

## Member review

A member with no note on three whole UTC days in a row is in review (docs/design.md, Member
review): every admin is asked to keep or remove them, and the member is told. Nothing on the wire
opens a review: each node works it out from the notes, the join and the newest Keep it holds. One
admin ends it for everyone, by a Keep or by a revoke signed with their admin key (**revoke**, above).

**keep**, content, written by an admin's device key:
`{ "to": [ "ed25519:<identity>", ... ], "sealed": <sealed> }`, sealed (see "Sealing") to every
admin's card key and the member's, the author's own included, all named in `to` as for an item. The
plaintext:

```json
{ "member": "ed25519:<identity of the member kept>",
  "created_at": "2026-11-19T15:00:00.000Z",
  "by": "ed25519:<the keeping admin's device key>",
  "signature": "<by over JCS({member, created_at, by})>" }
```

The plaintext is the Keep and its id is `sha256(JCS(plaintext))`, never the envelope's hash, so a
forwarded copy is the same Keep. A node honours a Keep only when `signature` verifies, `by` is an
admitted device key, and the identity `by` belongs to is bound to a key of the signer set the fold
holds at the Keep's `created_at` (the set after every circle-state envelope ordered before it). Any
other Keep, the member's own included, is ignored: it ends no review and restarts no count. A
relay checks only the envelope, as it does an item, since it cannot read the plaintext.

An admin promoted after a Keep holds no copy of it, since it was sealed to the admins of the day.
When a promotion takes effect (its `signer_set` folds), every admin's node, at its next upkeep,
posts each Keep still in force (the newest honoured Keep per member, younger than three whole UTC
days, with no note from the member since) as a new `keep` envelope sealed to the new admin and to
the forwarding admin, naming both in `to`, its plaintext unchanged; the forwarding node reads its own
copy, so it forwards each Keep to each admin once. Copies from several nodes are one Keep by its id.

## Encryption

An item addressed to named members and its answers and closes are sealed to every reader of the
item, the node's own choices and every pick to the member's own card key (a pick on another
member's choice to the choice's author's too), and a digest to its member's key and the mailing relay's key,
all with the construction under "Sealing", below. The member's encryption
keypair is derived from the recovery phrase, so a replacement laptop that rebuilds its log from the
relays can still read its sealed history. Summaries and items addressed to the circle, with their
answers and closes, are signed plaintext in v0: relay hosts and Cloudflare can read every one, and
the member docs say so in those words. The epoch is the hook
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
for the digest, and it is **chainless**: each envelope names the choice or notice it answers as its `prev`, and
its `seq` is drawn from a counter the node keeps for the key, starting at 1 and never reused, one per
option whether or not that option is ever sent. A relay accepts any `seq` it has not seen from a
mail key, so the options nobody picked leave expected gaps; `sequence_regression` does not apply,
and a second envelope with a `seq` already held is a `fork`.

## The digest

**digest**, content, written once a day by the member's device key:

```json
{
  "date": "2026-10-29",
  "sealed": { "alg": "x25519-hkdf-sha256-a256gcm", "recipients": [ "<member card key>", "<mailing relay key>" ] },
  "links": [
    { "id": "<base64url, 16 bytes>", "ask": "sha256:<choice or notice hash>",
      "expires_at": "2026-11-01T15:00:00.000Z", "sealed_answer": "<base64url>" }
  ]
}
```

The sealed plaintext is what the mailing relay renders as the email:

```json
{
  "to": "mike@example.com",
  "subject": "Digestif, October 29, 2026",
  "inbox": [ ... ],
  "sections": [ { "title": "Came in", "lines": [ "Roman (Ada): shipped the D1 fold." ],
                  "urls": [ "http://127.0.0.1:7070/feed/sha256:<note hash>" ] } ]
}
```

A section's optional `urls` links each line, by position, to its page on the member's machine,
`null` where a line has none; a section with no linked line omits it. **Came in** and **Went out**
link each note to its Feed page, and **Your agent did** links each review line to what the run read,
the item's Inbox page or the note's Feed page, where what the run drafted is read. A node links only
once its UI has answered at an address, since a guessed port links to nothing. A relay that does not
know the field ignores it. ISS-78222

**A digest fits one append** (`max_envelope_bytes`, 65,536 bytes). A section shows at most 40
lines and then `And N more on your machine.`; the Inbox part shows at most 20 entries, and `On your
machine` says `N more items wait in your Inbox on your machine.` for the rest, which stay open for a
later digest. A digest that still encodes past the limit is written again with half of each, down
to the counts alone. DIG-202

**The Inbox part**, `"inbox"`, lists every Draft and New item of the
member's, the count the Inbox tab shows, Draft first and then the newest. An item they have opened
is Read and stays on the Inbox page only.

```json
"inbox": [
  { "item": "item-3f9c...", "kind": "notice", "title": "Introduce Phong to Andrey",
    "line": "Draft by your agent to Phong and Andrey",
    "page": { "label": "Read the draft", "url": "http://127.0.0.1:7070/inbox/item-3f9c..." } },
  { "item": "sha256:<choice hash>", "kind": "choice", "title": "Digestif paused. Unpause?",
    "line": "Choice from your node", "default": "stay_paused",
    "options": [ { "id": "unpause", "label": "Unpause", "recommended": true, "link": "<link id>" },
                 { "id": "stay_paused", "label": "Stay paused", "link": "<link id>" } ] },
  { "item": "sha256:<notice hash>", "kind": "notice",
    "title": "Your first note is ready on your machine.", "line": "Notice from your node",
    "acknowledge": { "link": "<link id>" } }
]
```

- `item` is the item's id on the member's node (its envelope hash once sent); `line` says who wrote
  it, to whom, and how many answers a question has.
- A draft and a question carry `page`, the item's page on the member's machine, where the words are
  read before anything is sent: a draft is sent only from there, and a question is answered there.
- A choice carries `options`, each with an answer link that picks it (Answer links), and `default`
  and `deadline` as the choice has them. A `suggestion` choice is picked blind on the note's
  approval page, so it carries `page` instead.
- A notice carries `acknowledge`, one answer link that writes its Acknowledge (Items, Picks).
- A local item never leaves the machine as an envelope, so nothing can answer it from the mail: the
  digest carries its title, which says only a count (`1 new repository waits for you on your
  machine.`), with `page` and no link. A `folder_access` notice's own title names its folder, so the
  digest carries it under a title its subject fixes, `Digestif cannot read some of your sessions on
  your machine.`, which names nothing.
- **A notice that needs the member says where and what** (DIG-355). Each of the node's notices that
  expects the member to act, `repositories`, `note_ready`, `could_not_run` and `pause_coming`, is an
  Inbox item whose `path` holds the page on the member's machine where they act (Settings,
  Repositories for `repositories`, the Feed for a note and for a run that could not) and whose
  `detail` holds one line of instruction (`Decide whether Digestif may read it. Nothing is read until
  you say so.`). Both are fixed by the subject and never carry a name, a path or the kind of a
  failure. A notice raised before it carried a `detail` reads the line its subject fixes. Only the
  member's own node's notice carries a `path`; a node notice indexed from a peer carries none. The
  digest entry is unchanged. The Inbox shows `path` as **Open on your machine** when it is read on
  the node's own machine, and anywhere else as the page's label with `address`, the node's own URL
  (the port it bound) followed by `path`, to type on that machine.
  Archive takes a notice the member has read and will not act on out of their Inbox.
- **The projects a reading skipped** (ISS-81609) are one `skipped_projects` notice, local: its
  `title` is a count (`2 projects were not read: Digestif could not look at a folder they are
  in.`), the one line the digest carries, and its `detail` names each folder and why (no access,
  with the step that grants it; too many entries; took too long to list; could not be read). It is
  the one notice whose `detail` names what is on the machine, so it has no `path` and is never
  handed to Ask your agent. The newest reading by either reader replaces the one before. The same
  folders skipped for the same reasons are told once; a folder or reason not told before makes it
  New again; a reading that skips nothing settles it by itself.
- **Ask your agent** hands such a notice to the member's agent as one plain-text message, with the
  member's Inbox prompt above it. For a "1 new repository" notice it reads, line for line:

  ```
  The member asks you about one notice in their Inbox.
  Item id: item-3f9c...
  Kind: notice
  Title: 1 new repository waits for you on your machine.
  What the member does there: Decide whether Digestif may read it. Nothing is read until you say so.
  Page: /settings/repositories/edit
  Address, on the member's machine: http://127.0.0.1:7420/settings/repositories/edit
  Do not open anything: you cannot. Say where the member should act and how, in a few short steps, or what you would do and what you need from them.
  ```

  The `What the member does there` line is the fixed text the notice's subject gives (the item's
  instruction) and is left out for a subject with none. Those lines are all there is: only fixed
  strings and the title of a notice from the member's own node, never peer text and never the item's
  stored detail. The agent runs with no tools (or read-only), so it cannot open the page, and is
  asked where and how the member should act, not to open anything. The delivery is local (DIG-378).
  The agent is the program already connected on Setup, and the node runs it on the machine, in a
  process group of its own, through `POST /items/<id>/ask-agent`. Nothing leaves the machine, so no
  relay carries it and no envelope is signed. The route answers 202 at once, and the run has ten
  minutes, after which its whole process group is killed. Stopping the node kills it too and fails
  the ask; the group is also kept with the ask, so after a crash the next start kills what is left
  of it before failing the ask. The item then carries `agent_ask`, with a `status` of `asked`,
  `answered` or `failed` and the agent's answer, or `Your agent did not answer (<reason>).`, as its
  `reply`, also when the agent could not be started. The reply is kept on the machine alone: the
  notice is addressed to the member, and a signed reply would be the circle's. It is dropped once
  the item is settled. An item that is not a notice from the node with a page answers 422
  `not_askable`, and that is told before a node with no agent connected answers 422 `no_agent`.

A node writes a digest in every stage, Onboarding and Paused included, and only on a day with an
Inbox item or a section in it. **What the digest said On your machine is a notice from the node**:
new repositories waiting (local), a note ready to approve (`note_ready`), a run that could not
(`could_not_run`) and a pause coming (`pause_coming`), each raised once, on the day it happens, in
the words the line had, each saying only what the circle could already know (a count and never a
name; never the kind of failure). **Came in** and **Went out** give each note one line, its
author and the note's first line of content, the line the Feed previews, never a bare heading: a
note holding only headings reads `an empty note.`, and a status note says what its status means.
The **On your machine** section keeps the lines that are not
items: a relay rollback, a prompt suggestion's round, a relay deploy. The digest's last section is
**Your agent did**: the review lines the member's agent's reading runs wrote since the last digest
on what reached the member (docs/design.md, The Inbox agent), each `<member>'s <kind>: <review>`. The
subject is the date alone, year included, `Digestif, December 1, 2026`, in every stage; a paused member's digest says so
as the first line On your machine. The mailing relay renders the Inbox part first, then the
sections, then, when the mail links to the member's machine, how such a link opens, then how to
open the app (`digestif open` on the member's machine) and the address the mail was sent to; the
body never repeats the subject. A link to the member's machine opens on that machine alone, in the
browser that last opened Digestif, whose session lasts 30 days; a browser without one shows the
line that opens the page, `digestif open '<the link>'`, since `digestif open` takes a page to land
on.

## Answer links

For every option of every choice a digest carries, and for every notice's
Acknowledge, the node writing the digest:

1. Signs a `decision` with the mail key: the next `seq` from its counter, `prev` the choice's or
   notice's hash, the body naming that option (a pick or an Acknowledge, Items, Picks).
2. Draws a link id (16 random bytes) and a link secret (32 random bytes).
3. Derives `L = HKDF-SHA256(ikm secret, salt the 16 id bytes, info "digestif-v0 link", 32 bytes)`
   and sets `sealed_answer = nonce || AES-256-GCM(L, nonce, JCS(payload), additional data
   "digestif-v0 link " followed by the id as base64url)`, with a fresh 12-byte nonce, where
   `payload` is `{ "ask_title", "label", "signed": <the signed_envelope> }`, plus `"note"` when the
   answer acts later than the click: the sentence the confirm and done pages show under the option.
   The `paused` choice's `unpause` carries "Your machine unpauses when it next syncs, or when it
   wakes."

A link's `expires_at` is its choice's `deadline`, or, for a choice with none (and for an
Acknowledge), 30 days after the digest's `created_at`. The link record's `ask` names the hash of
the item the decision answers; a relay treats every link of that hash as used once one is
confirmed, and as closed once it holds a decision of the member's naming it under `item`.

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
request to a relay that does not mail is `not_mailer`. A mailing relay mails every circle it hosts
with its one sealing key: each link's URL is under the circle's address, a circle whose root names
it carries the circle's name in the email's From name and subject, and each circle mails a member
at most two digests a UTC day (`429 rate_limited` past it), which no node reaches.

**`GET /v0/links/<id>?s=<secret>`** opens the sealed answer and renders a page naming the item and the
option, with one Confirm button that posts the secret back. It changes nothing, so a mail scanner
that prefetches every link answers nothing. An unknown id, a wrong secret, a used link, a closed one
and an expired one each render a page saying which. A link is closed when the relay holds a
`decision` naming its item by any key of the digest author's identity: the member answered on the
machine or the phone, or the machine closed the choice, and no link answers it any more.

**`POST /v0/links/<id>`**, form-encoded `s=<secret>`, opens the sealed answer, checks that the
decision verifies, that its author is an admitted mail key of the digest author's identity and that
its `prev` is the link's item, appends it as an ordinary append (the envelope's own signature is the
proof, as on a bootstrap append), marks every link of that item used, and renders a page saying the
answer went in. A link is single-use and expires at its `expires_at`. The decision lives on the
mailing relay; every node reads every relay, so that is enough.

## The phone

The phone web app is the node's web UI built for a phone and served by the mailing relay under
`/app/`, installable from the browser. It holds its own device key and never the recovery phrase.
Its circle is that relay's home circle, which it reaches at the address `GET /v0/relay`'s `home`
names (Hosted circles).

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

From then on the phone reads the member's Inbox: every `item` another member addressed to the
circle, read as the signed plaintext it is; every `item` addressed to the member by name, opened with
their key (their node's own, such as the `join` and `paused` choices, and the questions, choices and
notices other members address to them); and on each question the `item_answer`s its readers
wrote. It shows no reply on a notice or a choice.
It shows each New until it is settled, and settled once the member answered, picked or
acknowledged it, or it closed: its author closed it, a choice's deadline passed, or a question nobody
else answered reached a week; Read is the machine's own. It writes on its own chain: a pick names the
choice under `item`, sealed to the member's card key and, on another member's choice, to that
author's card key from their newest `card` (Items, Picks); an Acknowledge names the notice, sealed
to the member alone; and an answer to a question addressed to the member by name is an `item_answer` in the member's own words, `voice: "person"`, with the question's `to`,
sealed to every reader of the question by the card key of each one's newest `card` (Items,
Answers). Every answer the phone writes passes the deny layer first, as on the machine: the member's
entries from their newest `deny_list` (below), a name entry never tripping on a circle member's or
agent's name from the cards, then the built-in detectors, run by `node/mail/webcrypto/deny.mjs`, which
refuses exactly the text the machine's deny layer refuses (`node/mail/test/deny_cases.json` holds
the cases both run). A trip refuses the answer and names the rule, `Refused before signing: <rule>.`,
never the words. An answer to a circle question is the signed plaintext `item_answer`; until the
phone reads a `deny_list` it writes none, and says to answer on the machine, rather than check
against nothing.

**deny_list**, content, written by the member's node: `{ "sealed": <sealed> }`, sealed to the
member's own card key alone, whose plaintext is `{ "entries": [ { "kind": "name", "value": "..." },
... ] }`, the deny list in the order Settings lists it, its `kind` one of `name`, `domain`, `id` and
`pattern`. The node writes one whenever its list differs from the newest one a key of the member
wrote, an empty list included: on the Settings change, and at the start of every pass, whose sync
posts it, so a list a relay refused is written again. The phone reads the newest by `created_at`. Other nodes store it
and open none.

It learns the member's stage from their newest summary, so while the member is
Paused it shows the Paused page's words, and Unpause while the node's `paused` choice is open: the
phone writes that choice's `unpause` pick, which the machine acts on when it next syncs or wakes,
and the page then says so. With no open `paused` choice, after a Pause the member pressed or once the
choice is picked Stay paused, the phone shows no Unpause. A lost phone is a revoke of its key like
any device.

## Hosted circles

A relay hosts many circles, each at its own **address**, `<base>/c/<root hex>`: the relay's base url
(`https://dinners.digestif.io`) and the 64 hex digits of the circle's root hash. Every circle route
(`/v0/envelopes`, `/v0/circle`, `/v0/invites/<invite key>`, `/v0/mail`, `/v0/links/<id>`) lives under
it unchanged, and a node keeps the address as its relay url: the signed string covers the whole
path, so a request signed for one circle never verifies at another's. A root's `relays` names each
relay's base url, since the root cannot hold its own hash; a circle's `relay` message and a node's
cursors name the full address. Each circle's state lives in a store of its own, so nothing one
circle holds is ever read, appended to or admitted into another.

Three routes are the relay's own, outside every circle (and also answered under a circle's address):

- `GET /v0/version`, unsigned (Relay version).
- `GET /v0/relay`, unsigned: `{ "relay_version", "mailer": true|false, "encryption_key":
  "x25519:...", "hosting": true|false, "home": "sha256:..."|null, "last_unprefixed_at":
  "<time>"|null }`. `encryption_key` is the mailing relay's sealing key, present when `mailer` is
  true: a founding node writes the circle's `relay` message from it. `hosting` says whether the relay
  opens a new circle now. `home` is the home circle's root. `last_unprefixed_at` is the last request
  on a circle route without a circle's address (below).
- `GET /v0/invites/<invite key>`, the bootstrap read across every hosted circle: an invite key is
  random, so it names one open invite on the relay. The answer is the circle's own bootstrap read
  (Invites) with `circle`, the circle's address, beside the stored envelope; the guest's app reads
  and appends at that address from then on. An invite stays `<relay host>/<code>`.

**The home circle** is the one the relay's `HOME_ROOT` names, the operator's own, which carries the
relay's releases; a relay whose `HOME_ROOT` is unset reads its `CIRCLE_ROOT`. Like every circle's,
its routes answer only under its address: a circle route without one answers `410 circle_moved`,
whose message and `Location` header name the home circle's address, and the relay records the time
of the last such request. A freshly deployed relay has no home: `home` is `null`, it hosts nothing,
and a circle route without an address answers `404 circle_unknown`.

**Founding a circle on a relay.** A circle opens with its root's bootstrap append to `POST
<base>/c/<root hex>/v0/envelopes`, and nothing else reaches an address no circle holds (`404
circle_unknown`). The home circle's root needs nothing more. Any other root carries a voucher in the
`Digestif-Voucher` header: `<document>.<signature>`, the document's exact bytes in base64url and an
Ed25519 signature over `DIGESTIF-VOUCHER-V0\n` plus those bytes, by the key the document names. The
document is

    { "format": "digestif-voucher-v0", "root": "sha256:<the new root>", "relay": "<the relay's host>",
      "circle": "sha256:<the vouching circle's root>", "key": "ed25519:<the member's device key>",
      "expires_at": "<at most ten minutes out>" }

The relay hosts the circle when the voucher verifies, names this root and this relay's host, has not
expired and runs no longer than ten minutes, and its key is an admitted, unrevoked device key of an
open circle the relay hosts. It records which circle and which member (that key's identity there)
vouched. A founding is refused, each with its own code, as:

| Code | Status | When |
|---|---|---|
| `not_hosting` | 403 | The operator turned hosting off. |
| `not_vouched` | 403 | No voucher, or one that fails any check above. |
| `too_many_circles` | 429 | The vouching member opened the relay's per-member number of circles (5) in the last 30 days; the message names the day the next opens. |
| `relay_full` | 507 | Every hosted circle's reserved share (256 MiB each), the new one's included, would not fit in the relay's total (4 GiB). |

A circle's store holds at most its share: an append past it is `507 circle_full`. Every per-device cap
and per-address limit applies inside each circle as before.

**A suspended circle** answers `410 circle_suspended` at every route until its operator resumes it;
its nodes show that as a fault naming the relay. Suspending reads nothing a circle holds.

**The home circle's move.** A relay that served its home circle before it hosted many circles moves
that circle's log into its store on first use, keeping every `relay_id`, `received_at` and
`judged_at`, so every node's cursor and the admission cutover keep their positions. While it copies,
the relay serves the circle as before. For the seconds the copy takes to drain, an append, a mail
request and an answer-link confirm answer `503 moving` with `Retry-After: 5`, which a node retries as
any transient failure, while reads keep answering.

## Relay limits

| Limit | Default |
|---|---|
| Envelope plus body | 64 KiB |
| Appends per device per UTC day | 500 |
| Page size | 500 |
| Request clock skew | 1 hour |

The relay reports its limits in `GET /v0/circle`. An append whose `Content-Length` is over the
envelope limit is refused (`422 too_large`) before its body is read, and one with no length is
refused as soon as the bytes read pass it. A deployed relay also caps `POST /v0/envelopes` per client
address (120 a minute), answering `429 rate_limited` past it; a node retries a 429 later.

## Relay version

`relay_version` is the relay release a relay's Worker was built as, a `MAJOR.MINOR.PATCH` string.
The build stamps it; a Worker built without a stamp reports no `relay_version` field at all, never
an empty one. Two reads report it, always the same value:

- `GET /v0/circle`, beside the limits, signed like every member read.
- `GET /v0/version`, unsigned: `{"relay_version":"0.1.1"}`, or `{}` from an unstamped Worker. The
  version is public by construction (the signed bundle, the channel index, the release tag), so a
  person checking a deploy or an uptime probe reads it with no member's key. It carries nothing
  else; the admitted keys stay behind the signed `GET /v0/circle`. `GET /v0/relay` (Hosted circles)
  reports it too, beside what a founding node reads unsigned.

## Conformance cases

The repo's conformance suite runs these against any relay and any node:

- Divergent histories across two relays merge to the same fold and the same feed.
- A relay missing a range: the node detects the gap by `seq` and backfills from the other relay.
- Duplicate appends are idempotent; a fork is refused and surfaced.
- Verification: an envelope a relay serves whose signature does not verify, whose body does not
  match its `body_hash`, or whose `author` did not sign it, is an `invalid_envelope` fault on the
  node, never folded or shown.
- `seq` regression is refused for chained keys and allowed for mail keys.
- Revocation: appends from a revoked device are refused, and so is a revoke whose `after_seq` or
  `mail_read` is missing or names a key it does not stop; a node reads a revoked device's envelopes
  up to `after_seq` and a revoked mail key's that `mail_read` lists, and no others, whatever their
  `created_at`.
- Host device revoke: the device key that wrote a dinner revokes an identity a join on that dinner
  admitted, within 7 days of the join; any other device key, a device key target, or a revoke after
  the window is refused.
- Admin revoke: a revoke signed by an admin key of the circle's signer set, every key of which is
  bound to an identity, and authored by a device of the identity its key is bound to, revokes a
  member whose identity holds no key of the set; one of an identity a key of the set is bound to, by
  a key outside the set, or authored by another member's device is refused.
- Keep: a relay accepts a `keep` from an admitted author as content, checking only the envelope, and
  serves it, its sealed body intact, to a reader admitted before it; a node honours a Keep only from
  a device of an identity bound to a key of the signer set at its `created_at`, and ignores any
  other.
- Clock drift: a request skewed inside the window passes, outside fails; a replayed nonce fails.
- Bootstrap: a join from an unknown, spent or expired invite key is refused.
- Pushed join: a join an admitted, unrevoked key pushes is judged by its `created_at`, so it is
  accepted after its invite's expiry when it was created before it; one created after it, or
  pushed by a revoked key, is refused. A node admitted on a relay pushes it the joins another
  relay accepted and it lacks, with their members' self-authored `device` messages.
- Lost laptop: a `device` message authored by the new key itself is accepted when its identity
  signature verifies, and refused when it does not.
- Bootstrap read: an invite key reads the dinner that lists it; an unknown, spent or expired one,
  or a request signed by any other key, is not answered.
- Epoch: a newcomer fetches every circle-state envelope and no content from before their join, and their node reports no gap for that content.
- Release revocation: a relay serves it to every reader, a newcomer included, without checking its
  release signatures; a node records the key as revoked when a current release signer signed it and
  ignores it otherwise.
- Relay release: a relay serves it to every reader, a newcomer included, without checking its
  release signatures, and refuses one without a `document` and a `signatures` list.
- Signer set: a relay refuses a `signer_set` without a `document` and a `signatures` list.
- Prompt: a relay serves it to every reader, a newcomer included, and refuses one whose
  `suggestion` and `text` are not strings.
- Relay version: `GET /v0/circle` and an unsigned `GET /v0/version` report the same
  `relay_version`, a `MAJOR.MINOR.PATCH` string on a stamped relay and no field at all on an
  unstamped one.
- Items: a relay accepts an `item`, an `item_answer` and an `item_close` from an admitted author as content, checking only the envelope, and serves each, its body intact, to a reader admitted before it; an envelope of a kind the protocol does not name (`question`, `answer`, `proposal`, `ask`) is refused as malformed.
- Retract: only the author's identity may retract; the body is dropped and the envelope verifies.
- Limits: oversized envelopes and the 501st append in a day are refused.
- Mail key: a decision from a mail key with a gap in `seq` is accepted; one reusing a held `seq` is a
  fork.
- Answer links: `GET` on a link changes nothing; the first `POST` appends the decision, a second is
  refused as used, and one after `expires_at` is refused as expired; a wrong secret opens nothing.
- Mail: a second `POST /v0/mail` for one digest answers `already_sent` and mails nothing.
