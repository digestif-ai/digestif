# The Digestif release channel

What every node reads to decide what to install: `index.json`, the release list of the seven newest
published versions (plus the newest no recall takes out, when it is older), and the revocations,
recalls and signer-set changes it names. Each version's manifest and signatures are read from its
GitHub release. Written only by `ci/release.sh publish` and by a signer's `digestif-update recall`,
`revoke` and `sign --next`; see `docs/releases.md`, The channel.
