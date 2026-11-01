# Digestif node

One native binary for Mac and Linux: the member's keys, the circle log, the admission fold and
signed sync with every relay. It holds no intelligence; behaviors are programs it spawns.

## Build

OCaml 5.1 or later and opam. The node needs SQLite (on macOS the system library; on Linux
`libsqlite3-dev`), and talks to relays through `curl`, so it uses the system's TLS and certificate
store.

    cd node
    opam install . --deps-only --with-test
    dune build
    dune test

The binary is `_build/default/bin/main.exe`, installed as `digestif`.

## Install and upgrade

From a checkout, `./install.sh` at the repository's root is the install and the upgrade step:

    git pull && ./install.sh

It builds the web UI and copies `ui/build` to `node/web/ui` (a plain `dune build` embeds no UI, and
`digestif open` then shows a page saying so) and builds the node. It puts the binary on PATH as the
CLI (`digestif` on PATH, else `~/.local/bin/digestif`, the old one kept as `<binary>.previous`).
When a service is installed, or with `--service`, it then runs `digestif service install
--behaviors behaviors/`, which makes this build and its behaviors a release in the node's data
directory, self-tests it against a copy of the node's data, points `current` and `good` at it, and
restarts the service. `--to <path>` only copies the binary and leaves the service alone. It runs no
tests: `ci/build.sh` is the whole check.

The service runs `good/bin/digestif supervise`, which runs `current/bin/digestif run` and installs
signed releases on its own (`digestif update`, docs/releases.md); `./install.sh` is the upgrade for
a node built from source.

## Keys

| Key | Where it lives |
|---|---|
| Identity (Ed25519) | Derived from the recovery phrase when a device or revoke message is signed, never stored |
| Encryption (X25519) | Derived from the phrase; cached in the keystore because every read needs it |
| Device (Ed25519) | This machine's key; signs everything but device and revoke messages |
| Mail (Ed25519) | The chainless key the digest's pre-signed answers ride on |

The keystore is the macOS Keychain (driven through `security`) or the Linux Secret Service (through
`secret-tool`, package `libsecret-tools`). A secret always goes over stdin, never an argv. Tests and
a throwaway CI circle may set `DIGESTIF_INSECURE_KEYSTORE_DIR` to keep keys in owner-only files
instead; a member's node never should.

The phrase is read from stdin by every command that needs it (`init`, `device publish`, `revoke`,
`join`, and `asks answer` when it revokes),
so it never lands in an argv or a shell history.

## Commands

    digestif phrase new                      a new 24-word recovery phrase, stored nowhere
    digestif init --root <hash> --relay <url>  set up this machine from the phrase on stdin
    digestif sync                            read every relay, verify, fold, push what a relay lacks
    digestif relay add <url> [--mine] | remove <url> | list
                                             the relays this node uses; --mine publishes a relay message,
                                             and every node adds the relay of an admitted member's message
    digestif circle                          the fold: epoch, admitted keys, cards, relays, refusals
    digestif log | show <hash> | faults      the log, one envelope, forks and gaps
    digestif post --kind <kind> --body <file>  sign the next envelope of this device's chain; a summary,
                                             question, answer or proposal passes the deny layer first
                                             (a trip signs nothing and exits 3)
    digestif card --name <n> --agent-name <n>  publish this member's card
    digestif device publish --role mail      admit the mail key (phrase on stdin)
    digestif revoke <key> | retract <hash>   revoke a key (phrase on stdin), retract a note
    digestif invite --date <d> --label <l> --guest "Name <email> [mac|linux]"...
                                             sign a dinner, append it to every relay, print each email
    digestif invite expected <guest> | list  record that a guest installed; the invites and their state
    digestif join <invite text or link>      join with an invite (phrase on stdin)
    digestif asks | asks answer <key> <option>  what this node needs decided, and the answer
    digestif url-handler print|install|uninstall  make digestif://join links open digestif join
    digestif run                             sync on an interval and on wake; self-update daily and on wake; serve the web UI
    digestif open                            open the running node's web UI with a one-time link
    digestif ui [--open]                     serve the web UI without syncing
    digestif note --text <file>              hand the node tonight's note: deny layer, then approval or signing
    digestif tick --outcome quiet|harness_signed_out [--note <text>]
                                             record a nightly run that handed over no note, and why
    digestif behavior set|unset|list|run     the programs digestif run spawns (docs/behaviors.md)
    digestif writer set|unset|show           the program the preview note and Draft for me run
    digestif demo --home <dir>               serve the web UI over a made-up circle, for the UI's tests
    digestif update check|apply|pin|unpin    what a self-update would install, stage and switch now, pin a version
    digestif supervise                       what the service runs: current/bin/digestif run, rolled back
                                             to good when a new release does not report healthy
    digestif self-test --expect-version <v>  a release's check before a switch: version, store, config
    digestif service print|install|uninstall  the launchd agent or systemd user unit, with this shell's
                                             PATH; install makes this binary (and --behaviors <dir>)
                                             the node's release and records $DIGESTIF_WRITER as the writer
    digestif conformance sync ...            the conformance suite's node adapter

