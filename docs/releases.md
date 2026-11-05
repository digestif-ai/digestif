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

The channel is a directory served over https, by default the root of this repo's `channel` branch
(`https://raw.githubusercontent.com/digestif-ai/digestif/channel/`); `digestif run --feed` names
another, and a local directory works too. Artifacts are attached to the matching GitHub release; a
relative `url` is resolved against the channel.

```
index.json
0.2.0/manifest.json
0.2.0/manifest.sig.json
revocations/<name>.json
revocations/<name>.sig.json
candidate/index.json
candidate/0.3.0/manifest.json
candidate/0.3.0/manifest.sig.json
relay/index.json
relay/0.3.0/manifest.json
relay/0.3.0/manifest.sig.json
```

`channel` holds no code and shares no history with `main`: main holds code only, so publishing a
version is never a commit the tagging job would tag as the next one, and a push to `channel` runs
no workflow, since GitHub reads a push's workflows from the pushed commit. What members' nodes read,
`index.json` and the documents it names, is written only by `ci/release.sh publish` and by a
recall. `relay/` is the relay line's record (Relay releases, Publishing a relay release), written
only by `relay-publish`, and no node reads it. `ci/release.sh` makes the branch, with an empty `index.json`, the first time it needs one.

`candidate/` is a feed of its own, holding the one version on its way to the test nodes: its
`index.json` names that version and the channel's revocations. Nodes never read it unless pointed at
it with `--feed`, which is what a test node does. `ci/release.sh candidate` writes it, after
checking again that every signer signed (below), and `publish` moves the version out of it into the
root and its `index.json` in one commit.

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
archive's `bin/`, `behaviors/` and `runtime/`, and `.release.json`, written last, naming its
version. Two
symlinks choose among them (`node/update/lib/layout.ml`):

- `current`: the release the service runs;
- `good`: the last release that reported healthy.

Older releases stay on disk. The behaviors run with the release's own Node.js, by its path:
`behaviors/bin/nightly-hook` runs `nightly.ts` with `runtime/bin/node` beside `behaviors/`, never a
`node` found on `PATH`, so a member's machine needs no Node.js of its own. A release staged from a
checkout (`digestif service install --behaviors`) carries no runtime and runs the `node` on `PATH`.
The nightly hook resolves through `current`: the node runs a hook path
ending in `behaviors/<file>`, such as a checkout's `behaviors/bin/nightly-hook`, from
`current/behaviors/<file>` when the current release has that file, so a member's existing absolute
hook path keeps working and follows every release. `digestif behavior set nightly
<data dir>/current/behaviors/bin/nightly-hook` names it directly.

## Staging

A pass that chooses a release stages it before anything the node runs changes
(`node/update/lib/stage.ml`):

1. download the archive and check its size and sha256 against the manifest both signers signed;
2. unpack it into `releases/.staging-<version>` and check it holds `bin/digestif`;
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

A failure leaves `current` alone. A download, a write or a checkout's missing Node.js is kept in
`update.json` as pending with its cause, and tried again after a backoff (ten minutes, doubling, at
most a day). A self-test that fails or hangs, or an archive without the binary or a runtime that
runs, refuses that version for good.

## Switching

A node runs under a supervisor once `digestif service install` has set up `releases/`, `current`
and `good`: the launchd agent or systemd unit runs `good/bin/digestif supervise`, the binary of the
last healthy release, and the supervisor runs `current/bin/digestif run` as its child
(`node/update/lib/supervisor.ml`). On a node not yet supervised a pass stages the release and the
digest says to run its `service install` once.

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
supervisor takes over the next time the service manager starts it. Past the trial the supervisor
counts the child's exits, and a version that keeps crashing goes back on its own (A version that
keeps crashing).

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
   since the last published release, or the tag's own message when a person wrote an annotated
   tag. A draft is readable only by people with write access until it is published. One failed
   platform leaves no draft and no manifest, so nothing partial can be signed. Nobody edits the
   manifest after; running the workflow again on the same tag replaces the draft's files and drops
   any signature beside them. `ci/release.sh build` succeeds once the draft holds all of it.
4. Each signer runs `digestif-update sign --next`, which shows what the version holds, asks, and
   uploads their signature to the draft (Signing a release).
