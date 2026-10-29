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

The phrase is read from stdin by every command that needs it (`init`, `device publish`, `revoke`),
so it never lands in an argv or a shell history.

## Commands

    digestif phrase new                      a new 24-word recovery phrase, stored nowhere
    digestif init --root <hash> --relay <url>  set up this machine from the phrase on stdin
    digestif sync                            read every relay, verify, fold, push what a relay lacks
    digestif circle                          the fold: epoch, admitted keys, cards, relays, refusals
    digestif log | show <hash> | faults      the log, one envelope, forks and gaps
    digestif post --kind <kind> --body <file>  sign the next envelope of this device's chain
    digestif card --name <n> --agent-name <n>  publish this member's card
    digestif device publish --role mail      admit the mail key (phrase on stdin)
    digestif revoke <key> | retract <hash>   revoke a key (phrase on stdin), retract a note
    digestif run                             sync on an interval and on wake; self-update daily and on wake
    digestif update check|apply|pin|unpin    what a self-update would install, install now, pin a version
    digestif service print|install|uninstall  the launchd agent or systemd user unit
    digestif conformance sync ...            the conformance suite's node adapter

The data directory is `$DIGESTIF_HOME`, else `~/Library/Application Support/Digestif` on macOS and
`$XDG_DATA_HOME/digestif` on Linux; `--data-dir` overrides it.

## Layout

`core/` is the library `digestif-node.core` (`Digestif_core`): `Jcs` (RFC 8785), `B64url`, `Keys`,
`Crypto`, `Phrase`, `Envelope`, `Bodies`, `Request_sign`, `Keystore`, `Log` (SQLite), `Fold`,
`Relay_client`, `Sync`, `View`, `Service`. `bin/` is the command line. `test/` runs the core against
two in-process relays. `update/` is self-update (`digestif-node.update`, docs/releases.md) on the
core's `B64url`, `Keys` and `Crypto`, and `digestif-update`, the release signer's tool.

## Sync

A sync reads each relay from the cursor kept for it, verifies every envelope's hash, signature and
body hash, and stores the union. It then folds the union (protocol.md, The admission fold), records
forks, gaps and broken chains as faults, applies retracts, and pushes to each relay every envelope of
this node's own that the relay does not hold. A relay missing a range is backfilled from the relays
that hold it, and repaired with this node's own envelopes; a node cannot repair a relay with another
author's envelopes, because a relay accepts an append only from its author.
