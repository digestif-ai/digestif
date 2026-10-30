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
| `POST /v0/mail` | Mailing relay only: opens the sealed mail request and the digest it names, emails the digest with one answer link per option through Resend, and remembers the digest hash (`already_sent` on a repeat). |
| `GET /v0/links/:id?s=` | The confirm page for an answer link: the ask and the option, one Confirm button. Changes nothing. |
| `POST /v0/links/:id` | Confirms the link: checks the pre-signed decision, appends it, marks the ask's links used. |
| `/app/` | The phone app: static assets from `app/`, `index.html` for any path the build has no file for. |

The three mailer routes answer `404 not_mailer` on a relay whose `MAILER` is not `"1"`.

## Layout

| Path | What it holds |
|---|---|
| `src/index.ts` | The Worker: routing and the error shapes. |
| `src/auth.ts` | Request signing (docs/protocol.md "Request signing"): the four headers, skew, nonces. |
| `src/append.ts` | `POST /v0/envelopes`, with the lost-race retry around its storage step. |
| `src/read.ts` | The three reads. |
| `src/mail.ts` | `POST /v0/mail`: open, render, send, remember. |
| `src/links.ts` | `GET` and `POST /v0/links/:id`. |
| `src/render.ts` | The digest plaintext rendered to the text and HTML email (snapshots in `test/fixtures/`). |
| `src/pages.ts` | The confirm, done and refusal pages. |
| `src/app.ts` | `/app/`: the assets binding behind the prefix, with the `index.html` fallback. |
| `app/` | The phone app's files: a placeholder page in the repository, `ui/build` once `ci/build.sh` copies it in. |
| `src/db.ts` | D1 access and the fold replayed from the log. |
| `src/env.ts` | The configuration: root and limits. |
| `migrations/` | The D1 schema, applied with `wrangler d1 migrations apply`. |
| `test/` | vitest, run inside workerd against a local D1 (`@cloudflare/vitest-plugin`). |
| `scripts/conformance.ts` | The conformance suite's relay cases against `wrangler dev`. |

## Configuration

Worker variables, in `wrangler.jsonc` (`vars`) or per deployment with `wrangler deploy --var`:

| Variable | Meaning | Default |
|---|---|---|
| `CIRCLE_ROOT` | `sha256:<hex>` of the founding dinner envelope this relay serves. Required. | the conformance test circle's root |
| `MAX_ENVELOPE_BYTES` | Envelope plus body. | 65536 |
| `MAX_APPENDS_PER_DEVICE_PER_DAY` | Per author, UTC day. | 500 |
| `MAX_PAGE_SIZE` | `GET /v0/envelopes` page size. | 500 |
| `SKEW_SECONDS` | Request clock skew either way; also how long nonces are kept. | 3600 |
| `MAILER` | `"1"` on the one relay that mails (docs/protocol.md "Mailer routes"); anything else and the mailer routes answer `not_mailer`. | `"0"` |
| `MAIL_FROM` | The From header of the digest email, an address on the circle's domain. | `Digestif <digest@mail.digestif.io>` |
| `RELAY_URL` | The URL answer links name, when the relay is reached through another address than the request's origin (a tunnel in front of `wrangler dev`). | the request origin |

Secrets, set with `wrangler secret put`, required when `MAILER` is `"1"` and unread otherwise:

| Secret | Meaning |
|---|---|
| `RELAY_SEALING_KEY` | The mailing relay's X25519 private key, raw 32 bytes, base64url. Its public half is the `mailer` key in the `relay` body the operator's node posts; digests and mail requests are sealed to it. |
| `RESEND_API_KEY` | Resend's API key; the Worker sends through `https://api.resend.com/emails` and nothing else. |

The D1 binding is `DB`, database `digestif-relay`; the assets binding is `ASSETS`, directory `app/`.
Apart from the mailer's two secrets the relay holds no key of its own; every request is proved by
the signatures it carries, and an answer link by the secret in its URL. A database remembers the
root it first served (the `circle` row) and refuses a Worker configured with another, so two
circles cannot be mixed by a wrong variable.

