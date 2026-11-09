#!/usr/bin/env bash
#
# Digestif's release command (docs/releases.md, Cutting a release): the verbs a rollout runs, in
# order, against origin as fetched now, never this working tree. A version is a tag of main,
# v<MAJOR.MINOR.PATCH>, and pushing it starts the Release workflow (.github/workflows/release.yml).
#
#   ci/release.sh build [--version X.Y.Z] [--sha COMMIT]
#       Without --version: tag origin/main with the next patch of the newest release tag (0.1.0
#       when there is none) and push the tag; a tip already tagged is that version. With
#       --version: the tag v<X.Y.Z>, which a person pushed, and which this never mints. Then wait
#       for the Release run on the tag and succeed once the draft release holds every platform's
#       archive and digestif-update and the manifest, each archive having passed stage-test. A
#       version already built is success with nothing to do. --sha names the commit the caller
#       judged: a run whose origin/main is any other commit exits 75 having tagged nothing.
#   ci/release.sh changed [--sha COMMIT]
#       Read-only. Prints `changed` when a path in ci/release-paths differs between the newest
#       release tag and origin/main (or COMMIT), else `unchanged`, and exits 0 either way; the
#       paths that moved go to stderr. No release tag yet is `changed`.
#   ci/release.sh signatures --version X.Y.Z
#       Read-only. Prints `complete` when the draft release v<X.Y.Z> carries a valid signature of
#       every signer, `waiting` when it does not (the missing signers go to stderr), `gone` when the
#       draft was deleted (a signer dropped it), and `published` when it is no longer a draft. The
#       signatures are checked by the digestif-update the newest published release holds for this
#       machine's platform (`digestif-update verify`), the draft's own copy only before any version
#       is published; every node checks them again with the code it runs.
#   ci/release.sh candidate --version X.Y.Z
#       Verify both signatures again with that same digestif-update (DIGESTIF_UPDATE names
#       another), publish the GitHub release as a prerelease that
#       is not Latest, write the manifest and its signatures under candidate/ on the channel
#       branch, and dispatch main's Release workflow with the version as its candidate, which
#       starts the test nodes. Run again, it dispatches again. Exits 75, writing nothing, while a
#       signer has not signed.
#   ci/release.sh test-nodes --version X.Y.Z
#       Read-only. What the newest test-node run of the version says (docs/releases.md, Test nodes):
#       prints `passed` when every platform's node took it and exits 0, `failed` when one says the
#       version is bad and exits 1, and `running` or `silent` and exits 75 otherwise. `silent` says
#       nothing about the version; running candidate again restarts the nodes.
#   ci/release.sh publish --version X.Y.Z
#       Once every test node passed: one commit on the channel branch moves the version out of
#       candidate/ and adds it to index.json, then the GitHub release becomes Latest.
#   ci/release.sh channel [--version X.Y.Z]
#       Read-only, what a member's node reads off the channel branch as origin holds it now.
#       Without --version: prints the newest version index.json lists, and nothing before the
#       first. With --version: prints `listed` and exits 0 when index.json lists it, its manifest
#       and signatures verify with the newest other published release's digestif-update, and every
#       archive fetches over https at its manifest's size and sha256; prints `absent` and exits 1
#       when it does not; exits 75 when the channel or an archive could not be read.
#   ci/release.sh relay-publish --version X.Y.Z
#       Publish the relay release relay-v<X.Y.Z> once every signer signed it (docs/releases.md,
#       Publishing a relay release), with the digestif-update the newest published node release
#       holds for this machine (DIGESTIF_UPDATE names another): check the signatures as a node
#       does, publish the GitHub release (never Latest), write relay/<X.Y.Z>/ and relay/index.json
#       on the channel branch in one commit, and announce it on the circle through this machine's
#       node, or print the line that does from a machine running one. `sign --next` runs the same
#       steps itself when its signature completes the signer set. Runs on a signer's machine, never
#       in CI: the announcement needs a device key. Exits 75, having published nothing, while a
#       signer has not signed, and 75 when the announcement is held because a relay does not know
#       relay_release yet (the one line it prints says what to run again).
#   ci/release.sh drop --version X.Y.Z
#       Delete the release while it is a draft or a prerelease (the tag stays), and clear
#       candidate/ on the channel branch when it holds the version: what a superseded or canceled
#       rollout, and a test node's no, leave behind. A published version, which only a recall
#       undoes, and an absent one are left as they are, and both succeed.
#
# The relay line (docs/releases.md, Relay releases) is tagged relay-v<MAJOR.MINOR.PATCH> and never
# names a node version; pushing a relay tag starts the Relay release workflow
# (.github/workflows/relay-release.yml), which leaves a draft release that is never Latest.
#
#   ci/release.sh relay changed [--sha COMMIT]
#       Read-only. Prints `changed` when a path in ci/relay-release-paths differs between the
#       newest relay-v* tag and origin/main (or COMMIT), else `unchanged`, and exits 0 either way;
#       the paths that moved go to stderr. Of relay/wrangler.jsonc only the top level counts, not
#       its "env" object. No relay tag yet is `changed`.
#   ci/release.sh relay tag [--sha COMMIT]
#       What the tagging job runs beside `changed`: when `relay changed` answers changed, tag
#       origin/main with the next patch of the newest relay tag (relay-v0.1.0 when there is none),
#       push it and print it; a tip already relay-tagged prints that tag; otherwise print
#       `unchanged` and tag nothing. --sha as for build: exits 75 when origin/main is another commit.
#
# Exits 0 on success, 1 on a failure, 2 on a usage error, and 75 when main moved under --sha, a
# candidate or a relay release is not signed yet, a relay release's announcement is held, the test
# nodes have not said yes or no, or the channel could not be read. Needs git, jq, curl and an
# authenticated gh with write access to the repository.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wait_minutes="${DIGESTIF_RELEASE_WAIT_MINUTES:-60}"
poll_seconds=60

