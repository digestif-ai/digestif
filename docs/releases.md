# Releases and self-update

How a node decides what code to run. The rules are in `node/update/lib/policy.ml`, a node's own
commands are `digestif update check|apply|pin|retry|unpin`, a signer's tool is `digestif-update`, and who
holds the keys is [GOVERNANCE.md](../GOVERNANCE.md).

## The rule

A node installs a release only when every key in its **signer set** signed it. The signer set is
Mike's and Roman's release keys. The binary is built with the set in
[`node/update/release-signers.json`](../node/update/release-signers.json), and after that only a
release both signers signed changes it. A build whose file names fewer than two signers installs nothing, and
`digestif update check` says so.

A node keeps its set in `update.json`, beside the set the build that last loaded the file names.
When the running build names a set the file has not seen, the stored set is a strict subset of it,
and it names no revoked key, the node takes the build's set as it loads the file, so a node first
started by a build that knew one signer reaches the published set by running a newer build, with no
fresh install. This does not weaken the rule: the build is one the member compiled or installed, so
it is already their trust root, and whoever could change the set it embeds could as well change the
code that checks signatures. A build already seen never changes the set again, so a signed change
that removes a signer (below) holds on a node still running the build that named it. A stored set is
never shrunk this way, and only a signed signer-set change replaces a set the build's does not
contain.

- **Newer only.** A node considers releases newer than the one it last ran healthy, never older,
  so a channel replaying an old release cannot roll a node back. Moving back to the last healthy
  release on the node's own disk after a failed switch (below) is not a downgrade: nothing is
  fetched for it.
- **Refused for good.** A release whose self-test answered no, or that crashed after a switch, is
  recorded in `update.json` and never chosen again; a newer release is. A failure that may be the
  machine rather than the release (a self-test past its bound, a trial that did not report healthy
  in time or exited for its environment) is a strike: the node tries again after the backoff and
  refuses the version only on its third. `digestif update retry
  0.4.1`, or Try again on the Feed line, forgets one refusal (or ends a pending stage's backoff) and
  makes the next pass due at once, for a refusal a person judges was the machine.
- **Pinning.** `digestif update pin 0.4.1` makes the node install exactly that version and nothing
  newer; `unpin` follows the newest release again. A pin never waives a signature. A pin at or below
  the installed version installs nothing; going back is a manual reinstall.
- **Withholding halts.** Either signer stops every update by not signing. A channel that withholds
  a release has the same effect and no other, because everything in it is verified.

## Changing the signer set

The signer set is the circle's admins, one set per channel and shared by every circle on it. A
change is a `digestif-signers-v0` document, the whole new set, in the same format as
`node/update/release-signers.json`:

```json
{ "format": "digestif-signers-v0", "created_at": "2026-11-14T15:00:00.000Z",
  "signers": [ { "name": "Mike Bryzek", "key": "ed25519:..." }, { "name": "Roman Cherkasov", "key": "ed25519:..." },
               { "name": "Sasha Ivanova", "key": "ed25519:..." } ] }
```

An entry may name its holder's circle `identity` beside `name` and `key`; a circle reads it to tell a
sitting admin from a member ([protocol.md](protocol.md), circle), and the channel and a node's
update state ignore it.

Each signature is over `DIGESTIF-SIGNERS-V0\n<document bytes>`. It is accepted only when:

1. every key in the current set signed it,
2. every key in the new set signed it, which proves each new key is held by someone,
3. the new set has at least two keys, no key twice, and no revoked key.

It is signed as an approval (Approvals, below): a promotion adds a member's key, a removal takes
one out, and a replacement moves an admin to a new key. It reaches nodes on the circle as a
`signer_set` message ([protocol.md](protocol.md)) and in the channel under `signers/` (The
channel), and a node adopts it, checked against the set it holds, from whichever it reads first.

A manifest never changes the set: one carrying a `signers` list is refused. A node adopts each
change into `update.json` as it folds the circle or reads the channel, even past a pin: adopting a
set installs no code, and a pinned node must still verify the release it is later unpinned onto. It
folds the chain link by link in `created_at` order, each checked against the set before it, so a
node first started by an older build reaches the current set, and it adopts no document twice, so
a replayed promotion a later removal undid changes nothing. A node that adopts a change from the
channel and finds its circle without it posts it there, and every change the node holds that the
channel lacks is published by the next `sign --next` any admin runs (The channel).

`digestif-update verify --channel <channel>` checks a manifest against the set the channel's
`signers/` chain leaves, from the build's own; `ci/release.sh` passes it once the channel lists a
change, so a version the new set signed reaches the test nodes and one the old set signed does not.

## Approvals

An invite and a change of the signer set are approvals: every admin signs them with their release
key, exactly as they sign a release ([protocol.md](protocol.md), Approvals). An admin starts one
from Members on their node; every admin, and on a promotion the member being promoted, gets an
Inbox item showing the one command to run:

    digestif-update approve <id>

It prints what it signs (the guest and the email, or the new signer set) for the key `signer.json`'s
`public_key` names, asks once, and only on `y` reads the release key the way `sign --next` does
(Where the key comes from), into memory only, refusing a key that is not that `public_key`; then it
hands the signature to the local node's API, which seals it to the approval's readers. Without a
`public_key` in `signer.json` the key itself is the only way to know whose approvals to show, so it
is read first. The node never holds,
asks for or receives the secret half. With no id it lists the approvals waiting on this key. A
promoted member makes their key first, with `digestif-update keygen` into `~/Downloads` and the
steps of Where the key comes from, and their `approve` is the approval's first signature, which
completes the document with their public half. An admin moving to a new key starts the replacement
themselves:

    digestif-update signers propose --replace <old key> --with <new key>

and the new key signs first with `approve`. A decline needs no release key: it is the item's
Decline. One decline, or seven days without the last signature, ends an approval and sends
nothing.

Two documents are signed this way, each over its own domain line:

| Document | Domain line | What it does once every key signed it |
|---|---|---|
| `digestif-admission-v0` | `DIGESTIF-ADMISSION-V0\n` | The starting admin's node writes the dinner listing the guest with the admission beside the entry, and sends the email the admins signed |
| `digestif-signers-v0` | `DIGESTIF-SIGNERS-V0\n` | Every node and relay of every circle on the channel adopts the new set |

A recall and a key revocation stay one signer's act (A recall, Revoking a release key).

## Removing a member

One admin removes a member, with no approval ([protocol.md](protocol.md), revoke): the review
item and the member page show the command, run on the admin's own machine:

    digestif-update remove <identity>

It reads the key as `approve` does (the circle's own admin key when its folder holds one, else the
release key, read only on `y`), asks the node for the revoke's claim (the target, the key and the
cutoffs its log holds once every relay is fetched), prints who is removed, signs the claim in
memory and hands the signature to the node, which posts the revoke with its own device key. A
member whose identity a key of the signer set is bound to is a sitting admin and is refused before
anything is signed, by the command and by the node: Remove as Admin on their member page takes the
key out first, by a removal approval.

## Revoking a release key

A revocation names one key and is signed by any key in the current set. From then on:

- no ordinary release installs while a revoked key is in the set: updates halt, and so do
  admissions in every circle on the channel, since no admission counts and no approval but a
  removal or a replacement starts;
- the only release that installs is a signer-set change, signed by every current key (a leaked key
  is still held by its owner) and by every new key, naming a set without the revoked key;
- a revoked key never enters a signer set again.

Any one signer revokes a key with their own release key, read as `recall` reads it (A recall):

    digestif-update revoke ed25519:SMoh... --reason "Laptop stolen."

It writes `revocations/<key>.json` (the key without its `ed25519:` prefix) beside its
`.sig.json`, listed under `revocations` in `index.json`, through the same channel writer as a
recall: one commit to `release/` on main and one to the `channel` branch, with the signer's own
`gh` login. The document is written once, and a second signer revoking the same key signs the
bytes already there. It then prints the line that posts the same revocation on the circle from a
machine running a node; `--channel DIR` writes into a checkout on disk and commits nothing.

The revocation reaches nodes two ways: in the channel, and on the circle as a `release_revocation`
message carrying the same document and signatures ([protocol.md](protocol.md)), so a node whose
channel is unreachable or withholds it still halts. `digestif-update circle-body <revocation>` prints
that message's body from the published document and its `.sig.json`. Either way the node checks the
signatures against its own signer set and records the revoked key in its update state.

A revocation grants nobody anything: whoever holds a leaked key can at worst halt updates, which
withholding a signature already does. A key that is lost rather than leaked cannot sign the change,
so recovery from it is a fresh install of a build carrying the new set, announced in the repo.

## The channel

The channel is `release/` on main of this repository, served over https at
`https://raw.githubusercontent.com/digestif-ai/digestif/main/release/`: the **release list**,
`index.json`, naming the versions on offer, and the revocations, recalls and signer-set changes
that take trust back. `digestif run --feed` names another channel, and a local directory works too.
A version's manifest and its signatures are not copied into it: the list names the
`manifest.json` and the combined `manifest.sig.json` of the version's GitHub release by their https
urls, and the archives are assets of that release too; a relative `url` is resolved against the
channel.

```
release/index.json
release/revocations/<name>.json
release/revocations/<name>.sig.json
release/recalls/<version>.json
release/recalls/<version>.sig.json
release/signers/<name>.json
release/signers/<name>.sig.json
```

**The release list keeps the seven newest published versions**, plus the newest no recall takes
out when it is older, so a run of recalls never leaves a new member with nothing to install.
`ci/release.sh publish` adds a version and trims the rest in one commit; main's history holds every
earlier state of the list. A node needs no old entry to reach a new one (it takes the newest listed
version no recall takes out whose signatures pass), and it reads the manifest and signatures of
every listed version newer than its own, so the count bounds a node's reads at fourteen. The one
thing a member loses: `digestif update pin <version>` works only for a listed version.
**Revocations, recalls and signer-set changes are never trimmed by count**: a revocation must never
lapse, and a node that was off for months folds the signer-set chain link by link. A recall goes
with its version's list entry.