5. `ci/release.sh candidate --version <version>` downloads the manifest and every `*.sig.json`
   asset of the release and checks them with `digestif-update verify`, a node's own check against
   the signer set, run from the `digestif-update` the newest published release holds for the
   machine's platform, so the version under review never vouches for itself (the draft's own copy
   is used only before any version is published). It
   exits 75 and changes nothing while a signer has not signed, which is what keeps Release now on
   a rollout from sending an unsigned version on. Once every signer signed, it publishes the GitHub
   release as a prerelease that is not Latest, so the archives can be fetched while the front page
   still offers the last published version; writes the manifest and the signatures, one per
   signer in one `manifest.sig.json`, under `candidate/` on the `channel` branch (The channel); and
   dispatches main's Release workflow with the version as its `candidate` input, which starts the
   test nodes. Run again, it dispatches again.
6. Once every test node passed (`ci/release.sh test-nodes`, Test nodes), `ci/release.sh publish --version <version>` moves the version out of
   `candidate/` and into `index.json` in one commit on `channel`, and marks the GitHub release
   Latest. From then on members' nodes take it on their next update pass. Marking it Latest is also
   what publishes the release's `install.sh` at `https://digestif.io/install.sh` (below).

The same workflow runs as a dry run on every push to `main`, every pull request, and by hand: it
builds and stages every platform at the version the commit is and uploads nothing, so a change that breaks one
platform shows within minutes rather than on release day. It is the only automated build of macOS;
`ci/build.sh` builds Linux on the fleet's builders.
The one pull request it skips is a fleet merge build's (head branch `batch-*`): its land merges it
seconds after it opens, so the push to `main` that follows builds the same tree.

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
   to the release's signed manifest (`releases/<version>/` on `main`, the manifest beside its
   signatures); a mismatch stops it with nothing installed;
3. unpacks the archive and stages it with the binary inside it, `digestif update stage <archive>`:
   the checks a node runs before it runs a release (staging, above), into `<data dir>/releases/`,
   changing nothing the node runs. A release already staged is not staged again, so running the
   command a second time resumes;
4. links `~/.local/bin/digestif` to the staged release's binary;
5. with `--join <invite code>`, runs `digestif join <invite code>` reading the terminal, since under
   `curl | sh` standard input is the script; with no terminal it stops before the join.

It checks the sha256 and no signature, and never says it checked one: a signature check needs a
tool a stock machine lacks. Its trust rests on TLS to `digestif.io`, as every `curl | sh` does, and
the manifest link lets anyone compare the sha256 with the one both signers signed. Every update
after the install is checked against both signatures (above). Nothing is built: no git, no dune,
no npm, and no Node.js, since the archive carries its own. The repo-root `install.sh` stays the
build-from-source path for contributors.

The Release workflow attaches `install.sh` to the draft release, and the newest published release
is the one `https://github.com/digestif-ai/digestif/releases/latest/download/install.sh` names. The
`dinners` relay answers `https://digestif.io/install.sh` with that file (`relay/src/install.ts`,
`INSTALL_SCRIPT_URL` and `SITE_HOST` in `relay/wrangler.jsonc`), so publishing a release publishes
its script, and the bare domain answers nothing else.

## Signing a release

A signer signs with one command, the same every time: `digestif-update sign --next`. It takes the
version waiting for signatures, so a command copied from last week's request is still the right
one.

Run a `digestif-update` you already hold, never one built by the version you are judging. Every
node release that is not a draft carries one per platform as `digestif-update-<platform>`, and both
signers signed it, a candidate (a prerelease) included. One line fetches the one from the newest
node release that is not a draft and signs with it:

    d=$(mktemp -d)&&r=digestif-ai/digestif&&t=$(gh api repos/$r/releases -q 'first(.[]|select(.draft|not).tag_name|select(startswith("v")))')&&gh release download $t -R $r -p digestif-update-darwin-arm64 -O $d/u&&chmod +x $d/u&&$d/u sign --next

It names that release's tag rather than leaving it to `gh release download` with no tag, which takes
the release marked Latest: a candidate is never Latest, and a candidate can be the first version
whose `digestif-update` knows a line the waiting draft is on. Latest's then passes over that draft.
A `sign --next` that finds a draft on a line it does not know names it and says to run a newer one.