The checked-in `CIRCLE_ROOT` is the conformance suite's throwaway test circle, so a fresh clone runs
the suite with no setup. A real deployment sets its own circle's root.

## Building and testing

Node.js 23.6 or later (the conformance suite runs `.ts` files directly) and npm.

    npm ci
    npm run check        # wrangler types, tsc, eslint
    npm test             # vitest inside workerd, against a fresh local D1
    npm run conformance  # the suite's relay cases against two wrangler dev instances

`npm run check` first generates `worker-configuration.d.ts` with `wrangler types` (the runtime
types for the compatibility date and flags; not checked in, so an editor wants `npm run types` once). `npm test` runs five files: the routes
before any envelope, the whole conformance relay suite in-process through the Worker with the
fold invariant below checked after every accepted append, the races (`test/race.test.ts`): two
appends interleaved at every point of the check through an injected D1, since miniflare
serializes D1 access over HTTP and cannot stage a real one, the mailer routes and `/app/` against a
fake Resend endpoint (the test's own `fetch`; nothing leaves the isolate, and the Worker under
test is configured as the mailer with a sealing key from `node/mail/test/vectors.json`), and the
email rendering against the snapshots in `test/fixtures/` (`npx vitest run -u` rewrites them after
a deliberate change). `npm run conformance` starts `wrangler dev`
on a temporary local D1 per instance, applies the migrations, runs
`conformance/bin/digestif-conformance.ts relay --url …` and exits with its status; `--instances 1`
runs one relay (the two-relay cases are skipped), `--case relay.clock` narrows the run.

`ci/build.sh` runs all three when `relay/` is present, after copying `ui/build` into `app/` when
the UI was built, so the deployed Worker serves the real phone app under `/app/`. A checkout
without that copy serves `app/index.html`, a placeholder page, and the tests only need that: they
check the route, not the UI.

Locally, for a relay that keeps its state between runs:

    npm run migrate:local
    npm run dev          # http://127.0.0.1:8787

## Deploying

The same Worker is deployed twice (docs/design.md "Two relays to start"), as the wrangler
environments `relay-1` and `relay-2` in `wrangler.jsonc`. wrangler does not inherit variables,
assets or bindings into an environment, so each repeats them; the top-level configuration is for
`wrangler dev` and the tests only.

| | `relay-1` | `relay-2` |
|---|---|---|
| Cloudflare account | the project's ("Digestif", held by Mike Bryzek) | Roman Cherkasov's own |
| Worker, database | `digestif-relay-1`, D1 `digestif-relay-1` | `digestif-relay-2`, D1 `digestif-relay-2` |
| Address | custom domain `relay1.digestif.io` | its `workers.dev` address or a domain of Roman's |
| `MAILER` | `"1"`, the one relay that mails | `"0"`, never mails |
| `RELAY_URL` | `https://relay1.digestif.io` | a placeholder, replace it with the relay's URL |
| Secrets (`secrets.required`) | `RELAY_SEALING_KEY`, `RESEND_API_KEY` | `RELAY_SEALING_KEY` |

Placeholders to fill before the first deploy: the root hash (`vars.CIRCLE_ROOT` of the
environment, left empty, or the `ROOT_HASH` environment variable at deploy time; the Worker reads it
as `CIRCLE_ROOT`), `RELAY_URL` of `relay-2`, and the `database_id`s, which the deploy script fills.

Deploy with `npm run deploy -- <relay-1|relay-2> [--dry-run]` (`scripts/deploy.sh`). It refuses
without the root hash, prints the account and the environment, creates the D1 database when its
id is still the placeholder (and writes the id into `wrangler.jsonc`; commit that), applies the
migrations with `wrangler d1 migrations apply DB --remote --env …`, and runs `wrangler deploy --env …
--var CIRCLE_ROOT:…`. `--dry-run` prints that plan and touches nothing. Run `wrangler login` as
the account's holder first (or set `CLOUDFLARE_API_TOKEN` in the shell, never in a file).

