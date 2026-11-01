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
`behaviors/` with its `bin/`, `src/`, `prompts/`, `launchd/` and `package.json`. It also carries
`bin/digestif-update`, the signer's tool, so a signer signs the next version with a tool from a
version both signers already signed (Signing a release). Code the node runs moves together, so a
release never updates the binary and leaves the nightly prompt or the digest reader behind. A node
built before `digestif-release-v1` refuses these manifests as unreadable and is upgraded once by
hand (`./install.sh`).

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
4. Each signer runs `digestif-update sign --next`, which shows what the version holds, asks, and
   uploads their signature to the draft (Signing a release).
5. Once both signatures are in `releases/<version>/manifest.sig.json`, publish the GitHub release
   (`gh release edit v<version> --draft=false`) so its archives can be fetched, then add the
   manifest, its signatures and the entry in `releases/index.json` in one pull request and merge.

The same workflow runs as a dry run on every push to `main`, every pull request, and by hand: it
builds and stages every platform at the version the commit is and uploads nothing, so a change that breaks one
platform shows within minutes rather than on release day. It is the only automated build of macOS;
`ci/build.sh` builds Linux on the fleet's builders.

A signer's key is made once with `digestif-update keygen <secret file>`, which prints the public
half and writes the secret with mode 0600. Put the secret in your password manager and delete the
file; signing from a machine that runs a node is fine, since `sign --next` writes nothing of the key
to its disk.

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

A signer signs with one command, the same every time: `digestif-update sign --next`. It takes the
version waiting for signatures, so a command copied from last week's request is still the right
one.

Run a `digestif-update` you already hold, never one built by the version you are judging: the
`bin/digestif-update` in the last published archive (a node's `<data dir>/good/bin/digestif-update`
once it has updated), or one built from your own checkout. It talks to GitHub with your own `gh`
login, which needs write access to the repository, since a draft release is readable by nobody else.

### Setting up once

`sign --next` reads the key from a command you name once in `~/.config/digestif/signer.json`
(`$XDG_CONFIG_HOME/digestif/signer.json` when that is set). The command prints the secret
`digestif-update keygen` made, and nothing of it is ever written to disk: it goes from the
command's output into the memory of the one process that signs.

```json
{ "key_command": "op read 'op://Private/Digestif release key/password'" }
```

A key kept in 1Password as a document is `op document get 'digestif-release.key'`. The command
runs under `/bin/sh -c`, so any password manager with a command line works. `"repo"` names another
repository than `digestif-ai/digestif`. With no `signer.json`, `sign --next` says what to write and
signs nothing.

A password manager with no command line signs the downloaded manifest by hand instead:
`gh release download v<version> --repo digestif-ai/digestif --pattern manifest.json`, then
`pbpaste | digestif-update sign --key /dev/stdin manifest.json`, and upload the
`manifest.sig.json` it writes as `manifest.<your key, without ed25519:>.sig.json` with
`gh release upload v<version> <file> --repo digestif-ai/digestif`. A key file that cannot be read
ends `sign` with one line naming it.

### What it shows, and the question

The waiting version is the newest draft release a signer has already signed, since a signed
version waits for the other signer however many versions are cut after it, else the newest
draft. Before it reads the key, `sign --next` prints:

- the version, the commit its tag names, and the Release workflow run that built it;
- every commit title since the last published version, and the compare link;
- the manifest's notes as signed, and every archive's sha256, each checked against the digest
  GitHub holds for the draft's file;
- the new signer set, when the version replaces it, and who has already signed.

Then it asks. `s` signs: it runs the key command, refuses a key that is not a release signer, signs
the manifest's exact bytes, and uploads the signature as the draft's asset
`manifest.<key>.sig.json` (the key's base64url without `ed25519:`), holding the one signature in
the channel's signatures format, so the two signers never write the same file. `d` drops the
version: it deletes the draft release with every signature on it, and the tag stays. Anything else
leaves it waiting and reads no key. No flag skips the question.

### Reading the signatures back

`ci/release.sh signatures --version <version>` is the rollout's read: it downloads the draft's
manifest, its signature assets and the `digestif-update-<platform>` the draft carries for the
machine it runs on, checks them with that tool's `verify`, and prints `complete`, `waiting` (the
missing signers on stderr), `gone` when a signer dropped the draft, or `published`. A wrong answer
there can only delay or waste a test run: every node verifies the signatures again with the code it
already runs.

## Test nodes

## A recall

## A version that keeps crashing