`darwin-arm64` is the platform; `ci/platforms.json` lists the others. A node's
`<data dir>/good/bin/digestif-update` is the same binary once it has updated. Before any version is
published there is no node release to take it from, and the trusted tool is one built from a tag you have
already reviewed: `git checkout v0.1.1` in your own checkout, then `dune build
./update/bin/main.exe` in `node/` and run `node/_build/default/update/bin/main.exe sign --next`. It
talks to GitHub with your own `gh` login, which needs write access to the repository, since a draft
release is readable by nobody else.

### Where the key comes from

`sign --next` reads the key from a command you name once in `~/.config/digestif/signer.json`
(`$XDG_CONFIG_HOME/digestif/signer.json` when that is set). The command prints the secret
`digestif-update keygen` made, and `sign --next` writes nothing of it to disk: it goes from the
command's output into the memory of the one process that signs. The command runs under
`/bin/sh -c`, so any password manager with a command line works:

```json
{ "key_command": "op read 'op://Private/Digestif release key/password'" }
```

A key kept as a document that the password manager's app downloads (1Password's Download, with no
`op` installed) is read from where it lands, and the signing line deletes it as soon as
`sign --next` returns:

```json
{ "key_command": "cat ~/Downloads/digestif-release.key" }
```

    "$d/digestif-update-darwin-arm64" sign --next ; rm -f ~/Downloads/digestif-release.key

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
   runs its supervisor. The first version has nothing to update from, and neither does a platform
   newer than the last published version: the version's archive is checked against the manifest
   and installs directly, `candidate` having verified the signatures.
2. Run `digestif update apply --feed <candidate>`, so nothing waits on the node's daily read. It verifies
   the signatures, stages, self-tests and switches.
3. Restart the service. The old supervisor runs the version on trial, ten minutes of awake time at most.
4. Restart the service again, so the version's own supervisor runs.
5. Run one more update pass with the version's own code, which must read the channel and switch to
   nothing. A later fix or recall depends on that pass and that supervisor.

A test node has no circle, no keys and no keystore, so nothing on the runner holds a secret. Its first
pass logs that it cannot sync (`no device key` on macOS, no `secret-tool` on Linux), as a node nobody
has initialized does, and it reports healthy after that pass. So a test node proves a version installs,
starts, serves and updates. It does not prove the version can sync with a circle.

`ci/release.sh test-nodes --version <version>` reads what the newest run says:

- `passed`: every platform's job passed, and `publish` runs.
- `failed`: a node says no: it refused the version or rolled it back, or the version's own supervisor or
  update pass did not work. The job's `the version failed on this node` step fails. No member could
  have received it, so the next version is the fix.
- `silent`: the jobs ended and said nothing about the version: a runner never started, a job hit its
  limit, or a download failed, which fails the job's `this node observed nothing` step instead.
  Running `ci/release.sh candidate` again dispatches again, which is how a job restarts.
- `running`: it has not finished.

Nothing else can run these jobs on a real version, so `ci/test-node-rehearsal.sh` runs the same script
for real, on every platform, against versions built with throwaway keys, including one it must refuse. A pull request touching
what a test node depends on runs it (`.github/workflows/test-node-rehearsal.yml`).

### Reading the channel, and dropping a version

`ci/release.sh channel` is the rollout's last read, the channel as a member's node reads it: with
no version it prints the newest version `index.json` lists; with `--version` it prints `listed`
only when `index.json` names the version, its manifest and signatures verify with the newest other
published release's `digestif-update`, and every archive fetches at its manifest's size and sha256.
It exits 75 when the channel or an archive could not be read, which says nothing about the version.