die() {
  echo "release.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,83p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

# The newest tag `git tag` lists for the arguments after $1 whose name past the prefix $1 is a
# valid version, or nothing. The whole list is read before the first is taken: a producer piped
# into a reader that stops at its line (`| head -1`) has the rest of the list left to write, and
# under pipefail that write fails the pipeline once the list outgrows the pipe. ISS-47745
newest_tag() {
  local prefix="$1" tags t
  shift
  tags="$(git -C "$root" tag --list "$@" --sort=-v:refname)" || return 1
  while IFS= read -r t; do
    if valid_version "${t#"$prefix"}"; then
      echo "$t"
      return
    fi
  done <<<"$tags"
}

# The newest release tag, and the newest release tag on a commit.
newest_release_tag() { newest_tag v 'v[0-9]*'; }
newest_release_tag_at() { newest_tag v --points-at "$1" 'v[0-9]*'; }

next_patch() {
  local newest major minor patch
  newest="$(newest_release_tag)"
  if [ -z "$newest" ]; then
    echo 0.1.0
    return
  fi
  IFS=. read -r major minor patch <<<"${newest#v}"
  echo "$major.$minor.$((patch + 1))"
}

fetch() {
  git -C "$root" fetch --quiet --force --tags origin main
}

# origin/main as fetched, or exit 75 when the caller judged another commit.
target_commit() {
  local sha expected="$1"
  sha="$(git -C "$root" rev-parse refs/remotes/origin/main)"
  if [ -n "$expected" ] && [[ "$sha" != "$expected"* || ${#expected} -lt 7 ]]; then
    echo "release.sh: origin/main is $sha, not $expected; main moved, so nothing is tagged" >&2
    exit 75
  fi
  echo "$sha"
}

# ci/release-paths at a commit, one pathspec per line.
release_paths_at() {
  git -C "$root" show "$1:ci/release-paths" | grep -v -e '^#' -e '^[[:space:]]*$'
}

repo() {
  git -C "$root" remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##'
}

cmd_changed() {
  local sha="" target newest specs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) [ $# -ge 2 ] || usage; sha="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  fetch
  target="$(target_commit "$sha")"
  newest="$(newest_release_tag)"
  if [ -z "$newest" ]; then
    echo "release.sh: no release tag yet" >&2
    echo changed
    return
  fi
  if ! git -C "$root" cat-file -e "$target:ci/release-paths" 2>/dev/null; then
    echo "release.sh: $target has no ci/release-paths" >&2
    echo changed
    return
  fi
  while IFS= read -r line; do specs+=("$line"); done < <(release_paths_at "$target")
  [ "${#specs[@]}" -gt 0 ] || die "ci/release-paths at $target names no path"
  local moved
  moved="$(git -C "$root" diff --name-only "$newest" "$target" -- "${specs[@]}")"
  if [ -n "$moved" ]; then
    echo "release.sh: since $newest: $(printf '%s' "$moved" | tr '\n' ' ')" >&2
    echo changed
  else
    echo "release.sh: nothing a member runs moved since $newest" >&2
    echo unchanged
  fi
}

# Every file the draft release must hold for the version: each platform's archive and
# digestif-update, and the manifest.
expected_assets() {
  local p
  git -C "$root" show "$1:ci/platforms.json" | jq -r '.platforms[].platform' | while IFS= read -r p; do
    echo "digestif-$p.tar.gz"
    echo "digestif-update-$p"
  done
  echo manifest.json
}

# Empty when the release holds every expected asset, else what it lacks (or that it is absent).
missing_assets() {
  local tag="$1" have
  have="$(gh release view "$tag" --repo "$(repo)" --json assets --jq '.assets[].name' 2>/dev/null)" || {
    echo "the release $tag"
    return
  }
  expected_assets "$tag" | while IFS= read -r a; do
    grep -qxF "$a" <<<"$have" || echo "$a"
  done
}

# Waits for the Release workflow's run on the tag; fails unless it concludes success. A failed
# attempt that .github/workflows/release-retry.yml re-runs (ci/release-retry.sh: every failure a job
# no hosted runner took) is waited through, since the run goes on under its next attempt.
wait_for_run() {
  local tag="$1" deadline line status conclusion url id attempt verdict
  deadline=$((SECONDS + wait_minutes * 60))
  while :; do
    line="$(gh run list --repo "$(repo)" --workflow release.yml --event push --branch "$tag" \
      --limit 1 --json status,conclusion,url,databaseId,attempt \
      --jq '.[0] | [.status, .conclusion, .url, .databaseId, .attempt] | @tsv' \
      2>/dev/null || true)"
    if [ -n "$line" ]; then
      IFS=$'\t' read -r status conclusion url id attempt <<<"$line"
      if [ "$status" = completed ] && [ "$conclusion" = failure ]; then
        verdict="$(bash "$root/ci/release-retry.sh" decide "$(repo)" "$id" "$attempt" 2>/dev/null || true)"
        if [ "${verdict%%:*}" = retry ]; then
          echo "release.sh: attempt $attempt of the Release run on $tag found no runner ($verdict); waiting for the retry: $url" >&2
          status=retrying
        fi
      fi
      if [ "$status" = completed ]; then
        [ "$conclusion" = success ] || die "the Release run on $tag ended $conclusion: $url"
        echo "release.sh: the Release run on $tag passed: $url" >&2
        return
      fi
      [ "$status" = retrying ] || echo "release.sh: the Release run on $tag is $status: $url" >&2
    else
      echo "release.sh: no Release run on $tag yet" >&2
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "the Release run on $tag did not finish in $wait_minutes minutes"
    sleep "$poll_seconds"
  done
}

cmd_build() {
  local version="" sha="" target tag existing
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      --sha) [ $# -ge 2 ] || usage; sha="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  fetch
  if [ -n "$version" ]; then
    valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
    tag="v$version"
    git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null ||
      die "there is no tag $tag; push it first, since --version builds a tag and mints none"
    git -C "$root" merge-base --is-ancestor "refs/tags/$tag" refs/remotes/origin/main ||
      die "$tag is not a commit of main"
  else
    target="$(target_commit "$sha")"
    existing="$(newest_release_tag_at "$target")"
    if [ -n "$existing" ]; then
      tag="$existing"
      echo "release.sh: origin/main $target is already $tag" >&2
    else
      tag="v$(next_patch)"
      git -C "$root" tag "$tag" "$target"
      git -C "$root" push --quiet origin "refs/tags/$tag" || {
        git -C "$root" tag -d "$tag" >/dev/null
        die "could not push $tag"
      }
      echo "release.sh: tagged origin/main $target as $tag" >&2
    fi
  fi

  if [ -z "$(missing_assets "$tag")" ]; then
    echo "release.sh: $tag is already built" >&2
  else
    wait_for_run "$tag"
    local missing
    missing="$(missing_assets "$tag")"
    [ -z "$missing" ] || die "the release $tag lacks: $(printf '%s' "$missing" | tr '\n' ' ')"
  fi
  echo "$tag"
}

cmd_signatures() {
  local version="" tag draft err dir tool out code
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$version" ] || usage
  valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
  tag="v$version"
  err="$(mktemp "${TMPDIR:-/tmp}/release-signatures.XXXXXX")"
  if ! draft="$(gh release view "$tag" --repo "$(repo)" --json isDraft --jq .isDraft 2>"$err")"; then
    if grep -qi 'not found' "$err"; then
      rm -f "$err"
      echo "release.sh: the release $tag is gone" >&2
      echo gone
      return
    fi
    cat "$err" >&2
    rm -f "$err"
    die "could not read the release $tag"
  fi
  rm -f "$err"
  if [ "$draft" = false ]; then
    echo "release.sh: $tag is published" >&2
    echo published
    return
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/release-signatures.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  gh release download "$tag" --repo "$(repo)" --dir "$dir" --pattern manifest.json \
    --pattern 'manifest.*.sig.json' >&2 ||
    die "could not download $tag's manifest and signatures"
  [ -f "$dir/manifest.json" ] || die "$tag's draft holds no manifest.json"
  tool="$(update_tool "$tag" "$dir")"
  local sigs=()
  for f in "$dir"/manifest.*.sig.json; do
    [ -e "$f" ] && sigs+=("$f")
  done
  if [ "${#sigs[@]}" -eq 0 ]; then
    echo "release.sh: nobody has signed $tag" >&2
    echo waiting
    return
  fi
  code=0
  out="$("$tool" verify "$dir/manifest.json" "${sigs[@]}" --expect-version "$version" 2>&1)" || code=$?
  printf '%s\n' "$out" >&2
  if [ "$code" = 0 ]; then
    echo complete
  elif grep -q '^missing ' <<<"$out"; then
    echo waiting
  else
    die "digestif-update verify could not check $tag's signatures"
  fi
}

# The channel (docs/releases.md, The channel): the branch every node reads, written only by
# candidate, publish and a recall. It holds no workflow, so a push to it starts nothing.
channel_branch=channel
scratch=()
cleanup() {
  local d
  for d in "${scratch[@]+"${scratch[@]}"}"; do
    git -C "$root" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
  done
}
trap cleanup EXIT

# Sets $scratch_path to a new directory removed on exit. Not a $(...): that would record it in a
# subshell's copy of $scratch.
scratch_dir() {
  scratch_path="$(mktemp -d -t digestif-release)"
  scratch+=("$scratch_path")
}

version_option() {
  local version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$version" ] || usage
  valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
  echo "$version"
}

# draft, prerelease, published, or absent.
release_state() {
  local s
  s="$(gh release view "$1" --repo "$(repo)" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' \
    2>/dev/null)" || s=absent
  echo "$s"
}

# The commit origin's channel branch is at, made with an empty index.json when it does not exist.
channel_head() {
  if git -C "$root" fetch --quiet --force origin \
    "refs/heads/$channel_branch:refs/remotes/origin/$channel_branch" 2>/dev/null; then
    git -C "$root" rev-parse "refs/remotes/origin/$channel_branch"
    return
  fi
  local index readme tree commit
  index="$(printf '%s\n' '{' '  "format": "digestif-feed-v0",' '  "releases": [],' \
    '  "revocations": []' '}' | git -C "$root" hash-object -w --stdin)"
  readme="$(printf '%s\n' '# The Digestif release channel' '' \
    'What every node reads to decide what to install: `index.json` and the signed documents it' \
    'names. Written only by `ci/release.sh candidate` and `publish` and by a recall; see' \
    '`docs/releases.md` on main, The channel.' | git -C "$root" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tREADME.md\n100644 blob %s\tindex.json\n' "$readme" "$index" |
    git -C "$root" mktree)"
  commit="$(git -C "$root" commit-tree "$tree" -m "The release channel")"
  if git -C "$root" push --quiet origin "$commit:refs/heads/$channel_branch" 2>/dev/null; then
    echo "release.sh: made the $channel_branch branch" >&2
    echo "$commit"
  else
    # Made by somebody else meanwhile: theirs.
    git -C "$root" fetch --quiet --force origin \
      "refs/heads/$channel_branch:refs/remotes/origin/$channel_branch" ||
      die "could not make or read the $channel_branch branch"
    git -C "$root" rev-parse "refs/remotes/origin/$channel_branch"
  fi
}

# Runs `$@ <worktree>` on a worktree of the channel's head and pushes what it changed as one
# commit titled $message; a push that lost a race starts again from the new head.
channel_commit() {
  local message="$1" attempt wt head
  shift
  for attempt in 1 2 3; do
    head="$(channel_head)"
    scratch_dir
    wt="$scratch_path"
    git -C "$root" worktree add --quiet --detach "$wt" "$head"
    "$@" "$wt"
    git -C "$wt" add --all
    if git -C "$wt" diff --cached --quiet; then
      echo "release.sh: the $channel_branch branch already holds it" >&2
      return
    fi
    git -C "$wt" commit --quiet -m "$message"
    if git -C "$wt" push --quiet origin "HEAD:refs/heads/$channel_branch"; then
      echo "release.sh: $message on $channel_branch at $(git -C "$wt" rev-parse HEAD)" >&2
      return
    fi
    echo "release.sh: $channel_branch moved during attempt $attempt; trying again" >&2
  done
  die "could not push to $channel_branch"
}

# The platform name ci/platforms.json gives this machine.
this_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "no release platform for $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) die "no release platform for $(uname -m)" ;;
  esac
  echo "$os-$arch"
}

# The digestif-update that checks a version's signatures, downloaded into $2: the one the newest
# published release holds for this machine, which both signers signed and members already run.
# The draft's own copy, which nobody has signed yet, only before any version is published, so the
# version under review never vouches for itself. DIGESTIF_UPDATE names another.
update_tool() {
  local tag="$1" dir="$2" platform from
  if [ -n "${DIGESTIF_UPDATE:-}" ]; then
    echo "$DIGESTIF_UPDATE"
    return
  fi
  platform="$(this_platform)"
  from="$(published_tag "$tag")"
  if [ -z "$from" ] && [[ "$tag" == relay-v* ]]; then
    die "no node version is published yet, so no digestif-update can check $tag; set DIGESTIF_UPDATE to one"
  elif [ -z "$from" ]; then
    echo "release.sh: no version is published yet, so $tag's own digestif-update checks it" >&2
    from="$tag"
  else
    echo "release.sh: checking with the digestif-update of $from, the newest published version" >&2
  fi
  mkdir -p "$dir/tool"
  gh release download "$from" --repo "$(repo)" --dir "$dir/tool" --clobber \
    --pattern "digestif-update-$platform" >/dev/null ||
    die "the release $from holds no digestif-update-$platform; set DIGESTIF_UPDATE to one"
  chmod 755 "$dir/tool/digestif-update-$platform"
  echo "$dir/tool/digestif-update-$platform"
}

# The newest node release other than $1 that is neither a draft nor a prerelease, or nothing before
# the first. A relay release (relay-v...) is published too, never as Latest, and is never a node
# release: it holds no digestif-update.
published_tag() {
  gh release list --repo "$(repo)" --exclude-drafts --exclude-pre-releases --limit 30 \
    --json tagName \
    --jq "[ .[].tagName | select(startswith(\"v\") and . != \"$1\") ] | first // empty" ||
    die "could not list the published releases"
}

# Downloads the release's manifest and every signature asset into $3 and verifies them as a node
# does, writing the signatures every signer gave as $3/manifest.sig.json. Exits 75 while a signer
# has not signed.
verified_signatures() {
  local tag="$1" version="$2" dir="$3" tool sigs=() f
  gh release download "$tag" --repo "$(repo)" --dir "$dir/assets" --clobber \
    --pattern manifest.json --pattern '*.sig.json' >/dev/null ||
    die "could not download the manifest of $tag"
  [ -f "$dir/assets/manifest.json" ] || die "the release $tag holds no manifest.json"
  for f in "$dir"/assets/*.sig.json; do
    [ -e "$f" ] && sigs+=("$f")
  done
  tool="$(update_tool "$tag" "$dir")"
  if ! "$tool" verify "$dir/assets/manifest.json" "${sigs[@]+"${sigs[@]}"}" \
    --expect-version "$version" --out "$dir/manifest.sig.json" >"$dir/verify.out"; then
    cat "$dir/verify.out" >&2
    if grep -q '^missing ' "$dir/verify.out"; then
      echo "release.sh: $tag waits for signatures; nothing was published" >&2
      exit 75
    fi
    die "the signatures of $tag do not verify"
  fi
  cat "$dir/verify.out" >&2
}

# candidate/ holds the one version on its way to the test nodes, as a feed of its own: its
# index.json names that version and the channel's revocations, and nodes never read it.
write_candidate() {
  local version="$1" dir="$2" wt="$3"
  rm -rf "$wt/candidate"
  mkdir -p "$wt/candidate/$version"
  cp "$dir/assets/manifest.json" "$wt/candidate/$version/manifest.json"
  cp "$dir/manifest.sig.json" "$wt/candidate/$version/manifest.sig.json"
  jq --arg v "$version" '{
      format,
      releases: [ { version: $v, manifest: "\($v)/manifest.json", signatures: "\($v)/manifest.sig.json" } ],
      revocations: [ .revocations[] | { document: "../\(.document)", signatures: "../\(.signatures)" } ]
    }' "$wt/index.json" >"$wt/candidate/index.json"
}

cmd_candidate() {
  local version tag state dir
  version="$(version_option "$@")"
  tag="v$version"
  fetch
  git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || die "there is no tag $tag"
  state="$(release_state "$tag")"
  case "$state" in
    absent) die "the release $tag is gone, so there is nothing to send to the test nodes" ;;
    published)
      echo "release.sh: $tag is already published" >&2
      echo "$tag"
      return
      ;;
  esac
  scratch_dir
  dir="$scratch_path"
  verified_signatures "$tag" "$version" "$dir"
  if [ "$state" = draft ]; then
    # Its archives must be fetchable by a test node, and the front page must not offer it yet.
    gh release edit "$tag" --repo "$(repo)" --draft=false --prerelease --latest=false >/dev/null
    echo "release.sh: published $tag as a prerelease" >&2
  fi
  channel_commit "Candidate $version" write_candidate "$version" "$dir"
  gh workflow run release.yml --repo "$(repo)" --ref main -f candidate="$version" >/dev/null ||
    die "could not dispatch the Release workflow for the candidate $version"
  echo "release.sh: dispatched the Release workflow on main with candidate $version" >&2
  echo "$tag"
}

# The word for the newest test-node run of the version, from the run's jobs as `gh run view` gives
# them on stdin. A job is `passed` only by succeeding, the version `failed` only through the step
# the workflow runs on a node's no, and every platform must have a job.
test_nodes_verdict() {
  jq -r --argjson want "$1" '
    [ .jobs[] | select(.name | startswith("test node ")) ] as $nodes
    | if any($nodes[]; any(.steps[]; .name == "the version failed on this node" and .conclusion == "failure"))
      then "failed"
      elif .status != "completed" then "running"
      elif ($nodes | length) == $want and all($nodes[]; .conclusion == "success") then "passed"
      else "silent" end'
}

cmd_test_nodes() {
  local version run platforms word
  version="$(version_option "$@")"
  fetch
  platforms="$(git -C "$root" show refs/remotes/origin/main:ci/platforms.json | jq '.platforms | length')"
  run="$(gh run list --repo "$(repo)" --workflow release.yml --event workflow_dispatch --limit 50 \
    --json databaseId,displayTitle \
    --jq "[ .[] | select(.displayTitle == \"Test nodes $version\") ] | first | .databaseId // empty")" ||
    die "could not list the Release runs"
  if [ -z "$run" ]; then
    word=silent
  else
    word="$(gh run view "$run" --repo "$(repo)" --json status,jobs | test_nodes_verdict "$platforms")"
  fi
  echo "$word"
  case "$word" in
    passed) ;;
    failed) exit 1 ;;
    *) exit 75 ;;
  esac
}

# Moves candidate/<version> to <version> and lists it in index.json, in version order.
publish_candidate() {
  local version="$1" wt="$2"
  if jq -e --arg v "$version" 'any(.releases[]; .version == $v)' "$wt/index.json" >/dev/null; then
    return
  fi
  [ -f "$wt/candidate/$version/manifest.json" ] ||
    die "$version is not the candidate on $channel_branch; run candidate first"
  [ ! -e "$wt/$version" ] || die "$channel_branch already has $version/"
  mv "$wt/candidate/$version" "$wt/$version"
  rm -rf "$wt/candidate"
  jq --arg v "$version" '.releases = (.releases
      + [ { version: $v, manifest: "\($v)/manifest.json", signatures: "\($v)/manifest.sig.json" } ]
      | sort_by(.version | split(".") | map(tonumber)))' "$wt/index.json" >"$wt/index.json.next"
  mv "$wt/index.json.next" "$wt/index.json"
}

cmd_publish() {
  local version tag
  version="$(version_option "$@")"
  tag="v$version"
  fetch
  [ "$(release_state "$tag")" != absent ] || die "the release $tag is gone"
  channel_commit "Publish $version" publish_candidate "$version"
  gh release edit "$tag" --repo "$(repo)" --draft=false --prerelease=false --latest >/dev/null
  echo "release.sh: $tag is published and Latest" >&2
  echo "$tag"
}

# Clears candidate/ when it holds the version.
clear_candidate() {
  local version="$1" wt="$2"
  if [ -f "$wt/candidate/index.json" ] &&
    jq -e --arg v "$version" 'any(.releases[]; .version == $v)' "$wt/candidate/index.json" >/dev/null; then
    rm -rf "$wt/candidate"
  fi
}

cmd_drop() {
  local version tag err state
  version="$(version_option "$@")"
  tag="v$version"
  fetch
  err="$(mktemp "${TMPDIR:-/tmp}/release-drop.XXXXXX")"
  if state="$(gh release view "$tag" --repo "$(repo)" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' \
    2>"$err")"; then
    :
  elif grep -qi 'not found' "$err"; then
    state=absent
  else
    cat "$err" >&2
    rm -f "$err"
    die "could not read the release $tag"
  fi
  rm -f "$err"
  case "$state" in
    published)
      echo "release.sh: $tag is published, which only a recall undoes; nothing is dropped" >&2
      return
      ;;
    absent) echo "release.sh: there is no release $tag" >&2 ;;
    *)
      gh release delete "$tag" --repo "$(repo)" --yes >/dev/null || die "could not delete the release $tag"
      echo "release.sh: deleted the $state release $tag; the tag stays" >&2
      ;;
  esac
  local code=0
  git -C "$root" ls-remote --exit-code --heads origin "$channel_branch" >/dev/null 2>&1 || code=$?
  case "$code" in
    0) channel_commit "Drop the candidate $version" clear_candidate "$version" ;;
    2) ;;
    *) die "could not read the $channel_branch branch" ;;
  esac
}

# ---- the relay line ----

# The newest relay tag, and the newest relay tag on a commit.
newest_relay_tag() { newest_tag relay-v 'relay-v[0-9]*'; }
newest_relay_tag_at() { newest_tag relay-v --points-at "$1" 'relay-v[0-9]*'; }

relay_next_patch() {
  local newest major minor patch
  newest="$(newest_relay_tag)"
  if [ -z "$newest" ]; then
    echo 0.1.0
    return
  fi
  IFS=. read -r major minor patch <<<"${newest#relay-v}"
  echo "$major.$minor.$((patch + 1))"
}

# ci/relay-release-paths at a commit, one pathspec per line.
relay_paths_at() {
  git -C "$root" show "$1:ci/relay-release-paths" | grep -v -e '^#' -e '^[[:space:]]*$'
}

# relay/wrangler.jsonc at a commit with its "env" object and its comment lines removed: the part a
# bundle carries. The object is the one opened by `  "env": {` at the file's two-space indentation
# and closed by the next `  }` at that indentation. A file naming "env" some other way prints the
# whole file, so a layout this cannot read counts as moved, never as unmoved.
wrangler_top_level() {
  local text
  text="$(git -C "$root" show "$1:relay/wrangler.jsonc" 2>/dev/null)" || return 0
  if grep -q '^  "env": {$' <<<"$text"; then
    printf '%s\n' "$text" | awk '
      /^  "env": \{$/ { skip = 1; next }
      skip && /^  \},?$/ { skip = 0; next }
      skip { next }
      /^[[:space:]]*\/\// { next }
      { print }'
  else
    printf '%s\n' "$text"
  fi
}

# The relay release paths that moved between $1 and $2, one per line; relay/wrangler.jsonc only
# when its top level moved.
relay_moved() {
  local from="$1" to="$2" specs=() line
  while IFS= read -r line; do specs+=("$line"); done < <(relay_paths_at "$to")
  [ "${#specs[@]}" -gt 0 ] || die "ci/relay-release-paths at $to names no path"
  git -C "$root" diff --name-only "$from" "$to" -- "${specs[@]}" | while IFS= read -r line; do
    if [ "$line" = relay/wrangler.jsonc ] &&
      [ "$(wrangler_top_level "$from")" = "$(wrangler_top_level "$to")" ]; then
      echo "release.sh: relay/wrangler.jsonc moved only in its environments" >&2
      continue
    fi
    echo "$line"
  done
}

# Whether the relay line moved between its newest tag and $1: `changed` or `unchanged`.
relay_word() {
  local target="$1" newest moved
  newest="$(newest_relay_tag)"
  if [ -z "$newest" ]; then
    echo "release.sh: no relay tag yet" >&2
    echo changed
    return
  fi
  if ! git -C "$root" cat-file -e "$target:ci/relay-release-paths" 2>/dev/null; then
    echo "release.sh: $target has no ci/relay-release-paths" >&2
    echo changed
    return
  fi
  moved="$(relay_moved "$newest" "$target")"
  if [ -n "$moved" ]; then
    echo "release.sh: since $newest: $(printf '%s' "$moved" | tr '\n' ' ')" >&2
    echo changed
  else
    echo "release.sh: nothing a relay serves moved since $newest" >&2
    echo unchanged
  fi
}

sha_option() {
  local sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) [ $# -ge 2 ] || usage; sha="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  echo "$sha"
}

cmd_relay_changed() {
  local sha target
  sha="$(sha_option "$@")"
  fetch
  target="$(target_commit "$sha")"
  relay_word "$target"
}

cmd_relay_tag() {
  local sha target existing tag
  sha="$(sha_option "$@")"
  fetch
  target="$(target_commit "$sha")"
  existing="$(newest_relay_tag_at "$target")"
  if [ -n "$existing" ]; then
    echo "release.sh: origin/main $target is already $existing" >&2
    echo "$existing"
    return
  fi
  if [ "$(relay_word "$target")" != changed ]; then
    echo unchanged
    return
  fi
  tag="relay-v$(relay_next_patch)"
  git -C "$root" tag "$tag" "$target"
  git -C "$root" push --quiet origin "refs/tags/$tag" || {
    git -C "$root" tag -d "$tag" >/dev/null
    die "could not push $tag"
  }
  echo "release.sh: tagged origin/main $target as $tag; the Relay release workflow builds its draft" >&2
  echo "$tag"
}

cmd_relay() {
  [ $# -ge 1 ] || usage
  local sub="$1"
  shift
  case "$sub" in
    changed) cmd_relay_changed "$@" ;;
    tag) cmd_relay_tag "$@" ;;
    *) usage ;;
  esac
}

# Exits 75: the channel could not be read, which says nothing about the version.
unread() {
  echo "release.sh: $*" >&2
  exit 75
}

# Exits 1: the channel does not offer the version as a node would take it.
not_offered() {
  echo "release.sh: $*" >&2
  echo absent
  exit 1
}

# The channel's commit as origin holds it now, never made; nothing when there is no channel yet.
channel_read() {
  local code=0
  git -C "$root" ls-remote --exit-code --heads origin "$channel_branch" >/dev/null 2>&1 || code=$?
  case "$code" in
    0) ;;
    2) return ;;
    *) unread "could not read the $channel_branch branch" ;;
  esac
  git -C "$root" fetch --quiet --force origin \
    "refs/heads/$channel_branch:refs/remotes/origin/$channel_branch" ||
    unread "could not fetch the $channel_branch branch"
  git -C "$root" rev-parse "refs/remotes/origin/$channel_branch"
}

# Checks every artifact of the manifest in $1 against its size and sha256, fetched over https as a
# node fetches it, with the digestif-update $2.
artifacts_match() {
  local dir="$1" tool="$2" base url sum size got
  base="https://raw.githubusercontent.com/$(repo)/$channel_branch/"
  while IFS=$'\t' read -r url sum size; do
    case "$url" in
      http://* | https://*) ;;
      *) url="$base$url" ;;
    esac
    curl -fsSL --retry 2 -o "$dir/artifact" "$url" || unread "could not fetch $url"
    got="$("$tool" hash "$dir/artifact" | jq -r '"\(.sha256)\t\(.size)"')" ||
      unread "could not hash $url"
    [ "$got" = "$sum"$'\t'"$size" ] || not_offered "$url does not match its manifest"
    echo "release.sh: $url matches its manifest" >&2
  done < <(jq -r '.artifacts[] | [.url, .sha256, (.size | tostring)] | @tsv' "$dir/manifest.json")
}

cmd_channel() {
  local version="" head entry dir tool out
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      *) usage ;;
    esac
  done
  fetch
  head="$(channel_read)"
  if [ -z "$version" ]; then
    [ -n "$head" ] || {
      echo "release.sh: there is no $channel_branch branch yet" >&2
      return
    }
    git -C "$root" show "$head:index.json" |
      jq -r '[ .releases[].version ] | sort_by(split(".") | map(tonumber)) | last // empty'
    return
  fi
  valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
  [ -n "$head" ] || not_offered "there is no $channel_branch branch, so no node can take $version"
  entry="$(git -C "$root" show "$head:index.json" |
    jq -r --arg v "$version" 'first(.releases[] | select(.version == $v) | [.manifest, .signatures] | @tsv) // empty')"
  [ -n "$entry" ] || not_offered "the $channel_branch index.json does not list $version"
  scratch_dir
  dir="$scratch_path"
  git -C "$root" show "$head:${entry%%$'\t'*}" >"$dir/manifest.json" ||
    not_offered "the $channel_branch branch lacks ${entry%%$'\t'*}"
  git -C "$root" show "$head:${entry#*$'\t'}" >"$dir/manifest.sig.json" ||
    not_offered "the $channel_branch branch lacks ${entry#*$'\t'}"
  tool="$(update_tool "v$version" "$dir")" || unread "could not fetch a digestif-update to check $version with"
  if ! out="$("$tool" verify "$dir/manifest.json" "$dir/manifest.sig.json" --expect-version "$version" 2>&1)"; then
    printf '%s\n' "$out" >&2
    not_offered "the signatures of $version on $channel_branch do not verify"
  fi
  printf '%s\n' "$out" >&2
  artifacts_match "$dir" "$tool"
  echo "release.sh: $channel_branch offers $version, signed, every archive matching" >&2
  echo listed
}

# Publishing a relay release: the three steps are digestif-update's own (relay-publish), run with
# the newest published node release's copy, so a version under review never checks itself.
cmd_relay_publish() {
  local version tag tool code=0
  version="$(version_option "$@")"
  tag="relay-v$version"
  fetch
  git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || die "there is no tag $tag"
  scratch_dir
  tool="$(update_tool "$tag" "$scratch_path")"
  "$tool" relay-publish "$version" --repo "$(repo)" --branch "$channel_branch" || code=$?
  case "$code" in
    0) echo "$tag" ;;
    75) exit 75 ;;
    *) die "relay-publish of $tag failed" ;;
  esac
}

[ $# -ge 1 ] || usage
verb="$1"
shift
case "$verb" in
  build) cmd_build "$@" ;;
  changed) cmd_changed "$@" ;;
  signatures) cmd_signatures "$@" ;;
  candidate) cmd_candidate "$@" ;;
  test-nodes) cmd_test_nodes "$@" ;;
  publish) cmd_publish "$@" ;;
  channel) cmd_channel "$@" ;;
  drop) cmd_drop "$@" ;;
  relay) cmd_relay "$@" ;;
  relay-publish) cmd_relay_publish "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
