-- The item a decision answers, indexed for the answer-link pages (src/links.ts, answeredElsewhere):
-- without it every link page view reads every decision's body to find one item. Partial on kind, so
-- the index holds decisions alone. DIG-234
CREATE INDEX envelopes_decision_item ON envelopes (json_extract(body, '$.item')) WHERE kind = 'decision';
