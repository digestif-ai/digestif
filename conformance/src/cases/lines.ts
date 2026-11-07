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
  pushedJoin:
    "Pushed join: a join an admitted, unrevoked key pushes is judged by its `created_at`, so it is accepted after its invite's expiry when it was created before it; one created after it, or pushed by a revoked key, is refused. A node admitted on a relay pushes it the joins another relay accepted and it lacks, with their members' self-authored `device` messages.",
  lostDevice:
    "Lost laptop: a `device` message authored by the new key itself is accepted when its identity signature verifies, and refused when it does not.",
  bootstrapRead:
    "Bootstrap read: an invite key reads the dinner that lists it; an unknown, spent or expired one, or a request signed by any other key, is not answered.",
  epoch: "Epoch: a newcomer fetches every circle-state envelope and no content from before their join.",
  releaseRevocation:
    "Release revocation: a relay serves it to every reader, a newcomer included, without checking its release signatures; a node records the key as revoked when a current release signer signed it and ignores it otherwise.",
  releaseRecall:
    "Release recall: a relay serves it to every reader, a newcomer included, without checking its release signatures; a node counts it only while a current, unrevoked release signer's signature on it verifies.",
  relayRelease:
    "Relay release: a relay serves it to every reader, a newcomer included, without checking its release signatures, and refuses one without a `document` and a `signatures` list.",
  prompt:
    "Prompt: a relay serves it to every reader, a newcomer included, and refuses one whose `suggestion` and `text` are not strings.",
  relayVersion:
    "Relay version: `GET /v0/circle` and an unsigned `GET /v0/version` report the same `relay_version`, a `MAJOR.MINOR.PATCH` string on a stamped relay and no field at all on an unstamped one.",
  items:
    "Items: a relay accepts an `item`, an `item_answer` and an `item_close` from an admitted author as content, checking only the envelope, and serves each, its body intact, to a reader admitted before it.",
  denyList:
    "Deny list: a relay accepts a `deny_list` from an admitted device as content, checking only the envelope, and serves it, its sealed body intact, to another device of the same member.",
  retract: "Retract: only the author's identity may retract; the body is dropped and the envelope verifies.",
  limits: "Limits: oversized envelopes and the 501st append in a day are refused.",
} as const;