**The release list is the one record of what is published.** No reader chooses a version by GitHub's
Latest mark but a relay older than the one that renders `install.sh` (its tag holds no
`relay/src/install-render.ts`), which answers `https://digestif.io/install.sh` from
`releases/latest/download/install.sh`. So `publish` reads the deployed relay's version and marks the
version Latest only while that relay is one, or its version cannot be read; once a relay that
renders is deployed, no release is marked Latest.
`publish` still clears the prerelease flag, which then says only that the release's files are final
because a list entry points at them: `drop` refuses to delete such a release, and `candidate` skips a
version already sent on. Every reader that picks a version (the `digestif-update` `ci/release.sh`
checks a new version with, the break-glass deploy's fallback download) takes the newest listed
version no recall takes out.

Who writes it, each through one writer: `ci/release.sh publish` lists a version (Cutting a
release), and every take-back is a signer's own act, written by `digestif-update`'s one channel
writer with the signer's own `gh` login: `recall` (A recall), `revoke` (Revoking a release key) and
`sign --next`, which before it signs a version publishes every `digestif-signers-v0` its node holds
and the channel lacks, so the channel and `ci/release.sh`'s check hold the new set before the next
release ships. The writer clones `release/` of main, shallow and sparse, and the `channel` branch,
writes into each, and pushes one commit to each it changed, starting again from new clones when a
push loses a race. A commit that touches only `release/` is no new code: `release/` is in neither
`ci/release-paths` nor `ci/relay-release-paths`, so its rollout tags nothing, and the Release
workflow ignores a push to main touching only `release/`.

### The channel branch, for nodes older than the move

Every version before the first one that reads `release/` on main reads the root of the orphan
`channel` branch (`https://raw.githubusercontent.com/digestif-ai/digestif/channel/`), which keeps its
old layout: `index.json`, `<version>/manifest.json` and `<version>/manifest.sig.json`, and the same
`revocations/`, `recalls/` and `signers/`. An installed node reads the branch until it runs a
version that reads main, so the branch carries those stragglers to main:

- **A publish lists a version on the branch only when no version the branch names that reads main
  is unrecalled.** A version reads main when its tag holds `release/index.json`. So the first
  version that reads main is listed on both, every later publish writes only `release/`, and the
  branch is left in place and readable, its index naming a version that reads main. A node older
  than that takes it from the branch and reads main from its next pass. A recall of that hop
  version makes the next publish list on the branch again, so a straggler is never stranded on its
  old version. No member's node reads the branch for anything else.
- **Every recall, revocation and signer-set change is written to both**, by `digestif-update`'s
  channel writer, for as long as the branch is readable. A `digestif-update` older than the move
  still writes the branch alone, so `ci/release.sh` reads the take-backs as one set before it checks
  anything (`channel_read`): main's `release/` with every take-back the branch holds that main lacks
  (a recall only while main lists its version, so a trimmed recall is not brought back, and the
  signatures of a document both hold joined). `signatures`, `candidate`, `channel` and a test
  node's feed check a version against that set, and `publish` commits that same set to main's
  `release/` in the commit that lists the version, so a node reading main folds the change before
  it meets the version. The files are signed, and every reader checks them against its own set, so
  reading or copying them vouches for nothing.
- A recall a signer makes runs `~/.local/bin/digestif-update`, the node's own copy, which reads
  main once that node has updated. **Each signer runs `digestif-update signer install` again from
  the first version that reads main**, so the signing job's pinned copy writes take-backs to both
  addresses too (The signing job).

The branch also still holds `changelog/<commit>.json`, an earlier What's new hand-off, and its
earlier `candidate/` and `relay/` records, which nothing writes or reads any more (the Release
workflow reads What's new from the tag alone: What's new), and a node's pre-move manifest copies.

`index.json` is unsigned and lists where things are. Its `version` is only a hint to skip fetching
old manifests; the version that counts is the manifest's own. Because nobody signs it, a node bounds
what it lets the index make it read: under an https channel an entry is a path relative to the
channel or an https URL, never a path on the node's own disk; every document is read to at most
1 MiB; and an archive is read no further than the size its signed manifest states. A channel that
names anything else costs that entry, reported as a problem, and the rest of the pass goes on.

```json
{
  "format": "digestif-feed-v0",
  "releases": [
    { "version": "0.2.0",
      "manifest": "https://github.com/digestif-ai/digestif/releases/download/v0.2.0/manifest.json",
      "signatures": "https://github.com/digestif-ai/digestif/releases/download/v0.2.0/manifest.sig.json" }
  ],
  "revocations": [
    { "document": "revocations/2026-11-roman.json", "signatures": "revocations/2026-11-roman.sig.json" }
  ]
}
```

A manifest:

```json
{
  "format": "digestif-release-v1",
  "version": "0.2.0",
  "published_at": "2026-11-02T18:00:00.000Z",
  "notes": "What changed, in a sentence or two.",
  "artifacts": [
    { "platform": "darwin-arm64", "url": "https://github.com/digestif-ai/digestif/releases/download/v0.2.0/digestif-darwin-arm64.tar.gz",
      "sha256": "sha256:<64 lowercase hex>", "size": 4353960 }
  ]
}
```

A manifest carries no `signers`: the set changes only by a `digestif-signers-v0` (Changing the
signer set). Platforms are `darwin-arm64`,
`darwin-x86_64`, `linux-x86_64` and `linux-arm64`.

An artifact is a release archive, a gzipped tar of everything the node runs: `bin/digestif`,
`behaviors/` with its `bin/`, `src/`, `prompts/`, `launchd/` and `package.json`, and `runtime/`, the
platform's Node.js (`runtime/bin/node` and its `LICENSE`) the behaviors run with. It also carries
`bin/digestif-update`, the signer's tool, so a signer signs the next version with a tool from a
version both signers already signed (Signing a release). Code the node runs moves together, so a
release never updates the binary and leaves the nightly prompt, the digest reader or the runtime
they need behind, and the runtime is signed with the code. A node built before
`digestif-release-v1` refuses these manifests as unreadable and is upgraded once by hand
(`./install.sh`).

A revocation:

```json
{ "format": "digestif-revocation-v0", "key": "ed25519:...", "reason": "Laptop stolen.", "revoked_at": "2026-11-03T09:00:00.000Z" }
```

Signatures sit beside each document:

```json
{ "signatures": [ { "key": "ed25519:...", "signature": "<base64url, no padding>" } ] }
```

Each signature is Ed25519 over a domain line plus the document's exact bytes as published:
`DIGESTIF-RELEASE-V0\n<manifest bytes>`, `DIGESTIF-REVOCATION-V0\n<revocation bytes>` or
`DIGESTIF-SIGNERS-V0\n<signer set bytes>`. There is no
canonical encoding to agree on; reformatting a manifest after signing breaks every signature, and
the domain line keeps a release signature from being replayed as a revocation.

The signers' tools sign a document only in the one form its renderer writes: `sign --next` refuses a
manifest whose bytes are not what `digestif-update manifest` or `relay-manifest` writes for what they
parse to, and `approve` refuses an admission or a signer set whose bytes are not the node's rendering
of it. Every reader, the node's and the relay's alike, refuses a document holding an object member
twice, which OCaml would read the first of and `JSON.parse` the last of.

No signed document carries an expiry, and no reader checks one. What an expiry would bound is
bounded by the document's own rule instead:

- **A release manifest** (node or relay) cannot be replayed to move a node back, because a node
  takes only a version newer than the one it last ran healthy, never takes a refused version
  again, and never takes a recalled one (A recall). A channel that serves an old manifest in
  place of a newer one is withholding, which halts updates and does nothing else (The rule). An
  expiry would add one thing, a node that notices it is being withheld from, at the cost of both
  signers re-signing every live version on a schedule and every node halting when either is away.
- **A signer-set change** is a link in a chain a node folds in order, each checked against the set
  before it; an expired link would strand every node behind it.
- **A revocation and a recall** must never lapse: an expired revocation would let a stolen key sign
  again, and an expired recall would offer the bad version again.
- **An approval** (an admission or a signer-set change being signed) is the one that ends on time:
  one decline, or seven days without the last signature, ends it (Approvals).

## When a node updates

`digestif run` reads the channel once a day, when the machine wakes (at most hourly on wakes), an
hour after a pass that failed outright, and when a failed stage's backoff has passed, as one pass of `node/update/lib/updater.ml`.
`node/update/lib/schedule.ml` decides when a pass is due, and no pass runs while a switch is on
trial. The update state is `update.json` in the node's data directory, and what passes and the
supervisor found for the person is `update-report.json` beside it:

- a release that became healthy, a release rolled back and why, a release refused and why (a
  signature missing, updates halted by a revocation, no artifact for this platform, a self-test that
  failed), a stage that failed and when it is tried again, an unreadable channel entry, and a pass
  that failed outright are each a line for the next digest's Updates section;
- a line is reported once: a refusal that holds pass after pass is in one digest, and one that clears
  and comes back is reported again;
- a pass that failed outright (the channel unreachable, as at a wake before the network is back) is
  reported only once passes have failed for a day, so a failure an hourly retry clears is in no
  digest; the line names curl's exit code and, for the common ones, what it means.

`digestif update check` prints the same state (installed, current, good, a trial, a pending stage,
refused versions) and the lines the next digest will carry. `digestif run --no-self-update` never
reads the channel; `digestif update apply` runs a pass at once.

While a stage waits or a newer release is refused, the top of the web UI's Feed says so as the state
(`node/update/lib/status.ml`): the release, why, the version the node still runs, and what happens
next. A pending stage, or a refusal that may have been the machine (a self-test that could not run
or ran past its bound, an unpack an older node refused for), offers Try again; a refusal that is the
release's own bytes says the next release replaces it and that there is nothing to do.

## Releases on disk

Each release is a directory under `<data dir>/releases/` that nothing changes once it is there: the
archive's `bin/`, `behaviors/` and `runtime/`, and `.release.json`, written last, naming its
version. Two
symlinks choose among them (`node/update/lib/layout.ml`):

- `current`: the release the service runs;
- `good`: the last release that reported healthy.

Each release carries its own Node.js, so a node does not keep them all. Once a switch is kept (the
new release reported healthy and `good` moved to it), the supervisor deletes every complete release
except `current`, `good`, the release the switch came from (the one a recall or a crash moves back
to), the release its own binary runs from, and any release newer than the one it kept, which an
update pass staged on its way to a trial of its own (`node/update/lib/prune.ml`). A directory being
staged, self-tested or deleted (its name starts with a dot) and one without its `.release.json` are
left alone. A release is renamed to a dot-prefixed name before it is deleted, so a deletion cut
short never leaves one that looks complete; the next kept switch finishes it. A
rollback deletes nothing, and neither does a recall or a move back for crashing.

The behaviors run with the release's own Node.js, by its path:
`behaviors/bin/nightly-hook` runs `nightly.ts`, and `behaviors/bin/read-hook` runs `read.ts`, with `runtime/bin/node` beside `behaviors/`, never a
`node` found on `PATH`, so a member's machine needs no Node.js of its own. A release staged from a
checkout (`digestif service install --behaviors`) carries no runtime and runs the `node` on `PATH`.
Without `--behaviors` it keeps the behaviors, and the runtime, of the release `good` names (else
`current`), and a node with neither is refused rather than given a release without behaviors. A
local release is named `local-<hash>` for everything it holds, the binary, each behavior file and a
carried runtime, so the same binary installed with other behaviors is a new release. A binary
built without the web UI (a plain `dune build` of `node/`, which embeds a page saying how to build
it in place of `ui/build`) is refused too, naming `ci/build.slow.sh`: it is never staged as a local
release, and `service install` never adopts a release whose binary is one.
The nightly hook resolves through `current`: the node runs a hook path
ending in `behaviors/<file>`, such as a checkout's `behaviors/bin/nightly-hook`, from
`current/behaviors/<file>` when the current release has that file, so a member's existing absolute
hook path keeps working and follows every release. `digestif behavior set nightly
<data dir>/current/behaviors/bin/nightly-hook` names it directly. Setup sets both hooks to the
current release's launchers, and a node that starts with no read hook, and no unset of it by the
member, sets it to `<data dir>/current/behaviors/bin/read-hook` and logs that it did.

## Staging

A pass that chooses a release stages it before anything the node runs changes
(`node/update/lib/stage.ml`):

1. download the archive and check its size and sha256 against the manifest both signers signed;
2. unpack it into `releases/.staging-<version>`, bounded at a minute, and check it holds
   `bin/digestif`. The bytes are the ones both signers signed, so an unpack that fails or runs past
   its bound is this machine (a night it crawled, a full disk) and is retried, never refused;
3. check the runtime the behaviors need by its path: `runtime/bin/node` must run and be at least the
   major version `behaviors/package.json` names in `engines`. An archive without its runtime, or
   whose runtime does not run or is older, is refused for good, since a later pass would meet the
   same bytes. A release staged from a checkout carries none and is checked against the `node` on
   the service's PATH instead, and a missing or older one is retried, since installing Node.js
   fixes it;
4. self-test: run the staged binary as `digestif self-test --data-dir <copy> --expect-version
   <version>` against a copy of the node's data (the store copied with SQLite's `VACUUM INTO`, no
   keys), bounded at two minutes. It must report the version, open the store and read its config;
