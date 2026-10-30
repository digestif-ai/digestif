-- The mailer's state (docs/protocol.md "Mailer routes"), additive to 0001. Nothing here holds a
-- mail request, a link secret or a digest's plaintext: the relay reads those, mails and forgets.

-- Digests this relay has mailed, so a second POST /v0/mail answers already_sent and mails nothing.
CREATE TABLE mailed_digests (
  digest TEXT PRIMARY KEY,
  sent_at TEXT NOT NULL
);

-- The links of every mailed digest, by id: which digest and ask each belongs to and when it
-- expires, so GET and POST /v0/links/:id find the sealed answer in the digest's body. used_at is
-- set on every link of an ask when one of them is confirmed.
CREATE TABLE links (
  id TEXT PRIMARY KEY,
  digest TEXT NOT NULL,
  ask TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT
);
CREATE INDEX links_ask ON links (ask);