The data directory is `$DIGESTIF_HOME`, else `~/Library/Application Support/Digestif` on macOS and
`$XDG_DATA_HOME/digestif` on Linux; `--data-dir` overrides it.

## The web UI

`digestif run` serves the web UI and the local API (`spec/digestif-node.json`) on 127.0.0.1:7420
(`--ui-port`, `--no-ui`), from one origin, with the UI's build embedded in the binary. Nothing
answers on any other interface. `digestif open` mints a launch link good once, for five minutes; it
sets an HttpOnly, SameSite=Strict session cookie and redirects to the UI. Every API request must
carry that cookie and the `Digestif-Local: 1` header, and its Host and Origin must name this
machine, so a page on another origin can neither read nor post. Any path the UI does not know
answers `index.html`.

What the UI keeps that never travels (the brief, the rules, the deny list, the source choice,
mutes, and notes held for approval or refused before signing) lives in `ui_*` tables beside the log.
Every outbound message passes the deny layer before it is signed: the member's deny list and the
built-in secret detectors, a trip naming the rule and never the text. The first five notes wait for
approval in the UI. The first-note preview extracts commit subjects and session titles from the
last day of the chosen sources and drafts the note with the writer, `DIGESTIF_WRITER` or the program
`digestif writer set` recorded (digest
lines on stdin, the note on stdout), or, with none set, a plain draft of those lines. The same
writer, told `DIGESTIF_WRITER_TASK=brief`, drafts a first brief from the member's card and the chosen
sources when My brief is empty (Draft for me); with no writer the action is absent
(docs/behaviors.md, What a behavior hands back).

Every run of the nightly pipeline leaves a tick in `ui_ticks`: `digestif note` records whether the
note was posted, held for approval or refused by the deny layer, and a run that hands over no note
calls `digestif tick` to say it had nothing to say or could not use the member's agent harness. When
this node has not posted in three days, the Members page says why, first match wins: no source
selected (`no_sources`), no tick in a day and a half (`asleep`), the newest tick that did anything
could not use the harness (`harness_signed_out`) or had its note refused (`deny_refusing`), or a
relay recorded an error on its last sync (`relay_rejecting`).

A behavior can also say why in its own words: `POST /api/v0/silence_notes` (or `digestif tick
--note`) records a silence note of at most 280 characters with the run's tick, after the deny layer
passes it, since it reaches the mailing relay inside the digest. The Members page shows the newest
note of the last three days beside the fixed reason, and the digest carries a Silence section: while
this node has not posted in three days, since when, the fixed reason and the notes of those three
days; otherwise only the notes recorded since the last digest.