5. write `.release.json` and rename the directory to `releases/<version>`.

A failure leaves `current` alone. A download, an unpack, a write or a checkout's missing Node.js is kept in
`update.json` as pending with its cause, and tried again after a backoff (ten minutes, doubling, at
most a day). A self-test that runs past its bound or cannot be started may be the machine as much as
the release: it is kept as pending the same way and counts a strike, and the third strike refuses the
version. A self-test that answers no, or an archive without the binary or a runtime that runs,
refuses that version for good.

## Switching

A node runs under a supervisor once `digestif service install` has set up `releases/`, `current`
and `good`: the launchd agent (through its launcher, The launcher) or systemd unit runs `good/bin/digestif supervise`, the binary of the
last healthy release, and the supervisor runs `current/bin/digestif run` as its child
(`node/update/lib/supervisor.ml`). On a node not yet supervised a pass stages the release and the
digest says to run its `service install` once. Releases live once per machine: the first node's
supervisor runs every circle folder's node from the release its `good` names, and those nodes
never update themselves, so one switch, trial or recall moves every circle on the machine
(node/README.md). A machine whose standard place holds no node judges each release by the first
circle folder's node, which its supervisor runs in that place.

`digestif service install` makes the binary it runs the node's release: the release directory the
binary sits in, else the staged release holding the same binary (an archive staged with `digestif
update stage` and installed from the unpacked copy), else, or with `--behaviors`, a local release
`local-<hash>` staged from the binary. `current` and `good` both name it, and `installed` in
`update.json` becomes its version when that is newer. Every pass counts the version of the release
`good` names as installed the same way, so a node never plans a release older than the one it runs
healthy, whatever `update.json` said before. `digestif update check` prints the channel it reads.

To switch, the pass records a trial in `update-trial.json` (the new release, and the one `good`
names to move back to), points `current` at the new release, and exits. The supervisor starts the
new release and watches it:

- `digestif run` writes `health.json` (its version and pid) once it has started: its store open and
  initialized and its web UI serving, before its first pass, whose length grows with the node's
  history and says nothing about whether the release runs. The new release is then kept: `good` moves to it,
  `installed` in `update.json` is saved, and the digest says "Updated Digestif to <version>."
  `installed` is never saved before this.
- If the child crashes before it reports healthy, the supervisor points `current` back at the
  release `good` names, refuses the version for good, says so in the digest, and runs the previous
  release again.
- If it has not reported healthy after ten minutes of awake time, or exits for its environment (its
  UI port held) or because it was stopped, the supervisor stops it and moves back the same way, but
  the version counts a strike instead: it is tried again after the backoff, and the third strike
  refuses it.
- Awake time is counted in one-second steps: a step that took far longer than a second spanned the
  machine sleeping and counts as one second, so a laptop closed during the window does not use it
  up.
- A trial that three supervisor starts did not finish (the machine restarting mid-trial) is rolled
  back with a strike.
- The supervisor writes `update.json` as stored: it never reconciles the signer set with its own
  build's, since its binary is the oldest the node runs. A node that adopted a signed signer-set
  change holds the set the last change names: no build's set widens it, a file an older binary
  widened returns to that set on the next load, and every later signer reaches it as a signed change.
  Every write of `update.json` is synced to disk and every read-modify-write holds a lock
  (`update.json.lock`), so the pass, the web UI, the supervisor and a person's `digestif update`
  never lose each other's change.

The recovery runs in the supervisor and not in `digestif run`, because a release that crashes on
start cannot run code to fix itself, and the supervisor is always a release that was healthy. A new
supervisor takes over the next time the service manager starts it. Past the trial the supervisor
counts the child's exits, and a version that keeps crashing goes back on its own (A version that
keeps crashing).

### The launcher

macOS keeps a privacy decision (a folder read, Full Disk Access) against the program a launchd job
starts, looked up by its resolved path and checked against its code signature. The supervisor's
path names its release, `releases/<version>/bin/digestif`, so a supervisor started from a new
release was a program macOS had never been asked about, and asked again, with nobody at the
keyboard during a nightly run. So on macOS launchd starts a launcher at one fixed path,
`<data dir>/launcher/Digestif`, with the supervisor's command as its arguments
(`node/launcher/digestif_launcher.ml`). It spawns that command, never execs it, so it stays the
process macOS holds responsible for everything beneath it; forwards SIGTERM, SIGINT and SIGHUP;
and exits with the child's status, so launchd restarts the job exactly as before.

The decision holds only while the launcher's bytes do: it is ad-hoc signed by the linker, so
macOS checks it by its cdhash. Every node binary embeds the launcher it was built with beside a
digest of the launcher's source (`node/update/lib/launcher.ml`), and writes those bytes to the
fixed path, with the digest in `launcher/Digestif.source`, only when the digest there differs. A
release rebuilt from the same launcher source leaves the installed bytes alone, whatever compiler
or linker built them; a change to `node/launcher/` replaces them, and macOS asks once more on each
machine. The bytes are part of a binary both release signers signed (or one the member built), so
the rule that decides what a node runs is unchanged, and no Apple signature is needed or checked.

The launcher is written by the supervisor when it starts, always a release that was healthy, and by
`digestif service install`; a release on trial never writes it. The plist names it once it is
there: `service install` loads the new plist at once, and a node launchd started rewrites its plist
to name it (DIG-323), which launchd reads at the next load (the next login). A launcher that cannot
be written leaves the job starting the supervisor directly. Linux has no such decision and runs the
supervisor directly. DIG-492

## Cutting a release

A version is a tag of `main`, `v<MAJOR.MINOR.PATCH>`, and nothing in the tree names one. A release
is that one commit, built for every platform in one run of the Release workflow
(`.github/workflows/release.yml`), and a signer only ever signs the manifest that run wrote. The
platforms a release ships are named once, in `ci/platforms.json`, with the GitHub runner each
builds on: `darwin-arm64`, `linux-x86_64` and `linux-arm64`.

Every build takes its version from the tag: `ci/version.sh` prints the release tag on `HEAD` without
its `v`, and `ci/release-artifact.sh`, `ci/release-linux.sh` and `install.sh` stamp it into both
binaries through `DIGESTIF_VERSION` (`node/update/lib/dune`), so a node's check that a release's
binary reports the manifest's version holds by construction. A build of any other commit reports
`0.0.0`, which every release is newer than, so a node built from `main` takes the newest signed
release on its next update pass. It is `0.0.0` and not a suffixed version because the node reads
its own version with the same strict parser it reads a signed manifest with. `ci/version.sh`
refuses a tagged checkout whose release paths carry uncommitted changes, so no archive holds code
its tag does not. The Release workflow asks once, in its plan, and every build of the run takes
that answer as `DIGESTIF_VERSION`: a tag pushed onto the commit while a run is under way (cutting
a version seconds after the push to `main`) starts its own run and leaves the dry run building
`0.0.0`.

`ci/release-paths` names what an archive is built from: the node and its UI, the parts of
`behaviors/` a release carries, and the scripts that build it. A commit touching none of them puts
nothing new on a member's machine, so it is not a new version: `ci/release.sh changed` answers
`unchanged` for it.

1. Push the tag. `ci/release.sh build` tags `origin/main` with the next patch of the newest release
   tag and pushes it; a minor or major version is a person's tag (`git tag v0.2.0 <commit> && git
   push origin v0.2.0`), which `ci/release.sh build --version 0.2.0` then builds without minting
   anything. Pushing the tag is the whole dispatch: the Release workflow runs on every pushed
   `v*` tag, and refuses one that is not `v<MAJOR.MINOR.PATCH>`, one on a commit that is not on
   `main`, and one whose GitHub release is already published.
2. The run builds each platform with `ci/release-artifact.sh` (on Linux inside
   `ci/release-linux.sh`'s Alpine container), which puts the platform's Node.js in the archive's
   `runtime/` through `ci/node-runtime.sh`: the official build pinned, with each platform's
   sha256, in `ci/node-runtime.json`, so moving to another Node.js is an edit of that file. It then
   stages each archive on a fresh machine with `ci/release-check.sh`, which runs `digestif-update
   stage-test`: the checks a node runs on a release it stages (below). On Linux that machine is a
   container holding no Node.js, so a release that leans on a `node` found on `PATH` fails there.
3. Only when every platform passed does it leave a **draft** GitHub release `v<version>` holding
   every archive, every platform's `digestif-update` as `digestif-update-<platform>`, `install.sh`
   (the hosted install script, below, written from the manifest by `ci/install-hosted.sh`), and
   `manifest.json`, written by `digestif-update manifest --platforms ci/platforms.json`, which
   refuses a manifest missing any platform in that file. The manifest's notes are the commit titles
   since the newest version the release list names, or the tag's own message when a person wrote
   an annotated tag (a tag whose message is a What's new ledger, What's new, takes the titles). Every one of those files is attested first, with a GitHub artifact attestation by this
   workflow on the tag at the commit it built (What ties a version to its build). A draft is
   readable only by people with write access until it is published. One failed
   platform leaves no draft and no manifest, so nothing partial can be signed. Nobody edits the
   manifest after; running the workflow again on the same tag replaces the draft's files and drops
   any signature beside them. `ci/release.sh build` succeeds once the draft holds all of it.
4. Each signer runs `digestif-update sign --next`, which shows what the version holds, asks, and
   uploads their signature to the draft (Signing a release).
5. `ci/release.sh candidate --version <version>` downloads the manifest and every signer's
   `manifest.<signer>.sig.json` asset of the release and checks them with `digestif-update verify`,
   a node's own check against the signer set the channel's take-backs leave (The channel branch,
   for nodes older than the move), run from the `digestif-update` the newest listed version no
   recall takes out holds for the machine's platform, so the version under review never vouches for
   itself (the draft's own copy is used only before any version is listed). It
   exits 75 and changes nothing while a signer has not signed, which is what keeps Release now on
   a rollout from sending an unsigned version on. Once every signer signed, it uploads the
   signatures, one per signer, as the release's combined `manifest.sig.json`, the one signatures
   file a node reads; publishes the GitHub release as a prerelease that is not Latest, so the
   archives can be fetched by a test node while no list names the version; and dispatches main's
   Release workflow with the version as its `candidate` input, which starts the test nodes. Run
   again, it dispatches again.
6. Once every test node passed (`ci/release.sh test-nodes`, Test nodes), `ci/release.sh publish
   --version <version>` lists the version in `release/index.json` on main, by the https urls of its
   release's `manifest.json` and `manifest.sig.json`, in one commit pushed straight to main as
   `channel_commit` pushes the branch (from main as fetched, started again from the new head when
   the push loses a race). The same commit trims the list (The channel) and copies in every
   take-back the branch holds that main lacks. It lists the version on the `channel` branch too
   only when no version the branch names that reads main is unrecalled (The channel branch, for
   nodes older than the move). Then
   it clears the release's prerelease flag, marking the release Latest only while the deployed relay
   reads that mark (The channel). From then on members' nodes
   take it on their next update pass, and the relay's `https://digestif.io/install.sh` offers it
   (below).