`ci/release.sh drop --version <version>` deletes the release while it is a draft or a prerelease,
keeping the tag, and clears `candidate/` when it holds the version. A rollout runs it for a version
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
`pbpaste | digestif-update recall 0.1.7 --reason "..." --key /dev/stdin`. The command clones the
channel's `channel` branch with the signer's own `gh` login (`gh auth git-credential`), writes the
recall, commits and pushes it in one commit, so it needs nothing of the fleet. It refuses a version the channel does not publish. On a
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
The tagging job asks `ci/release.sh relay tag --sha <commit>` beside `ci/release.sh changed`: when
`ci/release.sh relay changed` answers `changed` it tags the next relay patch and pushes it, and a
minor or major relay version is a person's tag. `ci/relay-release-paths`, in `ci/release-paths`'s
format, names what a bundle is built from: `relay/src`, `relay/migrations`, the relay's package
files, the top level of `relay/wrangler.jsonc` (a change inside its `env` object, one deployment's
settings, cuts nothing), every module outside `relay/src` the Worker bundles, the UI sources
`ci/release-paths` names (the phone app the relay serves is the node's UI built for a phone, so a UI
change cuts both lines), and the scripts that build the bundle.

**The build.** Pushing a relay tag starts `.github/workflows/relay-release.yml`, which refuses a tag
that is not `relay-v<MAJOR.MINOR.PATCH>` on `main` or whose release is published, then:

1. refuses a migration that is not additive (`ci/relay-migrations.sh`: a `DROP` or `RENAME` in a
   migration the previous relay version did not carry, or a change to one it did), since a
   rollback replaces the Worker and never the schema;
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
6. leaves a **draft** GitHub release `relay-v<version>` holding the bundle and the manifest, created
   and edited with `--latest=false`. It is never Latest: Latest is the node line, which the hosted
   install script and `gh release download` with no tag read. Running it again on the same tag
   replaces the draft's files and drops any signature beside them.

**The bundle**, `digestif-relay-<version>.tar.gz`: `worker/index.js` and `worker/index.js.map`
(the map's sources repository-relative), `app/` (the phone app), `migrations/*.sql` (every D1
migration from `0001_init.sql` on) and `bundle.json` (`relay/scripts/bundle-json.ts`): the main
module's name, the compatibility date and flags, the assets binding, and the names, never the
values, of the D1 binding and every var and secret a deployment sets. It carries no per-deployment
value, so one bundle deploys to every relay unchanged. `ci/build.sh` packs a rehearsal bundle and
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

### Signing a relay release

The same signers sign a relay version with the same command: `digestif-update sign --next` asks
about the node version waiting for signatures first, then the relay version waiting (a draft
release tagged `relay-v<version>`, chosen as for the node line), one after the other. A relay tag
is never a node version and a node tag never a relay version. For a relay version it prints,
before it reads the key:

- the version, the commit its tag names, and the Relay release workflow run that built it;
- every commit title since the last published relay version that touched a relay release path
  (`ci/relay-release-paths` at the tag, read with the pathspec rules of `ci/release-paths`), and
  the compare link. It reads each commit's files with one request, which for the first relay
  version is the newest 100 commits, so it says how many it reads before the first and counts
  every 25;
- the notes as signed;
- **the full text of every migration the version adds** over the last published relay version,
  read from the tag and checked against the manifest's sha256, since a migration is the one part
  of a relay release a rollback does not undo;
- the bundle's sha256, checked against the digest GitHub holds for the draft's file;
- `compatible_with`, and every relay's `relay_version` as this machine's node reads it now, a relay
  older than `compatible_with` marked (no node here: it says so);
- who has already signed.

`s` signs the manifest's exact bytes over `DIGESTIF-RELAY-RELEASE-V0` and uploads
`manifest.<key>.sig.json` to the draft, exactly as for a node version; `d` drops the draft; anything
else leaves it waiting. When the signature it uploaded completes the signer set, `sign --next`
publishes the version itself (below) and prints each step. A version signed by every signer that
did not publish is said with the line to run.

### Publishing a relay release

`ci/release.sh relay-publish --version <version>` publishes a relay version every signer signed.
Anyone with write access may run it, and running it again finishes what an earlier run left. It
runs `digestif-update relay-publish <version>` from the `digestif-update` the newest published node release
holds for the machine (`DIGESTIF_UPDATE` names another), so the version under review never vouches
for itself; `sign --next` runs the same steps in its own process
(`node/update/lib/relay_publish.ml`). Three steps:

1. Download the draft's manifest and every signature and check them as a node does
   (`Policy.check_relay`). A signer missing exits 75 having published nothing.
