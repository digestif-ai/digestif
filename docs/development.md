# Development

## Layout

| Directory | What it holds |
|---|---|
| `spec/` | The relay's HTTP surface in API Builder format. The contract every other piece builds to. |
| `docs/` | The design, the protocol, and this file. |
| `node/` | The node, in OCaml: one dune project (`node/dune-project`, package `digestif-node`). Each library is a directory of its own under `node/`. |
| `node/generated/` | The relay's types for OCaml, the `digestif_api` library. Generated. |
| `node/web/` | The localhost server: the embedded web UI and the local API in `spec/digestif-node.json`. |
| `ui/` | The web UI, in SvelteKit, built to static files the node embeds. |
| `ui/src/generated/` | The relay's and the node's types and clients for TypeScript. Generated. |
| `conformance/` | The cases every relay and node must pass. |
| `relay/` | The Cloudflare Worker relay. |
| `ci/build.sh` | Builds and tests everything present. |

## Building

You need OCaml 5.1 or later with opam, and Node.js 22 or later.

    opam install ./node --deps-only --with-test
    ci/build.sh

`ci/build.sh` runs `npm ci`, `npm run check`, `npm test` and `npm run build` in `ui/`, copies
`ui/build` to `node/web/ui`, builds and tests `node/` with dune, and runs `npm ci`, `npm run check`
and `npm test` in `conformance/`, whose self-test needs Node.js 23.6 or later. On a fresh machine,
`DIGESTIF_INSTALL_DEPS=1 ci/build.sh` installs the opam dependencies first, along with the system
packages they declare (`pkgconf`, which `conf-sqlite3` needs). Without it, `ci/build.sh` refuses
before dune runs when the current switch is missing any of them, and names each one.

The node embeds the web UI at build time: dune turns every file under `node/web/ui` into
`assets.ml`. That directory is a copy of `ui/build` and is not checked in, so build the UI and copy
it before building a node to ship; a node built without it serves one page saying so. To run the
UI's Playwright suite against the node itself rather than the mock, build the node and run
`ui/playwright/against-node.sh`, which starts `digestif demo` and points the suite at it.

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
