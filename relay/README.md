# Relay

The Digestif relay: a Cloudflare Worker with D1, in TypeScript. It implements
[spec/digestif-relay.json](../spec/digestif-relay.json) and the relay rules in
[docs/protocol.md](../docs/protocol.md), and passes the relay cases of the suite in
[conformance/](../conformance). One deployment mirrors one circle: it is configured with the hash of
the circle's founding dinner and holds nothing until that dinner is appended.

| Route | What it does |
|---|---|
| `POST /v0/envelopes` | Append one signed envelope: the request check, the envelope check, the chain rules, the daily cap, then the admission fold. |
| `GET /v0/envelopes?after&limit` | Everything after a cursor in `relay_id` order; circle state in full, content from the reader's join epoch on. |
| `GET /v0/circle` | The root, the epoch, the admitted keys and the limits. |
| `GET /v0/invites/:invite_key` | The bootstrap read: the dinner listing an open invite, to the invite key alone. |
| `POST /v0/mail`, `/v0/links/:id` | The mailer routes, a later epic: `404 not_mailer` for now. |

## Layout

| Path | What it holds |
|---|---|
| `src/index.ts` | The Worker: routing, the error shapes, the lost-race retry. |
| `src/auth.ts` | Request signing (docs/protocol.md "Request signing"): the four headers, skew, nonces. |
| `src/append.ts` | `POST /v0/envelopes`. |
| `src/read.ts` | The three reads. |
| `src/db.ts` | D1 access and the fold replayed from the log. |
| `src/env.ts` | The configuration: root and limits. |
| `migrations/` | The D1 schema, applied with `wrangler d1 migrations apply`. |
| `test/` | vitest, run inside workerd against a local D1 (`@cloudflare/vitest-plugin`). |

## Configuration

Worker variables, in `wrangler.jsonc` (`vars`) or per deployment with `wrangler deploy --var`:

| Variable | Meaning | Default |
|---|---|---|
| `CIRCLE_ROOT` | `sha256:<hex>` of the founding dinner envelope this relay serves. Required. | the conformance test circle's root |
| `MAX_ENVELOPE_BYTES` | Envelope plus body. | 65536 |
| `MAX_APPENDS_PER_DEVICE_PER_DAY` | Per author, UTC day. | 500 |
| `MAX_PAGE_SIZE` | `GET /v0/envelopes` page size. | 500 |
| `SKEW_SECONDS` | Request clock skew either way; also how long nonces are kept. | 3600 |

The D1 binding is `DB`, database `digestif-relay`. There are no secrets: the relay holds no key of
its own; every request is proved by the signatures it carries. A database remembers the root it
first served (the `circle` row) and refuses a Worker configured with another, so two circles cannot
be mixed by a wrong variable.

The checked-in `CIRCLE_ROOT` is the conformance suite's throwaway test circle, so a fresh clone runs
the suite with no setup. A real deployment sets its own circle's root.

## Building and testing

Node.js 23.6 or later (the conformance suite runs `.ts` files directly) and npm.

    npm ci
    npm run check        # wrangler types, tsc, eslint
    npm test             # vitest inside workerd, against a fresh local D1

`npm run check` first generates `worker-configuration.d.ts` with `wrangler types` (the runtime
types for the compatibility date and flags; not checked in, so an editor wants `npm run types` once). `npm test` runs two files: the routes
before any envelope, and the whole conformance relay suite in-process through the Worker, with the
fold invariant below checked after every accepted append.

`ci/build.sh` runs both when `relay/` is present.

Locally, for a relay that keeps its state between runs:

    npm run migrate:local
    npm run dev          # http://127.0.0.1:8787

## Deploying

1. Create the database once: `wrangler d1 create digestif-relay`, and put its id in
   `wrangler.jsonc` (`d1_databases[0].database_id`).
2. Apply the migrations: `npm run migrate:remote`.
3. Deploy with the circle's root: `wrangler deploy --var CIRCLE_ROOT:sha256:…` (and any limit to
   change). The host's node prints the founding dinner's hash; the conformance suite's is
   `node conformance/bin/digestif-conformance.ts circle show`.
4. The host appends the founding dinner (a bootstrap append, no request signature); until then every
   signed request is `401 not_admitted`, since nobody is admitted.

To run the suite against a deployment rooted in the test circle:

    node conformance/bin/digestif-conformance.ts relay --url https://relay.example

A relay that already holds earlier runs is as good a target as a fresh one (conformance/README.md).

## Design

**The fold is shared, not copied.** `src/` imports `conformance/src/fold.ts`, `envelope.ts`,
`keys.ts`, `encoding.ts` and `request.ts` by relative path and wrangler bundles them, so the relay
and the suite can never disagree about who is admitted. Those modules use `node:crypto` (Ed25519
through `createPublicKey` and `verify`, `createHash` for sha256) and `Buffer`. The Worker runs them
unchanged under the `nodejs_compat` compatibility flag: workerd's `node:crypto` verifies Ed25519 and
hashes sha256, which `test/worker.test.ts` proves on the test circle's root dinner inside workerd,
and `wrangler dev` showed the same before the flag was chosen. No bundler alias and no WebCrypto
twin, because the fold is synchronous and WebCrypto is not; a twin would have meant a second
Ed25519 implementation.

**D1 holds the log and the fold's output.** `envelopes` is the append-only log in relay order;
`admitted_keys`, `invites` and the `circle` row (root and epoch) are derived from it; `nonces` and
`daily_appends` serve the request checks. The shared `Fold` keeps its state in memory and exposes no
way to load it, so an append replays it from the circle-state envelopes (dinner, join, device,
revoke, card, relay: one per membership event, not per message) with each one's `relay_id` as
position and `received_at` as clock, applies the new envelope, and writes the envelope and the keys
that changed to D1 in one batch. The invariant, checked by `test/conformance.test.ts` after every
accepted append: `admitted_keys`, the epoch and the open invites equal a full refold of the log.
The replay costs one signature check per join, device and revoke per append; a circle of a few
dozen members replays in a few milliseconds. A relay with thousands of membership events would want
the fold's state snapshotted, which needs the shared fold to expose it.

**The relay_id is chosen before the insert** (`MAX(relay_id) + 1`) so the fold's positions and the
rows agree; two appends racing for one id, or one hash, fail D1's UNIQUE constraint and the loser is
re-run once from the start.

**Retracts of circle state are refused** (`422 malformed`): a retract drops its target's body, and
the fold reads the bodies of dinners, joins, devices and revokes, so dropping one would leave the
log unfoldable for the relay and every node. The protocol fixes retracts for content; this is the
relay's reading until it says otherwise.

**Where the protocol is silent, the relay follows the suite's choices** (conformance/README.md):
`not_admitted` is 401 for a request and 422 for an envelope, `too_large` is 422, a second join on a
spent invite is `not_admitted`, and `release_revocation` is not yet a kind the shared `envelope.ts`
knows, so it is refused as `malformed` until the suite adds it.