Quiet hours are a span of local time the member sets on the Rules page (`/api/v0/rules/quiet_hours`,
`HH:MM` to `HH:MM`, past midnight when the start is later than the end), kept in the log's config.
The digest, which carries every ask, waits for them to end, and a behavior reads the same resource,
whose `active` and `ends_at` say whether they hold now and until when, before it reaches the person
any other way.

## Behaviors

`digestif run` spawns the behaviors `digestif behavior set` names (docs/behaviors.md): the
`nightly` one on the first pass after the member's fixed minute between 3:00 and 3:59 local, once
per local date, so a laptop closed at that minute runs it on wake (a minute that passed before the
nightly was set up is not owed), and the `read` one after a sync
that stored something new. Each is handed a JSON context on stdin (the data directory, the local
API address with a session that ends with the run, the chosen sources and the local date), its
output goes to `behaviors/<hook>.log`, and it hands results back through `digestif note`,
`digestif tick` and the local API. A run past its deadline is ended.

`digestif demo` serves the same circle `ui/mock/fixtures.ts` describes, built from real keys and
signed envelopes in a throwaway directory, and answers `POST /api/v0/_reset` by reseeding it;
`ui/playwright/against-node.sh` runs the UI's Playwright suite against it.

## Layout

`core/` is the library `digestif-node.core` (`Digestif_core`): `Jcs` (RFC 8785), `B64url`, `Keys`,
`Crypto`, `Phrase`, `Envelope`, `Bodies`, `Request_sign`, `Keystore`, `Log` (SQLite), `Fold`,
`Quiet_hours`,
`Relay_client`, `Sync`, `View`, `Service`, `Asks` (the ask store, in the log's database) and
`Url_handler`. `web/` is the localhost server (`Digestif_web`): `Http`, `Server`, `Api`, `Store`,
`Deny`, `Content`, `Sources`, `Behaviors`, `Demo`, and `Assets`, generated from `web/ui` by `web/embed`.
`invite/` is `digestif-node.invite` (`Digestif_invite`): invite codes, the dinner, the invite email,
the guest's join, the host's join watcher (`Host_watch`, whose ledger is `invites.json` beside the
log) and `Invite_node`, which runs them on a node. `bin/` is the command line. `test/` runs the core
and the invite flow against two in-process relays. `update/` is self-update
(`digestif-node.update`, docs/releases.md) on the core's `B64url`, `Keys` and `Crypto`, and
`digestif-update`, the release signer's tool.

## Invites

`digestif invite` writes the dinner as the next envelope of this device's chain (a node with no root
is founding its circle, and the dinner becomes the root), records an invite per guest, prints each
guest's email with a `mailto:` link for the host to send from their own address, and syncs, which
appends the dinner to every relay. The guest runs `digestif join` with the invite text or the
`digestif://join` link (`digestif url-handler install` makes the link open it in a terminal): it
sets the machine up from the phrase, reads the dinner through the bootstrap read signed by the invite
key, appends the join to every relay the dinner lists, and publishes a card named as the host named
the guest (`--agent-name` names their agent; `digestif card` changes either). A member with no card
reads as the name their invite gave them. A host with no card gets one from the `--from` name their
invite emails are signed with. Every sync on the host runs the join
watcher over the joins it stores: a join the host recorded as expected (`digestif invite expected`)
is printed, and any other is an ask, `join:<invite key>`, answered `confirm` or `revoke`. A revoke
is signed by the identity key, so it reads the phrase.

## Sync

A sync reads each relay from the cursor kept for it, verifies every envelope's hash, signature and
body hash, and stores the union. It then folds the union (protocol.md, The admission fold), records
forks, gaps and broken chains as faults, applies retracts, and pushes to each relay every envelope of
this node's own that the relay does not hold. A relay missing a range is backfilled from the relays
that hold it, and repaired with this node's own envelopes; a node cannot repair a relay with another
author's envelopes, because a relay accepts an append only from its author.
