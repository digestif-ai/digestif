-- The admission cutover (docs/protocol.md, The admission fold): the relay_id of the circle's head
-- when this relay took the rule that a dinner's guest counts only with an admission every release
-- signer signed. A dinner at or before it admits by its guests' invite keys alone, as it did when it
-- was appended; one after it needs the signed admission. A database that already serves a circle
-- records its head now; a fresh one starts at 0, so the rule holds from its first dinner after the
-- root.
ALTER TABLE circle ADD COLUMN admission_cutover INTEGER NOT NULL DEFAULT 0;
UPDATE circle SET admission_cutover = (SELECT COALESCE(MAX(relay_id), 0) FROM envelopes) WHERE id = 1;
