# Governance

The node reads session directories and replaces its own binary, so who can ship code to it is the
point of the system. This file says who holds what. [docs/releases.md](docs/releases.md) is how the
node enforces it.

## Release signers

| Signer | Release key |
|---|---|
| Mike Bryzek | not yet published |
| Roman Cherkasov | not yet published |

A node installs only a release both signers signed. The keys a build trusts are in
[`node/update/release-signers.json`](node/update/release-signers.json); until both public keys are
there, a node installs no update. Each signer makes their key with `digestif-update keygen` and keeps
the secret off every machine that runs a node.

A member may pin a version (`digestif-update pin <version>`) and stay on it as long as they like.

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

## Accounts

| Account | Holder | Backup holder |
|---|---|---|
| First relay's Cloudflare account | Mike Bryzek | not yet named |
| The circle's domain | Mike Bryzek | not yet named |
| Mail API credentials for the digest mailer | Mike Bryzek | not yet named |
| Second relay's Cloudflare account | Roman Cherkasov | not yet named |
| This GitHub repository | Mike Bryzek | not yet named |

A holder names their backup holder here. The backup holder can reach the account if the holder
cannot, and the change to this file is the record that they agreed.

## The organization

The repo moves to a `digestif` organization on GitHub when the circle grows past the founders. The
release channel moves with it in a release both signers sign, so no node is left reading the old
address.