The same workflow runs as a dry run on every push to `main`, every pull request, and by hand: it
builds and stages every platform at the version the commit is and uploads nothing, so a change that breaks one
platform shows within minutes rather than on release day. It is the only automated build of macOS;
`ci/build.slow.sh` builds Linux on the fleet's builders.
The one pull request it skips is a fleet merge build's (head branch `batch-*`): its land merges it
seconds after it opens, so the push to `main` that follows builds the same tree.

### What's new

A node's What's new page (`/changelog`, opened from the version in its footer) reads the
`changelog.json` its build embeds, so a member reads what each release changed offline and without
an idempotent login. The build writes it with `ci/changelog.sh <version> [<ledger>]`: every version
up to the one built, newest first, each with its `released_at` and entries (a summary and a
category), the shape `ui/src/lib/changelog.ts` reads. `ci/release-artifact.sh` puts it in place of
the empty `ui/static/changelog.json`.

The entries are the Digestif product's entries of the changelog idempotent writes (`dev changelog
build`). Only an identity idempotent admits reads them, and the release command holds none, so the
Digestif rollout's job reads them (`GET /dev/changelog/releases?repo=digestif-ai/digestif&product=digestif`)
once `ci/release.sh changed` answers `changed`, writes them to a file and cuts the version's tag
itself as an annotated tag whose message is that file, kept verbatim, so the ledger rides in the push
that starts the run, attached to the one thing it describes; the Release run on the tag reads its
own tag's message. The job cuts the same tag `ci/release.sh build --changelog <file>` would, and
writes the ledger only for a checkout whose `ci/release.sh` takes `--changelog`. Notes are
written after a version is released, so a version carries every earlier version's entries and its
own as the commit titles its manifest's notes hold, which the next release replaces with its
entries. A version whose notes are not written yet, and every version when the run finds no ledger (a tag a
person pushed carries none), carries its commit titles the same way.

### A job no runner took

GitHub-hosted macOS arm64 runners run short. A job waiting for one is cancelled after about fifteen
minutes with the annotation `The job was not acquired by Runner of type hosted even after multiple
attempts`, and the run fails though nothing in the code is wrong. When a Release run fails,
`.github/workflows/release-retry.yml` runs `ci/release-retry.sh`, which reads the attempt's jobs and
each failed or cancelled job's annotations, and re-runs the run's failed jobs when every one of them
carries that annotation, while the attempt is below the third: two retries, then the run fails as it
stands. A job that failed for any other reason is never retried, so a real red still fails.
GitHub Actions mail is off: a push, tag, dispatch or scheduled run still red five minutes after its
last attempt, with no retry after it, reaches the owner as one Inbox notice linking that attempt,
and a retry that comes later takes the notice back (platform's `RedWorkflowRunNotices`). A retried
attempt files nothing.
`ci/release.sh build` waits through a retry, and a test node's job restarted this way reads
`running` until its attempt ends.

It is not a self-hosted Mac: a test node stages each archive on a clean machine the way a member's
node does, which a kept Mac is not, and the repository is public and builds every pull request, so a
fork's code would run on that Mac.

A signer's key is made once with `digestif-update keygen <secret file>`, which prints the public
half and writes the secret with mode 0600. Put the secret in your password manager and delete the
file; signing from a machine that runs a node is fine, since `sign --next` writes nothing of the key
to its disk.

### What a node needs on Linux

The Linux binaries are linked statically against musl (the `static` profile in `node/dune`), so they
need no libc, SQLite or other shared library from the member's distribution, and run on any
x86_64 or arm64 Linux. The Node.js in `runtime/` is the official Linux build, which needs glibc 2.28
or later, so a musl distribution such as Alpine does not run the behaviors. `ci/release-artifact.sh` prints what each binary links (`ldd` on Linux,
`otool -L` on macOS) and refuses a Linux binary that is dynamic or a macOS binary that links
anything outside `/usr/lib` and `/System`. The node runs Node.js from the release's own `runtime/`
and these programs from `PATH`:

- `curl`, to reach relays and the release channel;
- `tar`, to unpack a release;
- `secret-tool` (libsecret-tools) and a running Secret Service, for the keystore;
- `systemctl`, for the service.

`./install.sh --service` on Linux installs a systemd user unit, `~/.config/systemd/user/digestif.service`,
that runs `good/bin/digestif supervise`, and enables and starts it with `systemctl --user enable
--now`; on macOS it installs the launchd agent. A user unit runs while its user is logged in;
`loginctl enable-linger $USER` keeps it running without a session.

## The hosted install script

A member installs with one command, the same on Mac and Linux, which the invite email carries:

    curl -fsSL https://digestif.io/install.sh | sh -s -- --join dg1.<invite code>

`install.sh` is a POSIX `sh` script written for each release from its manifest
(`ci/install-hosted.sh` fills `ci/install-hosted.sh.in`), carrying that release's archive url and
sha256 for every platform in it. It:

1. picks this machine's platform from `uname`, and stops when the release has none for it;
2. downloads the archive and prints the sha256 it expects, the sha256 the download has, and a link
   to the release's signed manifest (the version's GitHub release page,
   `https://github.com/digestif-ai/digestif/releases/tag/v<version>`, which shows `manifest.json`
   beside every signature); a mismatch stops it with nothing installed;
3. unpacks the archive and stages it with the binary inside it, `digestif update stage <archive>`:
   the checks a node runs before it runs a release (staging, above), into `<data dir>/releases/`,
   changing nothing the node runs. A release already staged is not staged again, so running the
   command a second time resumes;
4. links `~/.local/bin/digestif` and `~/.local/bin/digestif-update` to the node's release (The
   commands on PATH, below);
5. with `--join <invite code>`, runs `digestif join <invite code>` reading the terminal, since under
   `curl | sh` standard input is the script; with no terminal it stops before the join.

It checks the sha256 and no signature, and never says it checked one: a signature check needs a
tool a stock machine lacks. Its trust rests on TLS to `digestif.io`, as every `curl | sh` does, and
the manifest link lets anyone compare the sha256 with the one both signers signed. Every update
after the install is checked against both signatures (above). Nothing is built: no git, no dune,
no npm, and no Node.js, since the archive carries its own. The repo-root `install.sh` stays the
build-from-source path for contributors.

**The relay renders it.** The `dinners` relay answers `https://digestif.io/install.sh` itself
(`relay/src/install.ts`, on the host `SITE_HOST` names in `relay/wrangler.jsonc`), and the bare
domain answers nothing else. It reads the channel's `index.json` (`release/` on main, and the channel
branch's root while main's release list names no version), takes the newest version no
recall signed by a key of the set takes out, reads that version's manifest and signatures, and
checks that every key of the signer set signed the manifest's exact bytes. The set is the one the
channel's `signers/` chain leaves, folded from the set the relay's own build carries
(`node/update/release-signers.json`, never the `RELEASE_SIGNERS` the conformance suite's top level
sets) exactly as a node folds it (Changing the signer set), with the channel's revocations applied,
so a signer-set change published on the channel moves the script without a relay release. It then
answers the template applied to that manifest, from its copy of the template
(`relay/src/install-template.ts`). A channel it cannot read, a signer set holding a revoked key, a
newest version whose manifest is not signed by every key, or a manifest the template cannot be
applied to is answered `502` with the reason, which `curl -f` stops on, never with a script and never with an
older version's. So publishing a version both signers signed publishes its script, and nothing a
writer of the repository's releases or channel replaces reaches a new member.

The Release workflow still attaches `install.sh` to the draft release, for the direct GitHub link,
written by `ci/install-hosted.sh` with the same link; `ci/install-hosted-test.sh` holds the relay's
rendering byte for byte equal to it, template and renderer alike, so edit `ci/install-hosted.sh.in`
and `relay/src/install-template.ts` together.

## Signing a release

A signer signs with one command, the same every time, from the `digestif-update` their own node
holds, which the install puts on PATH (The commands on PATH). With the key downloaded from
1Password (Where the key comes from), it is:

    digestif-update sign --next; rm -f ~/Downloads/digestif-release.key

A signer with no node installs one with the hosted install script (The hosted install script).

`sign --next` takes the version waiting for signatures, so a command copied from last week's
request is still the right one, and it sees to its own preconditions:

- **Out of date.** The node keeps the binary current: `digestif-update` on PATH is the one in the
  release `good` names, so it moves with every update the node keeps, and is only ever a binary
  the node's own check of both signatures took. When the newest node release that is not a draft
  is newer than the running binary, `sign --next` says a newer version is published and goes on
  (`node/update/lib/out_of_date.ml`); the release channel a node reads (The channel) decides which
  versions count, so a version a current signer recalled is never offered. Run from the node's
  release, it says the node takes the version at its next update check and `digestif update apply`
  takes it now; run from any other file, such as a `digestif-update-<platform>` downloaded from a
  release, which nothing replaces, it names the file and says to install a node with `curl -fsSL
  https://digestif.io/install.sh | sh` and sign with the `digestif-update` it puts on PATH. A
  newer binary is how a draft on a line an older one does not know becomes readable, so a `sign
  --next` that finds a draft on a line it does not know names it and says to run a newer one.
- **Key missing.** With a `signer.json`, the key command runs once you answer `s`, never before:
  everything is shown and the question asked with the key unread, so a Keychain or password-manager
  prompt comes only when there is something to sign, and a drop or a leave never reads the key. A
  key command that fails, prints nothing, or prints no key ends the run there in one line: for
  `cat FILE`, to download the release key from 1Password to `FILE` and run the same command again.
  Nothing is signed.
- **No `signer.json`.** The key is asked for at a hidden prompt once you answer `s` (Where the key
  comes from).

Before any version is published there is no node release to take it from, and the trusted tool is
one built from a tag you have already reviewed: `git checkout v0.1.1` in your own checkout, then
`dune build ./update/bin/main.exe` in `node/` and run `node/_build/default/update/bin/main.exe sign
--next`. It talks to GitHub with your own `gh` login, which needs write access to the repository,
since a draft release is readable by nobody else.

### The commands on PATH

`~/.local/bin/digestif` and `~/.local/bin/digestif-update` are symlinks to
`<data dir>/good/bin/digestif` and `<data dir>/good/bin/digestif-update`, so both follow every
release the node keeps (Switching) and neither is pinned to the release that was current at
install (`node/update/lib/cli_links.ml`). The hosted install script links them to the release it
staged, since `good` does not exist until `digestif service install` makes the layout;
`service install`, which `digestif join` runs, every start of the supervisor and every pass of
`digestif run` point them at `good`. The pass is what an automatic update reaches: the supervisor
already running stays up and starts the new release's `run` (Switching), so an install whose
supervisor predates a change to the links gets it from the release that carries it, and a
`digestif-update` the previous `good` lacked is linked on the first pass after the new release
becomes `good`. A link into the node's `releases/`, `current` or `good` is the install's and is moved; a
file or a link anywhere else at that path is the member's and is left alone, so a CLI
`./install.sh` copied from a checkout stays. A missing `digestif-update` is made beside an existing
`~/.local/bin`; a missing `digestif` is not, since a member who builds from source may keep the CLI
elsewhere on PATH. A release staged from a checkout carries `bin/digestif` alone, and gets no
`digestif-update` link; when `good` names one, the hosted install script links `digestif-update`
to the release it staged instead, which `service install` and the supervisor then leave alone.
The links are the standard node's: a node in a data directory of its own (a second circle's)
never moves or makes them, so the CLI on PATH stays the release of the machine's first node.

### Where the key comes from

