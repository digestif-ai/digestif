-- The relay's log and the state derived from it. The log is `envelopes`; everything else is a
-- fold over it that a full refold must reproduce (relay/test/conformance.test.ts checks that).

-- One row per database: the circle root this database serves and the epoch its fold has reached.
-- Written on first use from the Worker's CIRCLE_ROOT; a database whose root differs from the
-- Worker's configuration is refused rather than mixed.
CREATE TABLE circle (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  root TEXT NOT NULL,
  epoch INTEGER NOT NULL DEFAULT 0
);

-- The append-only log, in relay order. relay_id is the cursor GET /v0/envelopes pages by and the
-- fold position admitted_at and revoked_at name. body is NULL once a retract dropped it.
CREATE TABLE envelopes (
  relay_id INTEGER PRIMARY KEY AUTOINCREMENT,
  hash TEXT NOT NULL UNIQUE,
  author TEXT NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  envelope TEXT NOT NULL,
  body TEXT
);
CREATE INDEX envelopes_author_seq ON envelopes (author, seq);
CREATE INDEX envelopes_kind_relay_id ON envelopes (kind, relay_id);

-- The admission fold's output: one row per key the fold has seen, as GET /v0/circle reports it.
-- mail_read is a JSON array of envelope hashes for a revoked mail key, NULL otherwise.
CREATE TABLE admitted_keys (
  key TEXT PRIMARY KEY,
  role TEXT NOT NULL,
  identity TEXT NOT NULL,
  admitted_at INTEGER NOT NULL,
  join_epoch INTEGER NOT NULL,
  revoked_at INTEGER,
  after_seq INTEGER,
  mail_read TEXT
);

-- Invite keys the fold has recorded from dinners: the first dinner listing a key wins, and a join
-- by the key spends it. The bootstrap read answers from here.
CREATE TABLE invites (
  key TEXT PRIMARY KEY,
  dinner TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  spent INTEGER NOT NULL DEFAULT 0
);

-- Request nonces seen per signing key, kept until the skew window has passed them.
CREATE TABLE nonces (
  key TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (key, nonce)
);
CREATE INDEX nonces_expires_at ON nonces (expires_at);

-- Accepted appends per author per UTC day, for the daily cap.
CREATE TABLE daily_appends (
  author TEXT NOT NULL,
  day TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (author, day)
);