2. Publish the GitHub release, never as Latest (Latest is the node line to the install script and
   to the signing line), and write `relay/<version>/manifest.json`, its exact bytes,
   `relay/<version>/manifest.sig.json`, one signature per signer, and `relay/index.json` on the
   channel in one commit, with the signer's own `gh` login. `relay/index.json` has the node index's
   shape, format `digestif-relay-feed-v0`, every published relay version in version order and the
   channel's revocations named from `relay/`. A different manifest already under the version is
   refused.
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

**`digestif relay operate <url>`** sets it up, once, on the operator's own node. It asks for the
Cloudflare account id, the Worker's name and the D1 database's id (or takes them from
`--account-id`, `--worker` and `--database-id`), and reads the deploy token at a hidden prompt into
memory. Before it stores anything it:

- verifies the token with Cloudflare's `GET /user/tokens/verify` (an account-owned token, at
  `GET /accounts/<id>/tokens/verify`), lists the account's Workers and refuses a token that cannot
  see the named Worker or can see a second one, and reads the database;
- reads the Worker version serving now, the first rollback target;
- reads the relay's `relay_version` on a signed `GET /v0/circle`, so the record starts from what is
  running.

It then stores the token in the keystore as `relay-deploy-token` (service `digestif`, account
`relay-deploy-token@<data dir>`) and the rest in `relay-deploy.json` in the data directory: url,
account id, Worker name, database id, rollback version id, the reported relay version, a pending
step, refused versions. When the relay's newest `relay` message is not this node's, it writes it
again with the same body, which makes this node its operator from the next sync. Running it again
for the same relay replaces the token; naming another relay is refused until
`digestif relay operate --remove <url>` deletes the token and the record. The token is a Cloudflare
custom API token on the relay's own account, with `Workers Scripts: Edit` and `D1: Edit`, and
reaches `curl` only in a config file on stdin (`curl -K -`), never on an argv.

**`digestif relay status`** prints the newest relay release, the record, who the circle reads as
the operator, the deployed version, a pending step and its retry time, and refused versions, never
the token.

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
   annotated with the bundle's sha256. A version already carrying both is reused.
4. **Deploy.** Record the Worker version serving now in `relay-deploy.json` as the rollback target,
   then deploy the new version at 100%. A pass finding it serving already deploys nothing.
5. **Health check.** A signed `GET /v0/circle` answering 200 with the release's `relay_version` and
   the circle's `root`, and `GET /app/` answering 200, within two minutes of awake time counted in
   one-second steps as a trial is.
6. **Kept, or rolled back.** A pass records the version, and the next digest says "Deployed relay
   0.3.0 to dinners.digestif.io." A failure deploys the rollback target at 100%, checks that the
   relay answers the version it reported before, refuses the release on this relay for good, and
   the next digest says what the relay answered and that the node rolled it back. A rollback that
   fails too is a line leading the digest's "On your machine" section, with the `wrangler rollback`
   to run, on every digest until the relay answers a version the node knows.

`bundle.json` is read for `main_module` (default `index.js`), `compatibility_date` (required),
`compatibility_flags`, and an optional `assets` object (`binding`, `html_handling`,
`run_worker_first`).

A step failing before the deploy changes nothing the relay serves. A download, a bundle whose bytes
do not match, or Cloudflare not answering or answering 5xx is kept as pending in
`relay-deploy.json` with its step and cause, and tried again on the update pass's backoff (ten
minutes, doubling, at most a day). A 401 or 403 is a digest line naming `digestif relay operate`,
once, and nothing is tried until that command stores a new token. A migration D1 refuses is refused
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
- An exit after which `current` names another release is the child's own move back (a recall) and
  is not counted, and neither is the child stopping because the service manager stopped the
  supervisor. An exit during a trial is the trial's to judge.
- With nothing older on its disk, or an older release that fails its self-test, the node keeps the
  version and the service manager keeps restarting it; the version is not refused, and the count
  starts over.

The digest says what happened, once:

- "Digestif 0.1.7 kept crashing, so this node went back to 0.1.6."
- "Digestif 0.1.7 kept crashing, and this node has nothing older to go back to, so it keeps
  restarting until the next release.", or the failed self-test in place of "has nothing older to go
  back to". It reaches the person only if the node stays up long enough to send a digest.
