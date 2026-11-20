-- A send in flight (docs/protocol.md "Mailer routes", src/mail.ts): POST /v0/mail takes a lease on
-- the digest here before it calls Resend and writes mailed_digests only once Resend has accepted the
-- mail. A Worker that dies between the two leaves a lease that expires at claimed_until, so a later
-- request mails the digest instead of answering already_sent for mail that never went; Resend's
-- idempotency key (the digest hash) keeps that retry from sending a second copy of one that did.
-- holder names the request holding the lease, so a request whose lease was taken over drops only
-- its own.
CREATE TABLE mail_claims (
  digest TEXT PRIMARY KEY,
  holder TEXT NOT NULL,
  claimed_until TEXT NOT NULL
);
