-- The clock the admission fold judged an envelope at, when it is not received_at (docs/protocol.md,
-- The admission fold): a join an admitted member's device pushed is judged by its created_at, so
-- a refold replays it at that clock. NULL for every other envelope, which was judged at arrival.
ALTER TABLE envelopes ADD COLUMN judged_at TEXT;
