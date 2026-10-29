# Conformance

The cases every relay and node must pass: canonical encoding, hashing, request signing, the
admission fold, and the sequence and fork rules, as listed in
[docs/protocol.md](../docs/protocol.md). A relay is tested over its HTTP surface,
[spec/digestif-relay.json](../spec/digestif-relay.json), so the suite is the same for every
implementation.
