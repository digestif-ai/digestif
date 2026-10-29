# Digestif web UI

The node's local web UI: SvelteKit, built to static files that the node embeds in its binary and
serves on localhost beside its API (`spec/digestif-node.json`). The mailing relay serves the same
build, and its pages under `/app/` are the phone web app (docs/protocol.md, The phone): the phone
keeps its own keys in IndexedDB, shows a pairing code, and reads and answers the member's asks by
talking to the relay with requests it signs itself, using `node/mail/webcrypto/mail.mjs`.

    npm ci
    npm run dev            # answers from mock/node.ts, an in-memory node with a made-up circle,
                           # and /v0 from mock/relay.ts, a mailing relay for /app (POST /v0/_pair
                           # admits the phone's pairing code as the member's laptop would)
    DIGESTIF_NODE=http://127.0.0.1:7420 npm run dev   # proxies /api/v0 to a running node
    npm run check          # svelte-check, playwright types, eslint
    npm test               # vitest
    npm run test:e2e       # playwright against vite dev and the mock node
    playwright/against-node.sh   # the same suite against a `digestif demo` node (build node/ first)
    npm run build          # build/, the files the node embeds

The build is a single-page app: the node answers any path it does not know with `build/index.html`.
