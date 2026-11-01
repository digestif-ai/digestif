# Releases and self-update

How a node decides what code to run. The rules are in `node/update/lib/policy.ml`, a node's own
commands are `digestif update check|apply|pin|unpin`, a signer's tool is `digestif-update`, and who
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
never shrunk this way, and only a signed release replaces a set the build's does not contain.

- **Newer only.** A node considers releases newer than the one it last ran healthy, never older,
  so a channel replaying an old release cannot roll a node back. Moving back to the last healthy
  release on the node's own disk after a failed switch (below) is not a downgrade: nothing is
  fetched for it.
- **Refused for good.** A release whose self-test failed, or that was rolled back after a switch,
  is recorded in `update.json` and never chosen again; a newer release is.
- **Pinning.** `digestif update pin 0.4.1` makes the node install exactly that version and nothing
  newer; `unpin` follows the newest release again. A pin never waives a signature. A pin at or below
  the installed version installs nothing; going back is a manual reinstall.
- **Withholding halts.** Either signer stops every update by not signing. A channel that withholds
  a release has the same effect and no other, because everything in it is verified.

## Changing the signer set

A release replaces the set when its manifest carries a `signers` list. It is accepted only when:

1. every key in the current set signed it,
2. every key in the new set signed it, which proves each new key is held by someone,
3. the new set has at least two keys, no key twice, and no revoked key.

The node adopts the new set as it reads the channel, in version order, even past a pin: adopting a
set installs no code, and a pinned node must still verify the release it is later unpinned onto.

## Revoking a release key

A revocation names one key and is signed by any key in the current set. From then on:

- no ordinary release installs while a revoked key is in the set: updates halt;
- the only release that installs is a signer-set change, signed by every current key (a leaked key
  is still held by its owner) and by every new key, naming a set without the revoked key;
- a revoked key never enters a signer set again.

The revocation reaches nodes two ways: in the channel, and on the circle as a `release_revocation`
message carrying the same document and signatures ([protocol.md](protocol.md)), so a node whose
channel is unreachable or withholds it still halts. `digestif-update circle-body <revocation>` prints
that message's body from the published document and its `.sig.json`. Either way the node checks the
signatures against its own signer set and records the revoked key in its update state.

A revocation grants nobody anything: whoever holds a leaked key can at worst halt updates, which
withholding a signature already does. A key that is lost rather than leaked cannot sign the change,
so recovery from it is a fresh install of a build carrying the new set, announced in the repo.

## The channel

The channel is a directory served over https, by default the `releases/` directory of this repo
(`https://raw.githubusercontent.com/digestif-ai/digestif/main/releases/`). Artifacts are attached to the
matching GitHub release; a relative `url` is resolved against the channel.

```
releases/
  index.json
  0.2.0/manifest.json
  0.2.0/manifest.sig.json
  revocations/<name>.json
  revocations/<name>.sig.json
```

`index.json` is unsigned and lists where things are. Its `version` is only a hint to skip fetching
old manifests; the version that counts is the manifest's own.

```json
{
  "format": "digestif-feed-v0",
  "releases": [
    { "version": "0.2.0", "manifest": "0.2.0/manifest.json", "signatures": "0.2.0/manifest.sig.json" }
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
  ],
  "signers": [ { "name": "Mike Bryzek", "key": "ed25519:..." }, { "name": "Roman Cherkasov", "key": "ed25519:..." } ]
}
```

`signers` is present only on a release that replaces the set. Platforms are `darwin-arm64`,
`darwin-x86_64`, `linux-x86_64` and `linux-arm64`.

An artifact is a release archive, a gzipped tar of everything the node runs: `bin/digestif`, and
`behaviors/` with its `bin/`, `src/`, `prompts/`, `launchd/` and `package.json`. Code the node runs
moves together, so a release never updates the binary and leaves the nightly prompt or the digest
reader behind. A node built before `digestif-release-v1` refuses these manifests as unreadable and
is upgraded once by hand (`./install.sh`).

A revocation:

```json
{ "format": "digestif-revocation-v0", "key": "ed25519:...", "reason": "Laptop stolen.", "revoked_at": "2026-11-03T09:00:00.000Z" }
```

Signatures sit beside each document:

```json
{ "signatures": [ { "key": "ed25519:...", "signature": "<base64url, no padding>" } ] }
```