`sign --next` reads the key from a command you name once in `~/.config/digestif/signer.json`
(`$XDG_CONFIG_HOME/digestif/signer.json` when that is set). The command prints the secret
`digestif-update keygen` made, and `sign --next` writes nothing of it to disk: it goes from the
command's output into the memory of the one process that signs. The command runs under
`/bin/sh -c`, so any password manager with a command line works. It runs once you answer `s`
(Signing a release), so a key that is not there ends the run then, with nothing signed:

```json
{ "key_command": "op read 'op://Private/Digestif release key/password'" }
```

On a Mac the login Keychain holds it with nothing to install. Add it once from the file
`digestif-update keygen` wrote (or the document 1Password downloads), with an empty list of trusted
apps, so every read asks for your Keychain password and nothing reads it silently; then delete the
file:

    security add-generic-password -U -s digestif-release-key -a "$USER" -T "" -w "$(cat ~/Downloads/digestif-release.key)"; rm -f ~/Downloads/digestif-release.key

```json
{ "key_command": "security find-generic-password -s digestif-release-key -w" }
```

Answer the Keychain's prompt with Allow, never Always Allow, which would trust `security` with the key
from then on. The line to sign is then `digestif-update sign --next` alone. The signing job (The signing job)
replaces this item with one its pinned copy created, which that copy alone reads without a prompt.

A key kept as a document that the password manager's app downloads (1Password's Download, with no
`op` installed) can also be read from where it lands, and the signing line deletes it as soon as
`sign --next` returns:

```json
{ "key_command": "cat ~/Downloads/digestif-release.key" }
```

    digestif-update sign --next; rm -f ~/Downloads/digestif-release.key

`"public_key"` is your key's public half, the `ed25519:...` line `digestif-update keygen` printed:

```json
{ "key_command": "op read 'op://Private/Digestif release key/password'",
  "public_key": "ed25519:..." }
```

With it, `sign --next` knows who you are before it reads the key, and shows only the drafts that
still need your signature (What it shows, and the question). A key that turns out not to be the one
named there signs nothing, and the run says to correct `public_key`.

`"repo"` names another repository than `digestif-ai/digestif`. With no `signer.json`, `sign --next`
asks for the key at a hidden prompt once you answer `s`: paste it, and it is read into memory with
the terminal's echo off. Run with no terminal (input piped in), it says what to write in
`signer.json` instead and signs nothing.

The manifest can also be signed by hand:
`gh release download v<version> --repo digestif-ai/digestif --pattern manifest.json`, then
`pbpaste | digestif-update sign --key /dev/stdin manifest.json`, and upload the
`manifest.sig.json` it writes as `manifest.<your key, without ed25519:>.sig.json` with
`gh release upload v<version> <file> --repo digestif-ai/digestif`. A key file that cannot be read
ends `sign` with one line naming it.

### What it shows, and the question

Several versions can wait at once. Every merge that moves a release path cuts a version, and a cut
drops no draft: a draft goes only when a newer version publishes, or when a signer drops it. So a
signature is never thrown away while it could still count, and nothing waits for anyone: the fleet's
rollout publishes the newest version every signer has signed, whichever that is, and the drafts
older than it go. A version is waiting when its draft is newer than its line's newest published
version. One `sign --next` run offers, of each line (node and relay), the newest waiting version
and every older one that one more signature completes, and signs them with one answer. The waiting
versions in between are skipped: not shown, not signed and not dropped. A draft older than its
line's newest published version can never publish, so once the question is answered `sign --next`
drops every such draft, of both lines, each said in a line, and they never pile up. Whatever one signer signed is offered to the other for
completion, so a signature is never spent on a version the other signer has not seen. Who signs is
known only once the key is read, so "one more signature completes it" means every required signer
but one has signed. A `signer.json` that names your public key (Where the key comes from) leaves
out, of both lines, every draft that already carries your signature before anything is shown,
the newest included: the run names them in one line, the question counts only what is left, and
with nothing left it says so and asks nothing. Without it, a draft only you have signed is still
offered. Either way, once the key is read, a draft that already holds your signature is never
signed or uploaded again: the run says so and moves on. An older offered version's
commits are all in the newest one's, so it shows the newest version of each line in full and each
older one in a line (who signed it, and why it cannot be signed when it cannot). A node version
every signer has signed is named and left to the rollout. For the newest version, before it asks,
`sign --next` prints:

- the version, the commit its tag names, and the Release workflow run that attests every file of
  the version (What ties a version to its build); when none does, the link to the workflow's runs
  on the tag, composed;
- every commit title since the last published version, and the compare link. Everything git holds
  (a tag's commit, the titles, a file at a tag) is read from the tool's own full bare clone of the
  repository, `~/.digestif/update/<owner>-<name>.git`, cloned on the first run and fetched
  (`--tags`) at the start of every run after, so none of it is a GitHub request and no read
  fetches a file lazily; a partial clone an older `digestif-update` made (`--filter=blob:none`) is
  cloned again in full, once;
- the manifest's notes as signed, and every archive's sha256, each checked against the digest
  GitHub holds for the draft's file;
- when the version cannot be signed, every reason why, under NOT OFFERED.
- who has already signed, with "One more signature publishes it." when only one is missing.

Then it asks once. `s` signs every version offered: it runs the key command once, refuses a key that
is not a release signer, signs each manifest's exact bytes, and uploads each signature as its
draft's asset `manifest.<key>.sig.json` (the key's base64url without `ed25519:`), holding the one
signature in the channel's signatures format, so the two signers never write the same file. `d`
drops every version offered: it deletes each draft release with every signature on it, and the tags
stay. Anything else leaves them waiting. `sign --next --sign` answers `s` itself: it shows
everything above, prints the question with its answer, and signs every version offered without
reading the terminal. `--sign` goes only with `--next`. Every signature is made first and then all
are uploaded at once, each upload being a round trip to GitHub.

GitHub is asked only for what git does not hold: one listing of the releases, read once for the
whole run, then every waiting draft's `manifest.json` downloaded at once, while the clone fetches
and, when a version has not verified on an earlier run, the Sigstore trusted root is read once
(`gh attestation trusted-root`); the signatures go back as uploads. No archive is downloaded. Every
version offered, of both lines, is then shown at once (its manifest's attestation checked),
at most six of a line at a time, so the question comes after the slowest version rather than after
all of them in turn. Every step's duration is appended to
`~/.digestif/update/sign-next-timings.log`, one line per step (the run id, the step, its seconds),
and nothing extra is printed, so a slow run can be traced to the step that was slow. Publishing a
relay version (Publishing a relay release) is the step `settle`, and each of its parts a step of
its own: `settle listing`, `settle trust`, `settle manifest`, `settle signatures`,
`settle upload`, `settle release-edit` and `settle announce`. Publishing the signer set before
anything is signed is `publish-signer-sets`, its clone, commit and push to both addresses of the
channel `publish-signer-sets push`.

The key command runs only once you answer `s` (Signing a release), so a leave or a drop never runs
it: a key command that prompts, such as `op read` asking 1Password to unlock or the Keychain asking
for its password, prompts only on a run that signs.

### What ties a version to its build

What a signer signs is the exact bytes of the draft's `manifest.json`, and anyone who can write to
the repository's releases can replace a draft's files. So the two-signer rule would hold against a
forged signature but not against one repository writer unless the files were tied to the build
that made them. They are: the Release workflow (`release.yml`) attests every archive, every
`digestif-update-<platform>`, `install.sh` and `manifest.json`, and the Relay release workflow
(`relay-release.yml`) the bundle and `manifest.json`, each with `actions/attest-build-provenance`
before the draft is written. An attestation is a Sigstore certificate GitHub issues to that run,
naming the workflow, the ref, the commit and the run; a repository writer cannot make one for a
file the workflow did not build on that tag.

Each workflow attests every file of the draft, the manifest among them, in one statement listing
every file's sha256. Before it shows a version, `sign --next` checks the sha256 GitHub holds for each
file the manifest names against the manifest's, and runs `gh attestation verify` on the manifest's
own bytes, against the trusted root it read once for the run (`--custom-trusted-root`), requiring
the signer workflow to be the line's workflow, the source ref the tag, the source commit the one it
shows, and a GitHub-hosted runner; it reads the certificate gh answers back and checks the same
fields again, and requires every file's sha256, the manifest's included, to be named by an
attestation that passed. The version's `built` line is the one run that attests every file. A file
is never downloaded for this: a draft's file whose bytes differ from the manifest's has another
digest on GitHub, and no attestation names it. What verified is remembered in
`~/.digestif/update/attested.json` (the tag, the manifest's sha256, the workflow, the commit and the
attestations that passed, the newest 200 kept), so a later run that reads the same manifest of the
same tag at the same commit takes that answer without asking gh again; a manifest replaced on the
draft has another sha256 and a moved tag another commit, and either is verified again. A tag moved after the build therefore shows a commit no attestation names, and
the version is not offered. This needs a `gh` whose `attestation verify` takes `--source-digest`.

A version is **not offered**, shown with every reason under NOT OFFERED and left out of the
question, so neither `s` nor `sign --next --sign` signs it and `d` does not drop it, when:

- a file the manifest names is not on the draft, GitHub holds no digest for it, or its digest
  differs from the manifest's;
- a file, or the manifest, has no attestation by the line's workflow on the tag at the commit
  shown, or no one run attests them all;
- a relay migration the version adds differs from the tag's file or cannot be read there;
- a relay migration the last published relay version listed has another sha256: an applied
  migration never runs again, so the edit would reach only a relay deployed fresh, and the change
  goes in a new migration.

The other versions offered are still signed by one answer; with none left the run fails, naming
the versions it could not sign. Running the workflow again on the tag rebuilds and re-attests the
draft's files. GitHub runs the workflow a tag's commit holds, so a version whose commit predates
the attesting workflows can never be attested: it is dropped, and the next version is cut.

### The signing job

A signer's Mac signs a version unattended only through the signing job: a launchd agent running a
pinned copy of `digestif-update signer run` (`node/update/lib/signing_job.ml`), which signs exactly
the node or relay manifest a decision approved (design DIG-181). idempotent's signing check records
one decision per waiting version; the job holds `GET
https://api.idempotent.io/digestif/signer/decisions` open with the signer's token, a long-poll that
answers at once with every open decision on connecting and again the moment one is recorded or
answered. The job asks again as soon as an answer arrives, with that answer's `seen`; nothing
re-reads on a timer. A request that fails is retried after a backoff (one second, doubling to five
minutes), reading every open decision again as a connect does. A 401 ends the job, since the token
is unknown or revoked, and launchd starts it again no sooner than five minutes later.

A decision's `act` is all the job reads: `wait` and `drop` sign nothing, and `sign` signs only the
draft whose `manifest.json` has the decision's `manifest_sha256`, after the job repeats the
integrity check itself: exactly the conditions under which `sign --next` does not offer a version
(What ties a version to its build), which no answer overrides. It never runs the history check,
which is the signing check's. A sign whose draft fails either check is not signed, the log says
why, and the next answer that carries the decision checks it again. A relay signature that
completes the signer set publishes the version, as `sign --next` does. Each answer's signatures
are made with the signer's own `gh` login, and every line the job says goes, stamped, to
`~/.digestif/signer/signer.log`.

The job reads its key and its token from the login Keychain, from two items its pinned copy
created itself (`digestif-release-key` and `digestif-signer-token`): an item's access list trusts
the application that added it, so that copy reads both without a prompt, and every other reader,
`security` included, is asked. What the copy signs is bounded by its own code: only a manifest a
decision fetched with the signer token approved, whose files the release workflow attested at the
tag, and whose sha256 matches.

`signer install` sets it up, once, from the `digestif-update` the node holds:

    ~/.local/bin/digestif-update signer install

It copies the running binary, a published release's, to `~/.digestif/signer/digestif-update-<version>`
and refuses any other binary. When the Keychain holds no `digestif-release-key` item it asks for the
key at a hidden prompt; when it holds one, the pinned copy reads it, and the Keychain asks once:
answer Allow, never Always Allow. It asks for the signer token Mike issued on the signer's page
(Enter keeps the one in the Keychain), then runs the pinned copy's `signer adopt`, which writes both
items back as its own, replacing an item whichever program created it, and reads them back silently.
When an item cannot be replaced, the error names the `security delete-generic-password` line that
removes it; `signer install` run after that line asks for the value. It writes
`~/Library/LaunchAgents/io.digestif.signer.plist`, which runs the pinned copy's `signer run` at login
and keeps it alive with the PATH `signer install` ran under, and loads it with `launchctl bootstrap`.
It names every other agent of the signer's whose plist runs `sign --next`, the sign-on-assignment
job the signing job replaces, with the `launchctl bootout` line that stops it.

No automatic update replaces the pinned copy: a new binary is a new code identity, which the
Keychain does not trust. Upgrading the job is running `signer install` again from the newer
`digestif-update`; each signer runs it again once their node runs the first version that reads
`release/` on main, so the job's take-backs reach both of the channel's addresses (The channel
branch, for nodes older than the move). It pins the new copy, moves both items to it with one Keychain prompt, and
deletes the older copies. `digestif-update signer run --once` reads the open decisions once, acts
on them and stops, which shows what the job would do.

### Reading the signatures back

`ci/release.sh signatures --version <version>` is the rollout's read: it downloads the draft's
manifest and its signature assets, checks them with the `verify` of the
`digestif-update-<platform>` the newest published release carries for the machine it runs on (the
draft's own, which nobody has signed yet, only before any version is published), and prints `complete`, `waiting` (the
missing signers on stderr), `gone` when a signer dropped the draft, or `published`. A wrong answer
there can only delay or waste a test run: every node verifies the signatures again with the code it
already runs.

## Test nodes

Before a member can get a version, a throwaway node on every platform in `ci/platforms.json` takes
it the way a member's node does. `ci/release.sh candidate` dispatches main's Release workflow with
the version, which runs one `test node <platform>` job per platform, each limited to thirty minutes
and each running `ci/test-node.sh`:

1. Install the last published version with its own `digestif service install`, so the service manager
   runs its supervisor: the newest version `release/index.json` on main lists, or the `channel`
   branch's while main's list names none, so the first version that reads main is tested making the
   move from the branch every member's node makes. The first version has nothing to update from,
   and neither does a platform newer than the last published version: the version's archive is
   checked against the manifest and installs directly, `candidate` having verified the signatures.
2. Run `digestif update apply --feed <feed>`, so nothing waits on the node's daily read. The feed is
   a directory `ci/release.sh feed --version <version> --dir <feed>` lays out on the runner: the
   channel's take-backs as `channel_read` reads them (main's `release/` with every one the branch
   holds that main lacks), so a node built before a signer-set change follows the chain to the set
   that signed the version, and one release entry naming the prerelease's `manifest.json` and
   `manifest.sig.json`. The pass verifies the signatures, stages, self-tests and switches.
