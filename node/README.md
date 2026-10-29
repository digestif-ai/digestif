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

The phrase is read from stdin by every command that needs it (`init`, `device publish`, `revoke`,
`join`, and `asks answer` when it revokes),
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
    digestif invite --date <d> --label <l> --guest "Name <email> [mac|linux]"...
                                             sign a dinner, append it to every relay, print each email
    digestif invite expected <guest> | list  record that a guest installed; the invites and their state
    digestif join <invite text or link>      join with an invite (phrase on stdin)
    digestif asks | asks answer <key> <option>  what this node needs decided, and the answer
    digestif url-handler print|install|uninstall  make digestif://join links open digestif join
    digestif run                             sync on an interval and when the machine wakes
    digestif service print|install|uninstall  the launchd agent or systemd user unit
    digestif conformance sync ...            the conformance suite's node adapter

The data directory is `$DIGESTIF_HOME`, else `~/Library/Application Support/Digestif` on macOS and
`$XDG_DATA_HOME/digestif` on Linux; `--data-dir` overrides it.

## Layout

`core/` is the library `digestif-node.core` (`Digestif_core`): `Jcs` (RFC 8785), `B64url`, `Keys`,
`Crypto`, `Phrase`, `Envelope`, `Bodies`, `Request_sign`, `Keystore`, `Log` (SQLite), `Fold`,
`Relay_client`, `Sync`, `View`, `Service`, `Asks` (the ask store, in the log's database) and
`Url_handler`. `invite/` is `digestif-node.invite` (`Digestif_invite`): invite codes, the dinner, the
invite email, the guest's join, the host's join watcher (`Host_watch`, whose ledger is `invites.json`
beside the log) and `Invite_node`, which runs them on a node. `bin/` is the command line. `test/`
runs the core and the invite flow against two in-process relays.

## Invites

`digestif invite` writes the dinner as the next envelope of this device's chain (a node with no root
is founding its circle, and the dinner becomes the root), records an invite per guest, prints each
guest's email with a `mailto:` link for the host to send from their own address, and syncs, which
appends the dinner to every relay. The guest runs `digestif join` with the invite text or the
`digestif://join` link (`digestif url-handler install` makes the link open it in a terminal): it
sets the machine up from the phrase, reads the dinner through the bootstrap read signed by the invite
key, and appends the join to every relay the dinner lists. Every sync on the host runs the join
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
