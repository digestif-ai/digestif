// The lines of docs/protocol.md "Conformance cases", verbatim. Every case names the line it proves.
export const LINES = {
  divergent: "Divergent histories across two relays merge to the same fold and the same feed.",
  gap: "A relay missing a range: the node detects the gap by `seq` and backfills from the other relay.",
  duplicate: "Duplicate appends are idempotent; a fork is refused and surfaced.",
  sequence: "`seq` regression is refused for chained keys and allowed for mail keys.",
  revocation:
    "Revocation: appends from a revoked device are refused, and so is a revoke whose `after_seq` or `mail_read` is missing or names a key it does not stop; a node reads a revoked device's envelopes up to `after_seq` and a revoked mail key's that `mail_read` lists, and no others, whatever their `created_at`.",
  hostDeviceRevoke:
    "Host device revoke: the device key that wrote a dinner revokes an identity a join on that dinner admitted, within 7 days of the join; any other device key, a device key target, or a revoke after the window is refused.",
  clock: "Clock drift: a request skewed inside the window passes, outside fails; a replayed nonce fails.",
  bootstrap: "Bootstrap: a join from an unknown, spent or expired invite key is refused.",
  lostDevice:
    "Lost laptop: a `device` message authored by the new key itself is accepted when its identity signature verifies, and refused when it does not.",
  bootstrapRead:
    "Bootstrap read: an invite key reads the dinner that lists it; an unknown, spent or expired one, or a request signed by any other key, is not answered.",
  epoch: "Epoch: a newcomer fetches every circle-state envelope and no content from before their join.",
  releaseRevocation:
    "Release revocation: a relay serves it to every reader, a newcomer included, without checking its release signatures; a node records the key as revoked when a current release signer signed it and ignores it otherwise.",
  retract: "Retract: only the author's identity may retract; the body is dropped and the envelope verifies.",
  limits: "Limits: oversized envelopes and the 501st append in a day are refused.",
} as const;