1. Generate the relay's X25519 key: `node scripts/keygen.mjs` prints `RELAY_SEALING_KEY=…` (the
   secret, base64url raw private key) and `public=x25519:…` (the `encryption_key` of the `relay`
   message). Set the secret with `npx wrangler secret put RELAY_SEALING_KEY --env <environment>`,
   pasting the value at the prompt. A relay that does not mail never reads it.
2. On `relay-1` also set `RESEND_API_KEY` (see "Operations").
3. `ROOT_HASH=sha256:… npm run deploy -- relay-1`. The host's node prints the founding dinner's
   hash; the conformance suite's is `node conformance/bin/digestif-conformance.ts circle show`.
4. The host appends the founding dinner (a bootstrap append, no request signature); until then every
   signed request is `401 not_admitted`, since nobody is admitted. The operator's node then posts a
   `relay` message: `url`, `mailer` (true for relay-1) and, for the mailer, `encryption_key` from
   step 1.

To run the suite against a deployment rooted in the test circle:

    node conformance/bin/digestif-conformance.ts relay --url https://relay.example

A relay that already holds earlier runs is as good a target as a fresh one (conformance/README.md).

## Operations

Every command runs in `relay/`, with `--env relay-1` or `--env relay-2`, as the holder of that
environment's Cloudflare account (relay-1: the project's account; relay-2: Roman's). The relay has
no health route and grows none outside the spec; to see that one is up, read `GET /v0/circle`.

**Deploy.** `npm run deploy -- relay-1` (see "Deploying"). Migrations are applied before the Worker
is replaced and only ever add.

**Roll back.** List versions with `npx wrangler deployments list --env relay-1` (or
`npx wrangler versions list --env relay-1`), then `npx wrangler rollback <version-id> --env relay-1`
(without an id, the previous version). A rollback changes the code, not the database: after a
release with a new migration, roll back only to a version that works on the migrated schema.

**Watch it.** `npx wrangler tail --env relay-1` streams logs and exceptions live; add
`--status error` for failures only. The relay logs no request body, secret or address.

**Export a database.** `npx wrangler d1 export digestif-relay-1 --remote --output relay-1.sql`
(add `--no-schema` for data only). The file holds the whole log, sealed digests included, so keep it
as private as the relay. A `.sql` export restores into a fresh database with `wrangler d1 execute`.

**Rotate the Resend key** (relay-1). In Resend, create a new API key, then
`npx wrangler secret put RESEND_API_KEY --env relay-1`, paste it, and delete the old key in Resend.
A secret change takes effect at once with no redeploy. Nothing has to be told to the circle.

**Rotate the sealing key** (relay-1; relay-2 holds one it never reads). Run `node scripts/keygen.mjs`
and `npx wrangler secret put RELAY_SEALING_KEY --env relay-1` with the new private value. Digests and
mail requests are sealed to the mailer's public key, so the circle must see a new `relay` message
for relay-1 naming the new `x25519:` public key before nodes seal to it: post it first, and put the
secret in the moment the circle has it. Anything sealed to the old key before nodes learn the new one
cannot be opened by the relay; those digests must be written again.

**When a relay is lost.** Nothing is lost: every node holds a full copy of the log and writes to
every relay it knows, so the circle keeps working on the others. To replace it, deploy again with the
same root hash (new D1 database, migrations, secrets, `npm run deploy`), keep the same address, and
nodes push their logs back on their next sync. A lost mailer additionally needs its sealing key
(set a new one and announce it as above) and `RESEND_API_KEY`; email stops until then.

**Resend secret for Mike** (relay-1, in the project's Cloudflare account, after Roman has deployed
it). The Worker is `digestif-relay-1`; the secret is `RESEND_API_KEY`:

1. In Resend, make an API key with send access for the `mail.digestif.io` domain.
2. `cd relay && npx wrangler login`, signed in to the "Digestif" account.
3. `npx wrangler secret put RESEND_API_KEY --env relay-1`, and paste the key at the prompt (or use
   Workers & Pages, `digestif-relay-1`, Settings, Variables and Secrets, add a Secret with that name).
