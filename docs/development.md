# Development

## Layout

| Directory | What it holds |
|---|---|
| `spec/` | The relay's HTTP surface in API Builder format. The contract every other piece builds to. |
| `docs/` | The design, the protocol, and this file. |
| `node/` | The node, in OCaml: one dune project (`node/dune-project`, package `digestif-node`). Each library is a directory of its own under `node/`. |
| `node/generated/` | The relay's types for OCaml, the `digestif_api` library. Generated. |
| `ui/` | The web UI, in SvelteKit, built to static files the node embeds. |
| `ui/src/generated/` | The relay's types and client for TypeScript. Generated. |
| `conformance/` | The cases every relay and node must pass. |
| `relay/` | The Cloudflare Worker relay. |
| `ci/build.sh` | Builds and tests everything present. |

## Building

You need OCaml 5.1 or later with opam, and Node.js 22 or later.

    opam install ./node --deps-only --with-test
    ci/build.sh

`ci/build.sh` builds and tests `node/` with dune and, once `ui/package.json` exists, runs
`npm ci`, `npm run check`, `npm test` and `npm run build` in `ui/`, and `npm ci`, `npm run check`
and `npm test` in `conformance/`, whose self-test needs Node.js 23.6 or later. It then runs the
conformance suite's node cases against the `digestif` binary it built, through
`digestif conformance sync`, so the OCaml node is held to the reference node. On a fresh machine,
`DIGESTIF_INSTALL_DEPS=1 ci/build.sh` installs the opam dependencies first.

## Generated code

`node/generated/*.ml` and `ui/src/generated/` are generated from the files in `spec/` by
[API Builder](https://www.apibuilder.io), as `.api/config.pkl` declares, and are checked in, so
a clone builds without running the generator. Never edit them by hand: change the spec and
regenerate, and commit the spec change and the generated change together.

`node/generated/dune` is the one hand-written file among them. The OCaml modules are unwrapped,
so a caller writes `Com_bryzek_digestif_relay.Envelope`; the TypeScript client is
`ui/src/generated/com-bryzek-digestif-relay.ts`.
