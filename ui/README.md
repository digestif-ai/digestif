# Digestif web UI

The node's local web UI: SvelteKit, built to static files that the node embeds in its binary and
serves on localhost beside its API (`spec/digestif-node.json`). The relay will serve the same build
as the phone web app.

    npm ci
    npm run dev            # answers from mock/node.ts, an in-memory node with a made-up circle
    DIGESTIF_NODE=http://127.0.0.1:7420 npm run dev   # proxies /api/v0 to a running node
    npm run check          # svelte-check, playwright types, eslint
    npm test               # vitest
    npm run test:e2e       # playwright against vite dev and the mock node
    playwright/against-node.sh   # the same suite against a `digestif demo` node (build node/ first)
    npm run build          # build/, the files the node embeds

The build is a single-page app: the node answers any path it does not know with `build/index.html`.
