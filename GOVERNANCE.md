# Governance

The node reads session directories and replaces its own binary, so who can ship code to it is the
point of the system. This file says who holds what. [docs/releases.md](docs/releases.md) is how the
node enforces it.

## Release signers

| Signer | Release key |
|---|---|
| Mike Bryzek | `ed25519:UiEqBPmT4YLMOyovbJQ-W9jWTXWnQAGC-upBMVFImNY` |
| Roman Cherkasov | `ed25519:SMohOr7p4WGpjoRKamyBmclyzqxy6ajrh9w4iRQ_OSI` |

A node installs only a release both signers signed. The keys a build trusts are in
[`node/update/release-signers.json`](node/update/release-signers.json); until both public keys are
there, a node installs no update. Each signer makes their key with `digestif-update keygen` and keeps
the secret off every machine that runs a node.

A member may pin a version (`digestif update pin <version>`) and stay on it as long as they like.

## Disagreement

Either signer can halt every update by not signing. A dispute is raised as an issue on this repo and
settled by the founding circle. Until it is settled, nodes stay on the last release both signed.

## Replacing a signer

A signer is replaced by a release that names the new signer set, signed by both current signers and
by every key in the new set. The node accepts nothing else as a change of signers.

## A compromised release key

1. The other signer publishes a revocation of the key, signed with their own release key, in
   `releases/revocations/` and on the circle.
2. Nodes refuse every ordinary release while the revoked key is in the set.
3. The two parties sign a release naming a new key set without the revoked key; that release clears
   the halt. A revoked key never returns to a signer set.

A key that is lost rather than leaked cannot sign the replacement. Recovery is then a fresh install
of a build carrying the new set, announced on this repo and on the circle.

## A recall

Either signer can recall a published version alone, with `digestif-update recall <version> --reason
"..."` ([docs/releases.md](docs/releases.md), A recall). It is the one act a single signer takes for
members: nodes refuse the version, and a node that installed it within the past week moves back to
the newest older release on its disk. The next version both sign is the way forward. A recall both
signers signed has no week's limit.

What one key can do with it, in plain words: make nodes refuse a version they have not installed,
which withholding a signature already does; and send nodes back from a version they installed in the
past week, to older code both signers signed, which could undo a fix shipped in that week until the
key is removed. It cannot move a node off a version it has run for more than a week, cannot ship
anything, and cannot take a node to anything that lacks both signatures. A recall counts only while
its signer's key is in the set and unrevoked, so a stolen key's recalls end with the revocation and
the signer-set change above.

## Accounts

| Account | Holder | Backup holder |
|---|---|---|
| First relay's Cloudflare account ("Digestif") | Mike Bryzek | Andrey Kartashov |
| The circle's domain, `digestif.io` (Cloudflare Registrar, same account) | Mike Bryzek | Andrey Kartashov |
| Mail API (Resend, its own account) for the digest mailer | Mike Bryzek | Andrey Kartashov |
| Second relay's Cloudflare account | Roman Cherkasov | not yet named |
| The `digestif-ai` GitHub organization and this repository | Mike Bryzek | Roman Cherkasov (second owner) |

A holder names their backup holder here. The backup holder can reach the account if the holder
cannot, and the change to this file is the record that they agreed.

## The organization

The repo lives in the `digestif-ai` organization on GitHub, at
[github.com/digestif-ai/digestif](https://github.com/digestif-ai/digestif). Nodes read the release
channel from that address, so none depends on GitHub's redirect from an earlier one.