3. Restart the service. The old supervisor runs the version on trial, ten minutes of awake time at most.
4. Restart the service again, so the version's own supervisor runs.
5. Run one more update pass with the version's own code against the feed, which must switch to
   nothing, and a last one against the channel the version reads by default, `release/` on main,
   which must read it and switch to nothing. A later fix or recall depends on those passes and that
   supervisor.

A test node has no circle, no keys and no keystore, so nothing on the runner holds a secret. Its first
pass logs that it cannot sync (`no device key` on macOS, no `secret-tool` on Linux), as a node nobody
has initialized does, and it reports healthy after that pass. So a test node proves a version installs,
starts, serves and updates. It does not prove the version can sync with a circle.

`ci/release.sh test-nodes --version <version>` reads what the newest run says:

- `passed`: every platform's job passed, and `publish` runs.
- `failed`: a node says no: it refused the version or rolled it back, or the version's own supervisor or
  update pass did not work. The job's `the version failed on this node` step fails. No member could
  have received it, so the next version is the fix.
- `silent`: the jobs ended and said nothing about the version: a runner never started on the run's
  last attempt (A job no runner took), a job hit its limit, or a download failed, which fails the job's `this node observed nothing` step instead.
  Running `ci/release.sh candidate` again dispatches again, which is how a job restarts.
- `running`: it has not finished.

Nothing else can run these jobs on a real version, so `ci/test-node-rehearsal.sh` runs the same script
for real, on every platform, against versions built with throwaway keys, including one it must refuse. A pull request touching
what a test node depends on runs it (`.github/workflows/test-node-rehearsal.yml`).

### Reading the channel, and dropping a version