Each signature is Ed25519 over a domain line plus the document's exact bytes as published:
`DIGESTIF-RELEASE-V0\n<manifest bytes>` or `DIGESTIF-REVOCATION-V0\n<revocation bytes>`. There is no
canonical encoding to agree on; reformatting a manifest after signing breaks every signature, and
the domain line keeps a release signature from being replayed as a revocation.

## When a node updates

`digestif run` reads the channel once a day, when the machine wakes (at most hourly on wakes), and
when a failed stage's backoff has passed, as one pass of `node/update/lib/updater.ml`.
`node/update/lib/schedule.ml` decides when a pass is due, and no pass runs while a switch is on
trial. The update state is `update.json` in the node's data directory, and what passes and the
supervisor found for the person is `update-report.json` beside it:

- a release that became healthy, a release rolled back and why, a release refused and why (a
  signature missing, updates halted by a revocation, no artifact for this platform, a self-test that
  failed), a stage that failed and when it is tried again, an unreadable channel entry, and a pass
  that failed outright are each a line for the next digest's Updates section;
- a line is reported once: a refusal that holds pass after pass is in one digest, and one that clears
  and comes back is reported again.

`digestif update check` prints the same state (installed, current, good, a trial, a pending stage,
refused versions) and the lines the next digest will carry. `digestif run --no-self-update` never
reads the channel; `digestif update apply` runs a pass at once.

## Releases on disk

Each release is a directory under `<data dir>/releases/` that nothing changes once it is there: the
archive's `bin/` and `behaviors/`, and `.release.json`, written last, naming its version. Two
symlinks choose among them (`node/update/lib/layout.ml`):

- `current`: the release the service runs;
- `good`: the last release that reported healthy.

Older releases stay on disk. The nightly hook resolves through `current`: the node runs a hook path
ending in `behaviors/<file>`, such as a checkout's `behaviors/bin/nightly-hook`, from
`current/behaviors/<file>` when the current release has that file, so a member's existing absolute
hook path keeps working and follows every release. `digestif behavior set nightly
<data dir>/current/behaviors/bin/nightly-hook` names it directly.

## Staging

A pass that chooses a release stages it before anything the node runs changes
(`node/update/lib/stage.ml`):

1. download the archive and check its size and sha256 against the manifest both signers signed;
2. unpack it into `releases/.staging-<version>` and check it holds `bin/digestif`;
3. check the runtime the behaviors need: the `node` on the service's PATH must be at least the major
   version `behaviors/package.json` names in `engines`, and the line names Node.js when it is not;
4. self-test: run the staged binary as `digestif self-test --data-dir <copy> --expect-version
   <version>` against a copy of the node's data (the store copied with SQLite's `VACUUM INTO`, no
   keys), bounded at two minutes. It must report the version, open the store and read its config;
5. write `.release.json` and rename the directory to `releases/<version>`.

A failure leaves `current` alone. A download, a write or a missing Node.js is kept in `update.json`
as pending with its cause, and tried again after a backoff (ten minutes, doubling, at most a day).
A self-test that fails or hangs, or an archive without the binary, refuses that version for good.

## Switching

A node runs under a supervisor once `digestif service install` has set up `releases/`, `current`
and `good`: the launchd agent or systemd unit runs `good/bin/digestif supervise`, the binary of the
last healthy release, and the supervisor runs `current/bin/digestif run` as its child
(`node/update/lib/supervisor.ml`). On a node not yet supervised a pass stages the release and the
digest says to run its `service install` once.

To switch, the pass records a trial in `update-trial.json` (the new release, and the one `good`
names to move back to), points `current` at the new release, and exits. The supervisor starts the
new release and watches it:

- `digestif run` writes `health.json` (its version and pid) once its first pass has opened the
  store, synced and started the web UI. The new release is then kept: `good` moves to it,
  `installed` in `update.json` is saved, and the digest says "Updated Digestif to <version>."
  `installed` is never saved before this.
- If the child exits before it reports healthy, or has not reported healthy after ten minutes of
  awake time, the supervisor stops it, points `current` back at the release `good` names, refuses
  the version for good, says so in the digest, and runs the previous release again.
- Awake time is counted in one-second steps: a step that took far longer than a second spanned the
  machine sleeping and counts as one second, so a laptop closed during the window does not use it
  up.