4. Tell Roman. He does not need the value.

## The phone app

`/app/` serves the node's web UI built for a phone (docs/protocol.md "The phone"): `ui/build`,
copied into `app/` by `ci/build.sh`, behind the assets binding with `run_worker_first`, so the
Worker strips the prefix and answers `index.html` for any path the build has no file for. On the
relay the phone app calls `GET /v0/envelopes` (signed by its own device key, from before it is
admitted until it finds its `device` envelope and from then on to read the member's asks, digests
and directed messages), `POST /v0/envelopes` for its decisions, and `GET /v0/circle`. Pairing
(`POST /v0/_pair` in `ui/mock/relay.ts`) is the node's route, not the relay's: the pairing code is
pasted into the local UI and the laptop appends the `device` envelope that enrolls the phone.

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

**The relay_id is chosen first** (`MAX(relay_id) + 1`), before the duplicate, the fold, the chain
and the retract target are read, and every one of those reads sees only the log below it. So the
fold's positions and the rows agree, and the UNIQUE on `relay_id` guards the whole check: whatever
another append commits after the position was chosen takes that id, the batch fails, and the loser
re-runs the storage step once over the longer log (two joins at once take consecutive epochs; a
fork that races the envelope it forks is refused). The request is authenticated once, before the
retry, so its nonce is spent once and the re-run is not refused as a replay. A nonce is recorded
with a single INSERT against the `(key, nonce)` primary key; two copies of one request arriving
together cannot both pass.

**Retracts of circle state are refused** (`422 malformed`): a retract drops its target's body, and
the fold reads the bodies of dinners, joins, devices and revokes, so dropping one would leave the
log unfoldable for the relay and every node. The protocol fixes retracts for content; this is the
relay's reading until it says otherwise.

**The mailer stores nothing it was told.** `POST /v0/mail` opens the request and the digest with
the sealing key, renders the email with every option's link URL in it, and writes two things to D1
before calling Resend: the digest hash in `mailed_digests` (the `already_sent` claim; a lost race
finds the row and mails nothing) and each link's id, ask and expiry in `links`, so the link routes
can find the sealed answer in the digest body the log already holds. A send Resend refuses drops
both so a retry mails (`502 mail_failed`). No column anywhere holds the request, a secret, the
address, the subject or a line of the plaintext; `test/mailer.test.ts` dumps every table after a
send and looks for each. The link pages all answer `200 text/html` as the spec lists, and `GET`
checks the link in this order: unknown, the secret, used, expired, so a page says no more about a
link than its secret earns. `POST` runs `checkAnswer` from `node/mail/webcrypto/mail.mjs` against
the admitted, unrevoked mail keys of the digest author's identity and then the core append path
(`appendSigned`, with no request signer, as a bootstrap append), so the chain rules, the daily cap
and the fold apply to the decision as to any envelope; a refusal is rendered, not returned as JSON.
The conformance suite has no `relay.mail.*` or `relay.links.*` cases: a black-box case would have a
real relay send email and would need the relay's sealing key, so the mailer's cases are vitest
cases here instead.

**Pages and email.** The answer-link pages and the digest email take their look from the web UI:
`src/theme.ts` holds the font stack, the stone text and background colors in light and dark, the plum
accent, the radii, the 4px spacing scale and the status tones, each commented with the token in
`ui/src/app.css` or `ui/src/lib/components/` it was copied from. The pages inline that stylesheet
(no external resource, no script); the email expresses the same values as inline styles, since mail
clients ignore stylesheets. The values are copies, so they can drift. The ask to Mike: export the
`ui/` theme as a shared CSS file (the `@theme` tokens and the status tones as plain custom
properties) so the UI, the pages and the email read one source.

**Where the protocol is silent, the relay follows the suite's choices** (conformance/README.md):
`not_admitted` is 401 for a request and 422 for an envelope, `too_large` is 422, a second join on a
spent invite is `not_admitted`, and `release_revocation` is not yet a kind the shared `envelope.ts`
knows, so it is refused as `malformed` until the suite adds it.
