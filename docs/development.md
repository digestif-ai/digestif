# Development

## Layout

| Directory | What it holds |
|---|---|
| `spec/` | The relay's HTTP surface in API Builder format. The contract every other piece builds to. |
| `docs/` | The design, the protocol, the behavior interface, and this file. |
| `node/` | The node, in OCaml: one dune project (`node/dune-project`, package `digestif-node`). Each library is a directory of its own under `node/`. |
| `node/generated/` | The relay's types for OCaml, the `digestif_api` library. Generated. |
| `node/web/` | The localhost server: the embedded web UI and the local API in `spec/digestif-node.json`. |
| `ui/` | The web UI, in SvelteKit, built to static files the node embeds. |
| `ui/src/generated/` | The relay's and the node's types and clients for TypeScript. Generated. |
| `conformance/` | The cases every relay and node must pass. |
| `relay/` | The Cloudflare Worker relay. |
| `ci/build.sh` | Builds and tests everything present. |
| `install.sh` | Builds the node with its UI and installs it, with its behaviors, as the service's release (node/README.md, Install and upgrade). |
| `ci/release-artifact.sh` | Builds this platform's release archive for the version the checkout is (docs/releases.md, Cutting a release). |
| `ci/version.sh` | The version a checkout builds: the release tag on HEAD, or 0.0.0. |
| `ci/release-paths` | What a release archive is built from; a commit touching none of it is not a new version. |
| `ci/release.sh` | The release command a rollout runs: `build`, `changed`, `signatures`, `candidate`, `test-nodes`, `publish`, `channel`, `drop`. |
| `ci/release-linux.sh` | Builds this machine's Linux release archive inside an Alpine container, with static binaries. |
| `ci/release-check.sh` | Stages a built archive on a clean machine the way a node stages a release. |
| `ci/test-node.sh` | One test node: takes a signed version on a throwaway runner the way a member's node does. |
| `ci/test-node-rehearsal.sh` | Runs a test node for real against two versions built with throwaway keys. |
| `ci/platforms.json` | The platforms a release ships, and the runner each builds on. |
| `.github/workflows/release.yml` | Builds and stages every platform from one commit; on a pushed `v*` tag leaves the draft release, otherwise a dry run (docs/releases.md, Cutting a release). |

## Building

You need OCaml 5.1 or later with opam, and Node.js 22 or later.

    opam install ./node --deps-only --with-test
    ci/build.sh

`ci/build.sh` runs `npm ci`, `npm run check`, `npm test` and `npm run build` in `ui/`, copies
`ui/build` to `node/web/ui`, and builds and tests `node/` with dune. It then runs the UI's
Playwright suite twice, against vite dev and the mock node and then against the node it built
through `ui/playwright/against-node.sh`, installing the Chromium the suite pins first. It runs
`npm ci`, `npm run check` and `npm test` in `conformance/`, whose self-test needs Node.js 23.6 or later. It then runs the
conformance suite's node cases against the `digestif` binary it built, through
`digestif conformance sync`, so the OCaml node is held to the reference node. On a fresh machine,
`DIGESTIF_INSTALL_DEPS=1 ci/build.sh` installs the opam dependencies first, along with the system
packages they declare (`pkgconf`, which `conf-sqlite3` needs). Without it, `ci/build.sh` refuses
before dune runs when the current switch is missing any of them, and names each one.

The node embeds the web UI at build time: dune turns every file under `node/web/ui` into
`assets.ml`. That directory is a copy of `ui/build` and is not checked in, so build the UI and copy
it before building a node to ship; a node built without it serves one page saying so. To run the
UI's Playwright suite against the node itself rather than the mock, build the node and run
`ui/playwright/against-node.sh`, which starts `digestif demo` and points the suite at it. Its
`new-member.spec.ts` is a new member end to end, and runs only there: the setup chat scripted
through `digestif setup`, the first note edited with Save & approve and its Learnings, three
unchanged approvals and the suggestion, auto approval turned on, and a pause from a waiting note
and Unpause.

## Page budget

Every node page answers within 50ms at p95 on a heavy machine. `node/web/perf/test_perf.ml` builds
the machine (1,000 clones across 50 organizations and 5,000 Claude Code transcripts under a HOME
of its own) and a node a few years old (1,100 notes, 600 asks with a third of them answered, and
3,000 nights of digests and 3,000 summaries in its log), stores the machine scan, and calls every GET the UI reads through the server's own handler, the
paged lists at their first page and the page after it. A route fails when its p95 is over 50ms, or when it is more than three times what
`node/web/perf/baseline.json` recorded and more than 5ms above it, the baseline first scaled by how
much slower the run's machine is: the median, over every route the baseline names, of measured over
recorded, never below one. A slow or loaded runner moves every route at once, so it moves the median
and fails nothing; a route that regresses on its own still stands out from the rest by three times,
and the 50ms budget is never scaled. It runs with node/'s dune suite,
so `ci/build.sh` runs it. A route the baseline does not name yet is held to the budget alone; a
change meant to make a page slower retakes the baseline:

    cd node && DIGESTIF_PERF_RECORD=$PWD/web/perf/baseline.json dune exec web/perf/test_perf.exe

The lists that grow with the machine or the node's age (sources, organizations, repositories,
notes, asks, members and the deny list) take a `limit` and a `cursor`, the id of the last row of
the page before, and read one page from an index. Asks are sealed in the log, so the store keeps
an index of each ask's row as the list shows it, filled once per envelope; the Asks list opens no
ask, and only an ask's own page does. The feed walks the log newest first by `created_at` and
stops at its page, a member's recent list and what their summaries say walk only that member's
keys, and a message's replies are read by the `reply_to` the log keeps beside each envelope, so
none of them opens a message it does not show. Members are ordered by what the circle's summaries say, so
their page is cut from that order; a circle is the people a member knows. The scan
itself is incremental: the store keeps what it last read of each clone and project directory
under a stamp of sizes and modification times, and a rescan rereads only what moved
(`node/web/machine_scan.ml`).

## Generated code

`node/generated/*.ml` and `ui/src/generated/` are generated from the files in `spec/` by
[API Builder](https://www.apibuilder.io), as `.api/config.pkl` declares, and are checked in, so
a clone builds without running the generator. Never edit them by hand: change the spec and
regenerate, and commit the spec change and the generated change together.

`node/generated/dune` is the one hand-written file among them. The OCaml modules are unwrapped,
so a caller writes `Com_bryzek_digestif_relay.Envelope`; the TypeScript client is
`ui/src/generated/com-bryzek-digestif-relay.ts`. The UI reads the node's models (`spec/digestif-node.json`)
from `ui/src/generated/com-bryzek-digestif-node.ts`, imported as
`#generated/com-bryzek-digestif-node.ts`; its enums are TypeScript enums, so code names a value
as `Voice.Person`, never the string `'person'`.
