-- D1 only: what spans the circles a relay hosts (docs/protocol.md "Hosted circles", src/circles.ts).
-- Each circle's own state lives in its store (src/store.ts), which never applies this migration
-- (scripts/schema.ts leaves out a migration whose first line is this marker). The home circle's
-- tables of 0001-0005 stay here, serving it until its log has moved into its store.

-- One row per circle the relay hosts. vouched_by and vouched_identity name the circle and the member
-- whose voucher opened it (NULL for the home circle, which needs none); state is open or suspended,
-- set by the operator; store is where the circle's state lives: d1 (the home circle's tables here,
-- not moving), moving (still here, its log being copied into its store), draining (still here,
-- appends refused while the copy finishes) or object (its store). size and last_append_at are what
-- the circle's store last reported, for the operator's list.
CREATE TABLE hosted_circles (
  root TEXT PRIMARY KEY,
  opened_at TEXT NOT NULL,
  vouched_by TEXT,
  vouched_identity TEXT,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'suspended')),
  state_changed_at TEXT NOT NULL,
  store TEXT NOT NULL DEFAULT 'object' CHECK (store IN ('d1', 'moving', 'draining', 'object')),
  size INTEGER NOT NULL DEFAULT 0,
  last_append_at TEXT
);

-- The per-member founding limit counts the circles one member opened in the last 30 days.
CREATE INDEX hosted_circles_vouched ON hosted_circles (vouched_by, vouched_identity, opened_at);

-- Each open invite key and the circle whose dinner or root lists it: the relay's own bootstrap read,
-- GET /v0/invites/<invite key>, answers from here across every hosted circle.
CREATE TABLE invite_index (
  key TEXT PRIMARY KEY,
  root TEXT NOT NULL
);

-- The relay's own state: the last request on an unprefixed circle route, which GET /v0/relay
-- reports so the release that drops those routes waits until no node uses them.
CREATE TABLE relay_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_unprefixed_at TEXT
);

-- Once the home circle's copy is draining or done, nothing more lands in its tables here: an
-- append, a mailed link or a mailed digest that reaches them aborts, and the relay answers it
-- 503 moving, so the copy never misses a row written after it read the log.
CREATE TRIGGER home_moved_envelopes BEFORE INSERT ON envelopes
WHEN EXISTS (SELECT 1 FROM hosted_circles h JOIN circle c ON c.root = h.root WHERE c.id = 1 AND h.store IN ('draining', 'object'))
BEGIN
  SELECT RAISE(ABORT, 'circle_moving');
END;

CREATE TRIGGER home_moved_links BEFORE INSERT ON links
WHEN EXISTS (SELECT 1 FROM hosted_circles h JOIN circle c ON c.root = h.root WHERE c.id = 1 AND h.store IN ('draining', 'object'))
BEGIN
  SELECT RAISE(ABORT, 'circle_moving');
END;

CREATE TRIGGER home_moved_mailed BEFORE INSERT ON mailed_digests
WHEN EXISTS (SELECT 1 FROM hosted_circles h JOIN circle c ON c.root = h.root WHERE c.id = 1 AND h.store IN ('draining', 'object'))
BEGIN
  SELECT RAISE(ABORT, 'circle_moving');
END;