`ci/release.sh channel` is the rollout's last read, the channel as a member's node reads it,
`release/` on main: with no version it prints the newest version `index.json` lists; with
`--version` it prints `listed` only when `index.json` names the version, its manifest and
signatures (read from the version's GitHub release, as a node reads them) verify with the
`digestif-update` of the newest other listed version, and every archive fetches at its manifest's
size and sha256. It exits 75 when the channel or an archive could not be read, which says nothing
about the version.

`ci/release.sh drop --version <version>` deletes the release while it is a draft or a prerelease,
keeping the tag. A rollout runs it for a version
a newer one superseded or a person canceled, and for a version a test node said no to. A published
version is never dropped: only a recall takes one back.

## A recall

A recall is one signer's signed statement that a published version is bad. It names one version and
a reason, and is signed by any one key in the current set; a revocation, which revokes a key, stays
the answer to a stolen key. Nothing asks for a recall automatically: a version reaches members only
after the test nodes passed it, so the bad version a recall is for is one a person has noticed.

    digestif-update recall 0.1.7 --reason "It drops the nightly note."

The key is read from the command `~/.config/digestif/signer.json` names (Where the key comes
from), into the memory of the one process that signs; `"repo"` there names the
repository holding the channel. A password manager with no command line pipes the key in instead,
`pbpaste | digestif-update recall 0.1.7 --reason "..." --key /dev/stdin`. The command writes the
recall through `digestif-update`'s one channel writer, with the signer's own `gh` login (`gh auth
git-credential`), so it needs nothing of the fleet: it clones `release/` of main (shallow and
sparse) and the `channel` branch, writes the recall into each whose list names the version, and
pushes one commit to each, starting again from new clones when a push loses a race (The channel).
It refuses a version neither list names. On a
machine running a node it then writes the same recall to the circle as a `release_recall` message
([protocol.md](protocol.md)) for the node's next sync to carry; elsewhere it prints the one line that
posts it from a machine that runs one. `--channel DIR` writes into a checkout on disk and commits
nothing.

In the channel a recall is `recalls/<version>.json` beside `recalls/<version>.sig.json`, listed in
`index.json`:

```json
"recalls": [
  { "version": "0.1.7", "document": "recalls/0.1.7.json", "signatures": "recalls/0.1.7.sig.json" }
]
```

```json
{ "format": "digestif-recall-v0", "version": "0.1.7", "reason": "It drops the nightly note.", "recalled_at": "2026-11-03T09:00:00.000Z" }
```

Each signature is over `DIGESTIF-RECALL-V0\n<recall bytes>`. The document is written once: the
second signer running `recall` for the same version signs the bytes already there, and their reason
does not replace the first.

**A node derives what is recalled on every pass**, from the channel's recalls and the circle's,
with the signer set it holds (`node/update/lib/policy.ml`, `recall_of`). A recall counts only while
its signer's key is in the set and unrevoked, and nothing about it is stored, so it is undone by
what caused it: a wrongful recall by the next version both sign (the recalled number stays dead,
which costs nothing), a stolen key by the revocation and the signer-set change, after which that
key's recalls stop counting. A recall on the circle starts a pass as soon as a sync brings it, so it
does not wait for the daily read of the channel.

- **A version the node has not installed** is refused while the recall counts, like a version
  missing a signature.
- **The version the node runs**, when the channel has no newer release to take, is left for the
  newest release on the node's disk older than it, not refused and not recalled
  (`node/update/lib/move_back.ml`). The pass self-tests that release against a copy of the store,
  as staging does, since an older release must still read a store a newer one wrote; saves it as
  `installed`; points `current` and `good` at it; and exits, so the service manager starts the older
  release's supervisor. Nothing is fetched, so no signature is involved. A newer release both
  signed is the way forward and is taken instead.
- **The node keeps running the recalled version** and takes the next release when one is published
  when nothing older is on its disk (a fresh install, a node not yet supervised), when the older
  release fails its self-test, or when one signer's recall would take it past the week's limit.
  Stopping instead would hand one key the power to stop every freshly installed node.

**The week's limit.** `update.json` records when the node first installed each version it ran
(`first_installed`), and a move back never resets it. One signer's recall cannot take a node below
the newest release it first installed more than a week ago, so it cannot move a node off a version
it has run that long, and chained recalls cannot walk it down `releases/`: recalling 0.1.7 sends a
node back to 0.1.6 when it installed 0.1.7 within the week, and recalling 0.1.6 next does not take
it to 0.1.5 once 0.1.6 has been on the node for a week. A recall every signer signed has no limit.

The node says what it did in its next digest's Updates section, once:

- "Digestif 0.1.7 was recalled by Roman Cherkasov: <reason>. This node went back to 0.1.6."
- "Digestif 0.1.7 was recalled by Roman Cherkasov: <reason>. This node has nothing to go back to,
  so it keeps running 0.1.7 until the next release.", or the week's limit or the failed self-test
  in place of "has nothing to go back to".
- "Release 0.1.7 was not installed: it was recalled by Roman Cherkasov: <reason>." on a node that
  had not installed it.

`digestif update check` names a recall of the running version.

## Relay releases

The relay ships on a version line of its own, `relay-v<MAJOR.MINOR.PATCH>`, signed by the same
signer set with the same tools, and deployed by each relay's operator's node (DES-45470).

**Tags.** A relay version is a `relay-v<MAJOR.MINOR.PATCH>` tag of a commit of `main`, numbered from
`relay-v0.1.0`. A relay tag never names a node version and a node tag never names a relay version.
Platform creates a rollout for each commit on `main`, and after preflight that rollout's job tags it
and asks `ci/release.sh relay tag --sha <commit>` beside `ci/release.sh changed`: when
`ci/release.sh relay changed` answers `changed` and the order allows it (Order between relay
releases) it tags the next relay patch and pushes it, and a minor or major relay version is a
person's tag. `ci/relay-release-paths`, in `ci/release-paths`'s
format, names what a bundle is built from: `relay/src`, `relay/migrations`, the relay's package
files, the top level of `relay/wrangler.jsonc` (a change inside its `env` object, one deployment's
settings, cuts nothing), every module outside `relay/src` the Worker bundles, the UI sources
`ci/release-paths` names (the phone app the relay serves is the node's UI built for a phone, so a UI
change cuts both lines), and the scripts that build the bundle.

**The build.** Pushing a relay tag starts `.github/workflows/relay-release.yml`, which refuses a tag
that is not `relay-v<MAJOR.MINOR.PATCH>` on `main` or whose release is published, then, with a
read-only token while every dependency's install scripts run:

1. refuses a migration that is not additive (`ci/relay-migrations.sh`: a `DROP` or `RENAME` in a
   migration the previous relay version did not carry, or a change to one it did), since a
   rollback replaces the Worker and never the schema, and a release out of order (`ci/release.sh
   relay order`, Order between relay releases);
2. builds the UI and runs the relay's checks and tests;
3. packs the bundle with `ci/relay-bundle.sh`, which bundles the Worker with
   `wrangler deploy --dry-run --outdir`, defining `RELAY_VERSION_STAMP` as the version so the
   module reports it as `relay_version` (relay/README.md, Configuration), and refuses a module
   whose source map names a file `ci/relay-release-paths` does not cover;
4. runs the conformance suite's relay cases against the packed module, app and migrations
   (`node scripts/conformance.ts --bundle DIR`), so the bytes the signers sign are the bytes that
   passed;
5. writes `manifest.json` with `digestif-update relay-manifest`, built from the same commit, with
   the notes (the tag's message, or the titles of the commits since the previous relay version
   that touched a relay release path) and `compatible_with` the previous relay version (its own
   version for the first);
6. in a second job, `publish`, that installs nothing and runs no code from the tree, attests the
   bundle and the manifest and leaves a **draft** GitHub release `relay-v<version>` holding them,
   created and edited with `--latest=false`. No relay release is ever Latest (The channel). Running it again on the same tag
   replaces the draft's files and drops any signature beside them.

**The bundle**, `digestif-relay-<version>.tar.gz`: `worker/index.js` and `worker/index.js.map`
(the map's sources repository-relative), `app/` (the phone app), `migrations/*.sql` (every D1
migration from `0001_init.sql` on) and `bundle.json` (`relay/scripts/bundle-json.ts`): the main
module's name, the compatibility date and flags, the assets binding, and the names, never the
values, of the D1 binding and every var and secret a deployment sets, with each Durable Object
binding and the class it names and every Durable Object migration step with its tag (the top level
of `relay/wrangler.jsonc`, which every environment repeats). It carries no per-deployment
value, so one bundle deploys to every relay unchanged. `ci/build.slow.sh` packs a rehearsal bundle and
runs the suite against it on every change.

**The manifest**, `digestif-relay-release-v1`, is what both signers sign:

```json
{
  "format": "digestif-relay-release-v1",
  "version": "0.3.0",
  "published_at": "2026-11-12T18:00:00.000Z",
  "notes": "What changed, in a sentence or two.",
  "bundle": { "url": "https://.../digestif-relay-0.3.0.tar.gz", "sha256": "sha256:<64 lowercase hex>", "size": 812345 },
  "migrations": [ { "name": "0001_init.sql", "sha256": "sha256:..." } ],
  "compatible_with": "0.2.0"
}
```

`migrations` lists every D1 migration from the first, strictly ascending by name, each named
`NNNN_<lowercase words>.sql`. `compatible_with` is the oldest relay version this one is
wire-compatible with, never newer than `version`. Each signature is Ed25519 over
`DIGESTIF-RELAY-RELEASE-V0\n<manifest bytes>`, so a relay signature is never a node release, a
revocation or a recall (`node/update/lib/release.ml`).

**The tools.** `digestif-update relay-manifest VERSION --bundle FILE --url-base URL
--compatible-with VERSION [--notes TEXT]` prints the manifest for a bundle, reading every migration
out of the bundle itself. `digestif-update sign --key SECRET_FILE MANIFEST` signs a relay manifest
over its own domain line, and `digestif-update verify` checks one exactly as a node release:
`signed NAME`/`missing NAME` per signer, exit 0 only when every key of the set signed and none is
revoked (`Policy.check_relay`). A relay release never changes the signer set.

**The announcement.** A signed relay release reaches nodes as a `relay_release` circle message
([protocol.md](protocol.md), relay_release), which a relay checks only for an admitted author and
its two fields. Every node folds the announcements on every sync against its own signer set
(`node/update/lib/circle_relay_release.ml`), storing nothing but the verdict per version:

- An announcement counts when every key of the current, unrevoked signer set signed it and the
  document parses as `digestif-relay-release-v1`. One that does not is a fault shown to the member.
- While a revoked key is in the signer set, no announcement counts.
- The newest relay release is the counting announcement with the highest version. Order is by
  version alone, never `created_at` or relay order, so a replayed old announcement changes nothing.
- Two counting announcements of one version with different documents are a fault, and neither
  counts. The same document announced twice is one announcement.

The announcement carries no instruction to deploy: only an operator's node acts on it, and every
node judges from it whether a relay is behind. Nodes act on the announcement and never poll the
channel.

### Order between relay releases

A pull request merges the moment it is ready, and an operator's node deploys the newest announced
release, skipping any between. So the order two relay changes reach the relays in is kept where a
relay release is tagged, against what the relays serve (`GET /v0/version` of each relay
`ci/relay-release-order` names), and never by holding a merge. `ci/release.sh relay tag` keeps two
rules, and the release build refuses a tag, whoever pushed it, that breaks one (`ci/release.sh relay
order`):

- **A Durable Object migration step is released alone.** A release carrying a step of
  `relay/wrangler.jsonc`'s `migrations` some relay has not applied holds one commit past what that
  relay serves, the one that adds the step, and that commit changes no D1 migration, no shared module
  and no phone app. What landed before it is released and deployed first, and nothing after it is
  tagged until every relay serves it, so the version a rollback goes back to differs by the class
  alone. That the commit routes nothing to the class is its review's to see.
- **A commit another needs is live first.** A relay change that depends on an earlier one being live
  (dropping an address once every caller has the new one) adds, in its own pull request, the line
  `needs <full commit id> <why>` to `ci/relay-release-order`. No release holding that line is tagged
  until every relay serves one holding that commit.

A held commit exits `relay tag` 3 with the reason, after tagging the newest commit before it that the
order allows, so earlier work still ships; the relay job asks again until the rest may go. A hold ends
when the relays serve what it names, or when the held change is reverted on main. A relay that does
not answer holds too. The file's `served` line names a release every relay is known to serve,
and a commit that waits on nothing past it asks no relay. A build refused because a person pushed the
tag early is run again on the same tag once the relays have caught up.

A condition the relays' version does not say (no unprefixed request for 14 days) is not this order's:
the issue that removes something waits on the issue that reads the condition (`dev issues block`)
and its pull request is opened once that issue ends, since a pull request that is ready is merged.

### Signing a relay release

The same signers sign a relay version with the same command: `digestif-update sign --next` asks
about the node versions and the relay versions waiting (draft releases tagged `relay-v<version>`,
newer than the newest published relay version) in the same run and under the same one answer,
offering of the relay line the newest and those one more signature completes, as for the node
line. When the run's signatures complete a relay version, the newest such is published and every
older relay draft, offered or skipped, which can then never publish, is dropped. A relay tag
is never a node version and a node tag never a relay version. For a relay version it prints,
before it asks:

- the version, the commit its tag names, and the Relay release workflow run that attests its
  files (What ties a version to its build);
- every commit title since the last published relay version (every commit the tag holds, for the
  first) that touched a relay release path, and the compare link: `git log` in the tool's clone,
  limited to the pathspecs `ci/relay-release-paths` holds at the tag. A tag without that file shows
  every commit and says so;
- the notes as signed;
- **the full text of every migration the version adds or changes** over the last published relay
  version (a name it lacked, or the same name with another sha256, flagged CHANGED), read from the
  tag and checked against the manifest's sha256, since a migration is the one part of a relay
  release a rollback does not undo, and every migration that version listed and this one does not,
  flagged REMOVED;
- the bundle's sha256, checked against the digest GitHub holds for the draft's file, and, when the
  version cannot be signed, every reason why (a migration that differs from the tag's file is one);
- `compatible_with`, and every relay's `relay_version` as this machine's node last read it (what
  each sync records in its `relay_versions` table, A relay left behind is named; no relay is asked
  during the run), a relay older than `compatible_with` marked (no node here: it says so);
- who has already signed.

`s` signs the manifest's exact bytes over `DIGESTIF-RELAY-RELEASE-V0` and uploads
`manifest.<key>.sig.json` to the draft, exactly as for a node version; `d` drops the draft;
anything else leaves it waiting. When the signature it uploaded completes the signer set, `sign --next`
publishes the version itself (below) and prints each step. A version signed by every signer that
did not publish is said with the line to run.

### Publishing a relay release

`ci/release.sh relay-publish --version <version>` publishes a relay version every signer signed.
Anyone with write access may run it, and running it again finishes what an earlier run left. It
runs `digestif-update relay-publish <version>` from the `digestif-update` the newest listed node
version no recall takes out holds for the machine (`DIGESTIF_UPDATE` names another), so the version under review never vouches
for itself; `sign --next` runs the same steps in its own process
(`node/update/lib/relay_publish.ml`). Three steps:

1. Download the draft's manifest and every signature and check them as a node does
   (`Policy.check_relay`), against the set `sign --next` signs under: the build's set advanced by
   the channel's `signers/` and this machine's node, with every revocation the channel lists
   applied. Per signer, the signature kept is the one that verifies. A signer missing exits 75
   having published nothing; a revoked key in the set fails it. The releases listing and the
   channel's trust are read at once, then the manifest and every signature downloaded at once;
   `sign --next` hands over the manifest bytes it already downloaded, used while GitHub's digest of
   the draft's `manifest.json` is still theirs.
2. Upload the signatures kept, one per signer, to the release as its combined `manifest.sig.json`,
   beside the per-signer files, and publish the GitHub release, never as Latest, with the signer's
   own `gh` login. The release is the relay version's one record: the break-glass deploy reads its
   `manifest.json` and `manifest.sig.json` from there, and nothing is written to the channel.
3. Write the `relay_release` announcement through this machine's node for its next sync to carry,
   as a recall posts a `release_recall`; with no node here it prints the
   `digestif post --kind relay_release` line that posts it from a machine running one. An
   announcement the node's log already holds is not written again.

Publishing runs on a signer's machine and never in CI or the fleet: the announcement needs a device
key.

**A relay that does not know `relay_release` yet.** A relay deployed before relay releases answers
the announcement's append `422 malformed`, which a node's sync reads as a refusal for good: it would
drop the announcement, or, once another relay holds it, push it again on every sync. Such a relay
reports no `relay_version` on `GET /v0/circle`. So step 3 writes the announcement only when every
relay this node syncs with reports a `relay_version`; otherwise it writes nothing and says so in one
line naming the relay, why, and to run `ci/release.sh relay-publish --version <version>` again once
it runs the release, and `relay-publish` exits 75. A relay that could not be read holds it the same
way. The first relay release meets this on both relays: each operator deploys `relay-v0.1.0` by
hand, then `relay-publish` is run again and the announcement goes out (DES-45470, "Moving the two
existing relays", step 6). Nothing retries it on its own.

**Who operates a relay.** A node operates a relay when both hold: the relay's newest `relay`
message was written by a device of this node's identity (the fold keeps it per url,
`Fold.relay_operator`), which every node reads the same way; and this node holds a deploy token and
a deployment record for that url, which only the operator could have put there
(`node/relay_deploy/operate.ml`). A node holds the token of one relay at most. A node holding a
token for a relay the circle does not name as its own deploys nothing, and its next digest says so
once. An operator who has not set up deploys is reached by the lag lines.

**`digestif relay operate <url>`** sets it up, once, on the operator's own node, and `digestif
circle found --relay <url>` does the same for a person founding their first circle on a relay with
no home: the same checks, then the new root written into the Worker's `HOME_ROOT` through
Cloudflare's settings API (every other binding inherited), and the token and record stored in the
new circle's folder once the relay took the root. It asks for the
Cloudflare account id, the Worker's name and the D1 database's id (or takes them from
`--account-id`, `--worker` and `--database-id`), and reads the deploy token at a hidden prompt into
memory. Before it stores anything it:

- verifies the token with Cloudflare's `GET /user/tokens/verify` (an account-owned token, at
  `GET /accounts/<id>/tokens/verify`), lists the account's Workers and refuses a token that cannot
  see the named Worker or can see a second one, and reads the database;
- reads the Worker version serving now, the first rollback target;
- reads the relay's `relay_version` with the version read (below), so the record starts from what
  is running.

It then stores the token in the keystore as `relay-deploy-token` (service `digestif`, account
`relay-deploy-token@<data dir>`) and the rest in `relay-deploy.json` in the data directory: url,
account id, Worker name, database id, rollback version id, the reported relay version, a pending
step, refused versions. When the relay's newest `relay` message is not this node's, it writes it
again with the same body, which makes this node its operator from the next sync. Running it again
for the same relay replaces the token; naming another relay is refused until
`digestif relay operate --remove <url>` deletes the token and the record. The token is a Cloudflare
custom API token on the relay's own account, with `Workers Scripts: Edit` and `D1: Edit`, and
reaches `curl` only in a config file on stdin (`curl -K -`), never on an argv. The account needs a
`workers.dev` subdomain, whatever address the relay serves at: Cloudflare refuses the upload of a
release that carries a Durable Object migration without one. Opening Workers and Pages once in the
account's dashboard creates it; the token checks do not read it.

**`digestif relay status`** prints the newest relay release, the record, who the circle reads as
the operator, the deployed version, a pending step and its retry time, and refused versions, never
the token.

**The version read.** Every read the operator's node makes of which release a relay runs (`digestif
relay operate`, the check for a relay already deployed by hand, the rollback's check and clearing a
lead line) is the unsigned `GET /v0/version` at the relay's base url (protocol.md, Relay version;
`Relay_client.version`). A **supported** relay is one on any relay release from `relay-v0.1.1`,
the first to answer it: the route is unprefixed, asks no key, and answers alike on a relay that
hosts many circles (0.1.76 and later) and on one that does not, which answers `404` to
`GET /v0/relay` and at `<url>/c/<root hex>`. A Worker older than `relay-v0.1.1` answers `404`
there too and is read as reporting no version, as is an unstamped Worker. Only the new release's
health check (step 5) reads the home circle, signed.

**The deploy step** is a pass of `digestif run`, after each sync (`node/relay_deploy/deploy.ml`).
It is due when this node operates a relay, the newest relay release is newer than the version the
relay reports and not refused on it, Cloudflare has not refused the token, and no node switch is on
trial. A relay already reporting that release or a newer one (deployed by hand) is recorded and
nothing is deployed. Otherwise:

1. **Verify.** Download the bundle, check its size and sha256 against the manifest, unpack it, and
   check that its `migrations/` are the manifest's, name for name and byte for byte.
2. **Migrations.** Through the D1 query API, make `d1_migrations` as `wrangler d1 migrations apply`
   makes it, read which migrations it holds, and apply each the manifest lists and the table lacks,
   in order, each with its row in one request.
3. **Upload.** The bundle's `app/` through an assets upload session (each file keyed by 32 hex
   characters of the sha256 over its base64 and its extension), then `worker/<main_module>` and its
   source map as a new Worker version carrying `keep_bindings` for every binding kind, the `ASSETS`
   binding with the session's completion token and the assets config `bundle.json` names
   (`html_handling` `none` and `run_worker_first` when it names none), tagged `relay-v<version>` and
   annotated with the bundle's sha256. A version already carrying both is reused. Every Durable
   Object binding `bundle.json` names is in the upload.
4. **Deploy.** Record the Worker version serving now in `relay-deploy.json` as the rollback target,
   then deploy the new version at 100%. A pass finding it serving already deploys nothing.

   **A Durable Object migration** takes steps 3 and 4 as one, since a version upload cannot apply
   one. When `bundle.json` lists migration steps, the pass reads the tag the Worker has applied (the
   `migration_tag` Cloudflare's Worker list reports), and when it is not the newest step's tag,
   records the version serving now as the rollback target, then uploads the module as the Worker
   script itself (the call `wrangler deploy` makes), carrying the steps after the applied tag (every
   step when none is applied) with `old_tag` and `new_tag`; that upload serves at once. A Worker on a
   tag the bundle does not list refuses the release for good. A rollback cannot cross a migration,
   so a release that carries one changes nothing else, which `ci/release.sh relay tag` and the
   release build hold it to (Order between relay releases; relay/README.md, Each circle's store).
5. **Health check.** A signed `GET /v0/circle` at the home circle's address, `<url>/c/<root hex>`,
   answering 200 with the release's `relay_version` and the circle's `root`, and `GET /app/` on the
   relay's base url answering 200, within two minutes of awake time counted in
   one-second steps as a trial is.
6. **Kept, or rolled back.** A pass records the version, and the next digest says "Deployed relay
   0.3.0 to dinners.digestif.io." A failure deploys the rollback target at 100%, checks that the
   relay answers the version it reported before on the version read and `GET /app/` answers 200,
   within the same two minutes, refuses the release on this relay for good, and
   the next digest says what the relay answered and that the node rolled it back. A rollback that
   fails too is a line leading the digest's "On your machine" section, with the `wrangler rollback`
   to run, on every digest until the relay answers a version the node knows.

`bundle.json` is read for `main_module` (default `index.js`), `compatibility_date` (required),
`compatibility_flags`, an optional `assets` object (`binding`, `html_handling`,
`run_worker_first`), optional `durable_objects` (`name`, `class_name`) and optional `migrations`
(each step a `tag` and what it does). A binding without its class, a step without a tag or a tag
listed twice refuses the bundle for good.

A step failing before the deploy changes nothing the relay serves. A download, a bundle whose bytes
do not match, or Cloudflare not answering or answering 5xx is kept as pending in
`relay-deploy.json` with its step and cause, and tried again on the update pass's backoff (ten
minutes, doubling, at most a day).

What Cloudflare refuses is read from its error code, never from the HTTP status alone:

| Cloudflare answers | The node |
|---|---|
| a 401 or 403 whose code says the token is wrong, expired or lacks a permission (1000, 9109, 10000, 10001) | puts a digest line naming `digestif relay operate`, once, and tries nothing until that command stores a new token |
| code 10063, the account has no `workers.dev` subdomain | keeps the step pending and retries it on the backoff; a digest line, once per release, names the account id and says to open Workers and Pages in it |
| a 401 or 403 of any other code, or refusing an asset upload (which carries its session's token, not the deploy token) | keeps the step pending and retries it on the backoff; a digest line, once per release, carries Cloudflare's message |

A migration D1 refuses is refused
for good, and so is a bundle whose sha256 matches but that cannot be deployed as it stands (it does
not unpack, its migrations are not the manifest's, it has no `bundle.json`, module or `app/`): a
later pass would meet the same bytes. Each digest line goes out once; `digestif relay status` shows
the pending step, its retry time and every refused version.

**Break glass.** `relay/scripts/deploy.sh --release <version>` deploys a signed relay release by
hand, logged in to the relay's own account: it checks the channel's manifest and signatures with
`digestif-update verify`, and the bundle's sha256, size and migrations against the manifest, before
it deploys those bytes (relay/README.md, "Operations"). It is how the first relay release reaches a
relay that cannot accept its announcement yet, and how GOVERNANCE.md's backup holder deploys: always
signed code, never a build.

### A relay left behind is named

Every sync, a node asks each relay it read cleanly for `GET /v0/circle` and records the
`relay_version` it answers beside the relay's url (`node/relay_deploy/lag.ml`); a relay built
before relay releases answers none, and a relay the sync could not read keeps what it last
reported. A relay is **behind** when it reports a version older than the newest relay release, or
none, and has for at least the threshold since that release's announcement first reached the node:

| Behind for | Whose digest names it |
|---|---|
| 2 days | The relay's operator's: "Your relay dinners.digestif.io is behind: it runs 0.2.0 and the newest relay release is 0.3.0, announced 2 days ago. Run digestif relay status on your machine to see why." |
| 7 days | Each release signer's, naming the operator by their card: "The relay dinners.digestif.io, operated by Mike, is behind: ..." |

The operator is the member whose device authored the relay's newest `relay` message
(`Fold.relay_operator`). A release
signer's node is the one on the machine holding the signer's `signer.json` (Where the key comes
from), since the circle ties no release key to a member; a signer's own relay is named by their
operator line, not this one. Each line is told once per release per relay, and again only when a
newer release leaves the relay behind again. A relay reporting a version newer than every counting
announcement, or one that is not a version, is a `relay_version` fault shown to the member while
it does.


## A version that keeps crashing

A version that reported healthy can still crash later, and past its trial the supervisor would
only pass each exit on to the service manager, which restarts it. So the supervisor counts the
child's exits outside a trial in `update-crashes.json` beside `update.json`
(`node/update/lib/crashes.ml`), on disk because a child's exit ends the supervisor and the count has
to reach the next one the service manager starts:

- The count belongs to the release `current` names. Each exit is stamped with the awake time that
  release's child has run in total, summed across supervisors and counted in the same one-second
  steps as a trial, so a laptop closed between two exits does not bring them closer together.
- Three exits within ten minutes of that awake time move the node back the way a recall does
  (`node/update/lib/move_back.ml`): the newest older release on its disk, not refused, self-tested
  against a copy of the store, saved as `installed`, with `current` and `good` pointed at it. The
  version is refused, so no later pass installs it again, and the supervisor exits so that the
  service manager starts the older release's supervisor. Nothing is fetched, so no signature is
  involved, and there is no week's limit: the node is acting on what it saw itself.
- Only an abnormal exit counts: a nonzero status other than 75, or a signal other than a stop
  (`SIGTERM`, `SIGINT`, `SIGHUP`). `digestif run` exits 75 when this machine, not the release,
  stopped it (its UI port held by another process), and exits 0 when it is stopped; either adds its
  awake time and no exit. An exception in a pass never ends the process: it is reported as a
  problem of job `pass`, the next pass tries again, and the pass that completes closes it.
- An exit after which `current` names another release is the child's own move back (a recall) and
  is not counted, and neither is the child stopping because the service manager stopped the
  supervisor. An exit during a trial is the trial's to judge.
- The node moves back for crashing once. The release it went back to carries the version it came
  from in its count (`moved_back_from`), and when that release keeps crashing too the cause is the
  machine, not a release: it stays, unrefused, and the service manager keeps restarting it, rather
  than walking down every release on disk and refusing each newer one.
- With nothing older on its disk, or an older release that fails its self-test, the node keeps the
  version and the service manager keeps restarting it; the version is not refused, and the count
  starts over.

The digest says what happened, once:

- "Digestif 0.1.7 kept crashing, so this node went back to 0.1.6."
- "Digestif 0.1.7 kept crashing, and this node has nothing older to go back to, so it keeps
  restarting until the next release.", or the failed self-test in place of "has nothing older to go
  back to", or, for the release it already went back to, "it is the release this node went back to
  from 0.1.7 for crashing, which makes this machine the likely cause". It reaches the person only if the node stays up long enough to send a digest.
