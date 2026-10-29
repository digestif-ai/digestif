# Digestif conformance suite

Executable versions of every line under "Conformance cases" in [docs/protocol.md](../docs/protocol.md),
run against any relay over HTTP and against any node through a small adapter command. It is
TypeScript with no runtime dependencies: Node 23.6 or later runs the `.ts` files directly.

| Piece | What it is |
|---|---|
| `bin/digestif-conformance.ts` | The runner: `relay`, `node`, `self-test`, `fake-relay`, `circle`, `list` |
| `fixtures/test-circle.json` | The test circle root: a throwaway founding dinner with no guests. Its seeds are public, so it must never root a real circle |
| `src/fake-relay.ts` | A local relay implementing `spec/digestif-relay.json` in memory, for testing a node before a real relay is deployed |
| `bin/reference-node.ts` | The reference node behind the node adapter contract |
| `src/fold.ts` | The admission fold both of the above share |

## Running against a relay

A relay under test is configured with the test circle's root hash, the way a real relay is configured
with its circle's:

```sh
node conformance/bin/digestif-conformance.ts circle show
```

prints `root_hash` and the root dinner envelope. The suite appends the root dinner itself (a bootstrap
append), so the relay needs only the hash. Then:

```sh
node conformance/bin/digestif-conformance.ts relay --url https://relay-1.example --url https://relay-2.example
node conformance/bin/digestif-conformance.ts relay --url https://relay-1.example --case relay.clock
```

Output is TAP; the exit status is 1 when any case fails. `--case` takes an id, an id prefix
(`relay.bootstrap`) or a glob (`relay.*.refused`). With one `--url`, the cases needing two relays are
skipped.

Every case invites its own members through a dinner of its own, so a relay that already holds
earlier runs is as good a target as a fresh one, and the suite can be rerun against one deployment.
`relay.limits.daily-append-cap` makes `max_appends_per_device_per_day` appends from one fresh device
(500 requests at the default), and a run that crosses midnight UTC can fail it spuriously. Limits are
read from `GET /v0/circle`, so a relay configured with other limits is tested against its own.

## Running against a node

```sh
node conformance/bin/digestif-conformance.ts node --node "digestif conformance"
```

The node cases start three local fake relays per case, all rooted in a fresh circle: two checked
relays that play honest relays which each saw part of the history, and one unchecked relay that plays
a relay which accepted what it should not have (a join on a spent invite, a retract by the wrong
identity). The suite writes the history, runs the node's sync, and checks what the node concluded.
Without `--node` it runs the reference node.

### The node adapter contract

The suite runs the command it is given with these arguments appended:

```
sync --home <empty directory> --device-seed-file <file> --relay <url> [--relay <url>...]
```

The node starts from the empty home, signs its relay requests with the device key whose 32-byte
Ed25519 seed is in the file (base64url, no padding, one line), reads every relay in the order given,
prints one JSON object on stdout and exits 0. The device key is the test circle's host device, so it
reads everything. The object:

```json
{
  "epoch": 2,
  "keys": [ { "key": "ed25519:...", "role": "identity | device | mail", "identity": "ed25519:...", "revoked": false } ],
  "feed": [ "sha256:<envelope hash>" ],
  "faults": [ { "kind": "fork", "author": "ed25519:...", "seq": 3, "hashes": [ "sha256:...", "sha256:..." ] } ],
  "gaps": [ { "author": "ed25519:...", "missing": [ 2 ] } ]
}
```

- `epoch` and `keys` are the node's admission fold over every relay it read.
- `feed` is the content a person would see: every admitted content envelope except retracts, the
  targets of valid retracts, and both sides of a fork, ordered by `created_at` then hash.
- `faults` names every chained author holding two envelopes at one `seq`.
- `gaps` names, per device key, the `seq` numbers below its highest that no relay served. Mail keys
  are chainless and never have gaps.

`keys`, `faults` and `gaps` may come in any order; the suite sorts them. `feed` order is checked.

## Self-test

```sh
cd conformance && npm ci && npm run check && npm test
```