- A trial that three supervisor starts did not finish (the machine restarting mid-trial) is rolled
  back the same way.

The recovery runs in the supervisor and not in `digestif run`, because a release that crashes on
start cannot run code to fix itself, and the supervisor is always a release that was healthy. A new
supervisor takes over the next time the service manager starts it.

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
its tag does not.

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
   `ci/release-linux.sh`'s Alpine container), then stages each archive on a fresh machine with
   `ci/release-check.sh`, which runs `digestif-update stage-test`: the checks a node runs on a
   release it stages (below).
3. Only when every platform passed does it leave a **draft** GitHub release `v<version>` holding
   every archive, every platform's `digestif-update` as `digestif-update-<platform>`, and
   `manifest.json`, written by `digestif-update manifest --platforms ci/platforms.json`, which
   refuses a manifest missing any platform in that file. The manifest's notes are the commit titles
   since the last published release, or the tag's own message when a person wrote an annotated
   tag. A draft is readable only by people with write access until it is published. One failed
   platform leaves no draft and no manifest, so nothing partial can be signed. Nobody edits the
   manifest after; running the workflow again on the same tag replaces the draft's files and drops
   any signature beside them. `ci/release.sh build` succeeds once the draft holds all of it.
4. Each signer downloads the manifest and signs it. The secret stays in the signer's password
   manager and is on disk only for the one command:

       gh release download v<version> --repo digestif-ai/digestif --pattern manifest.json --dir releases/<version>
       pbpaste | digestif-update sign --key /dev/stdin releases/<version>/manifest.json

   A secret kept as a document (1Password saves a Download to `~/Downloads`) is signed with and
   deleted in the same command:

       digestif-update sign --key ~/Downloads/digestif-release.key releases/<version>/manifest.json; rm ~/Downloads/digestif-release.key

   A key file that cannot be read ends `sign` with one line naming it.
5. Once both signatures are in `releases/<version>/manifest.sig.json`, publish the GitHub release
   (`gh release edit v<version> --draft=false`) so its archives can be fetched, then add the
   manifest, its signatures and the entry in `releases/index.json` in one pull request and merge.

The same workflow runs as a dry run on every push to `main`, every pull request, and by hand: it
builds and stages every platform at the version the commit is and uploads nothing, so a change that breaks one
platform shows within minutes rather than on release day. It is the only automated build of macOS;
`ci/build.sh` builds Linux on the fleet's builders.

A signer's key is made once with `digestif-update keygen <secret file>`, which prints the public
half and writes the secret with mode 0600. Keep the secret off any machine that runs a node.

### What a node needs on Linux

The Linux binaries are linked statically against musl (the `static` profile in `node/dune`), so they
need no libc, SQLite or other shared library from the member's distribution, and run on any
x86_64 or arm64 Linux. `ci/release-artifact.sh` prints what each binary links (`ldd` on Linux,
`otool -L` on macOS) and refuses a Linux binary that is dynamic or a macOS binary that links
anything outside `/usr/lib` and `/System`. The node runs these programs from `PATH`:

- `node`, Node.js 24 or later, for the behaviors; a release does not stage without it;
- `curl`, to reach relays and the release channel;
- `tar`, to unpack a release;
- `secret-tool` (libsecret-tools) and a running Secret Service, for the keystore;
- `systemctl`, for the service.

`./install.sh --service` on Linux installs a systemd user unit, `~/.config/systemd/user/digestif.service`,
that runs `good/bin/digestif supervise`, and enables and starts it with `systemctl --user enable
--now`; on macOS it installs the launchd agent. A user unit runs while its user is logged in;
`loginctl enable-linger $USER` keeps it running without a session.

## Signing a release

## Test nodes

## A recall

A recall is one signer's signed statement that a published version is bad. It names one version and
a reason, and is signed by any one key in the current set; a revocation, which revokes a key, stays
the answer to a stolen key. Nothing asks for a recall automatically: a version reaches members only
after the test nodes passed it, so the bad version a recall is for is one a person has noticed.

    digestif-update recall 0.1.7 --reason "It drops the nightly note." --key /dev/stdin

The key is read as `sign` reads it. The command clones the channel's `channel` branch with the
signer's own `gh` login (`gh auth git-credential`), writes the recall, commits and pushes it in one
commit, so it needs nothing of the fleet. It refuses a version the channel does not publish. On a
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

## A version that keeps crashing