Every case passes against the fake relay and the reference node, and every case **fails** against a
fake relay or reference node told to skip the one rule that case is about (`FakeRelay`'s `breaks`,
`reference-node.ts --break`). The second half is what makes a pass against a real relay or node mean
something; a new case lands with the break that fails it.

## Cases

`node conformance/bin/digestif-conformance.ts list` prints the same list with each case's title.

| Protocol line | Relay cases | Node cases |
|---|---|---|
| Divergent histories | `relay.divergent.same-fold` (2 relays) | `node.divergent.same-fold-and-feed` |
| A relay missing a range | `relay.gap.missing-range-accepted` | `node.gap.backfilled-from-other-relay`, `node.gap.reported-when-unfilled` |
| Duplicates and forks | `relay.duplicate.idempotent`, `relay.fork.refused` | `node.duplicate.deduped`, `node.fork.surfaced` |
| `seq` regression | `relay.seq.chained-regression-refused`, `relay.seq.mail-regression-allowed` | `node.seq.mail-gaps-allowed` |
| Revocation | `relay.revocation.device-refused`, `relay.revocation.identity-refused`, `relay.revocation.cutoff-required` | `node.revocation.ignored-from-revoke-forward`, `node.revocation.mail-read-by-listed-hashes` |
| Clock drift | `relay.clock.skew-inside-window`, `relay.clock.skew-outside-window`, `relay.clock.replayed-nonce` | |
| Bootstrap | `relay.circle.root`, `relay.bootstrap.valid-join`, `relay.bootstrap.unknown-invite-refused`, `relay.bootstrap.spent-invite-refused`, `relay.bootstrap.expired-invite-refused` | `node.bootstrap.bad-joins-not-admitted` |
| Bootstrap read | `relay.bootstrap-read.open-invite`, `relay.bootstrap-read.closed-invites-unanswered` | |
| Epoch | `relay.epoch.newcomer-reads-from-join` | |
| Retract | `relay.retract.author-retracts`, `relay.retract.other-identity-refused` | `node.retract.author-only` |
| Limits | `relay.limits.oversized-refused`, `relay.limits.daily-append-cap` | |

Clock drift, epoch filtering and limits are relay rules a node has no half of.

## Where the protocol is silent, the suite chooses

Each of these is a reading of docs/protocol.md the suite holds relays and nodes to. A relay author who
reads the protocol differently raises it on the protocol, and the suite follows.

- **Bootstrap appends** (the root dinner and every join) carry none of the four `Digestif-*` headers.
  A later dinner is an ordinary append signed by the host's device key.
- **Refusal statuses.** `not_admitted` is accepted as 401 or 422, since the spec lists it under both.
  `too_large` is accepted as 413 or 422. A second join on a spent invite is accepted as `not_admitted`
  or `fork`, since it is also a second envelope at the invite key's `seq` 1.
- **A join** is the invite key's only envelope: `seq` 1, no `prev`, `epoch` 0.
- **Content epoch.** The suite writes content at the relay's current epoch from `GET /v0/circle`.
- **Gaps on a relay.** A relay accepts a chained key's later `seq` when it never received the ones
  between; refusing it would leave the missing range nowhere to be backfilled from.
- **Content bodies** are not fixed by protocol v0. The suite sends `summary` as `{ "text" }` (plus
  `padding` in the size case), `question` and `answer` as `{ "sealed" }`, and `retract` as
  `{ "target": "<envelope hash>" }`.
- **The node's merge order.** A node folds the union of every relay's envelopes by repeatedly taking,
  in `created_at`-then-hash order, every envelope that folds, until a pass folds nothing. The order
  depends only on the set of envelopes, which is what makes divergent histories merge to one fold
  and feed. An invite's expiry is judged against the join's `created_at`. A revoked device key is
  never read by this order: the node reads it up to the revoke's `after_seq`, and an envelope past
  the cutoff that folded ahead of the revoke is left out and the union folded again. A revoked mail
  key is read the same way by the envelope hashes the revoke's `mail_read` lists.
- **Join epochs differ across relays.** Each relay folds in its own order, so two relays may give one
  member different `join_epoch` values. The divergent relay case compares epoch advances and the
  admitted set, never `join_epoch`.
