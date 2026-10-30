// The mailer routes (docs/protocol.md "Mailer routes", "Answer links") and the phone app route,
// against the Worker through SELF: a member with a mail key writes an ask and a digest as the node
// does (test/helpers.ts), asks the relay to mail it, and answers from the links in the email the
// fake Resend endpoint received. Conformance cases cannot cover these routes black-box (a real
// relay would email, and the suite cannot hold the relay's sealing key), so this file is their
// test.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { jcs } from "../../conformance/src/encoding.ts";
import { envelopeHash, type SignedEnvelope, type StoredEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import type { HttpResult, SignOptions } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import vectors from "../../node/mail/test/vectors.json";
import { unb64url } from "../../node/mail/webcrypto/mail.mjs";
import type { Author } from "../../conformance/src/envelope.ts";
import { circleEpoch, foldLog, keyJson, loadKeys } from "../src/db.ts";
import { DEFAULT_LIMITS } from "../src/env.ts";
import { confirmLink } from "../src/links.ts";
import { countRows, dumpTables, FakeResend, Node, RELAY, type AskSpec, type Digest } from "./helpers.ts";

const resend = new FakeResend();
let world: World;
let mike: Member;
let ada: Member;
let mailKey: Author;
let node: Node;
const relayKey = unb64url(vectors.seal.recipients[0]!.public);
const memberKey = unb64url(vectors.seal.recipients[1]!.public);
const otherKey = unb64url(vectors.link.member.public);

const INTRO: AskSpec = {
  title: "Introduce Phong to Andrey?",
  detail: "Phong's agent asked for an intro about eval harnesses.",
  options: [
    { id: "yes", label: "Make the intro", recommended: true },
    { id: "no", label: "Decline" },
  ],
  on_no_answer: "no",
  lapses_at: new Date(Date.now() + 3 * 24 * 3600 * 1000).toISOString(),
};

function post(signer: Author | Member, body: string, options: SignOptions = {}): Promise<HttpResult> {
  const author = "device" in signer ? signer.device : signer;
  return world.client(RELAY, author).send("POST", "/v0/mail", body, options);
}

async function mailed(): Promise<number> {
  return countRows(env.DB, "mailed_digests");
}

async function decisionsHeld(): Promise<StoredEnvelope[]> {
  const all = await world.client(RELAY, mike.device).fetchAll();
  return all.filter((s) => s.envelope.kind === "decision");
}

async function checkRefold(): Promise<void> {
  const fold = await foldLog(env.DB, env.CIRCLE_ROOT, { all: true });
  expect((await loadKeys(env.DB)).map(keyJson)).toEqual(fold.admittedKeys().map(keyJson));
  expect(await circleEpoch(env.DB)).toBe(fold.epoch);
}

function linkUrlOf(digest: Digest, label: string): string {
  const link = digest.links.find((l) => l.label === label);
  if (link === undefined) throw new Error(`no link ${label}`);
  return `${RELAY}/v0/links/${link.id}?s=${link.secret}`;
}

async function confirm(url: string, secret?: string): Promise<string> {
  const target = new URL(url);
  const s = secret ?? target.searchParams.get("s") ?? "";
  const response = await SELF.fetch(`${RELAY}${target.pathname}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ s }).toString(),
  });
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
  return response.text();
}

async function page(url: string): Promise<string> {
  const response = await SELF.fetch(url);
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
  return response.text();
}

beforeAll(async () => {
  resend.install();
  const circle = {
    hostIdentity: Signer.fromSeed(circleFile.host_identity_seed),
    hostDevice: Signer.fromSeed(circleFile.host_device_seed),
    root: circleFile.root as SignedEnvelope,
    rootHash: circleFile.root_hash,
  };
  world = new World(circle, [RELAY]);
  await world.setup();
  [mike, ada] = (await world.members(["mike", "ada"])) as [Member, Member];
  mailKey = await world.addDevice(mike, "mail");
  node = new Node(world, mike.device, memberKey, relayKey);
});

afterAll(() => {
  resend.uninstall();
});

describe("POST /v0/mail", () => {
  it("refuses an unsigned request, answers unknown_digest to another member's device, and refuses the mail key", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    const body = await node.mailRequest(digest);
    const unsigned = await post(mike, body, { unsigned: true });
    expect(unsigned.status).toBe(401);
    expect(unsigned.body).toMatchObject({ code: "not_admitted" });
    // Another identity's device: the same answer as a digest the relay does not hold, so the route
    // says nothing about digests the caller did not write.
    const other = await post(ada, body);
    expect(other.status).toBe(404);
    expect(other.body).toMatchObject({ code: "unknown_digest" });
    const byMailKey = await post(mailKey, body);
    expect(byMailKey.status).toBe(401);
    expect(byMailKey.body).toMatchObject({ code: "not_admitted" });
    expect(resend.sent).toHaveLength(0);
    expect(await mailed()).toBe(0);
  });

  it("answers 422 malformed to a body that is not a mail request", async () => {
    for (const body of ["{", "[]", JSON.stringify({ digest: "sha256:00" }), JSON.stringify({ digest: 1, sealed: {} })]) {
      const result = await post(mike, body);
      expect(result.status, body).toBe(422);
      expect(result.body).toEqual([expect.objectContaining({ code: "malformed" })]);
    }
  });

  it("answers 404 unknown_digest for a hash it does not hold, or holds as something else", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    const request = JSON.parse(await node.mailRequest(digest)) as { digest: string; sealed: unknown };
    for (const hash of [`sha256:${"0".repeat(64)}`, ask]) {
      const result = await post(mike, jcs({ ...request, digest: hash }));
      expect(result.status, hash).toBe(404);
      expect(result.body).toMatchObject({ code: "unknown_digest" });
    }
  });

  it("answers 422 to a request or a digest the relay's key cannot open", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    const wrongRequest = await post(mike, await node.mailRequest(digest, memberKey));
    expect(wrongRequest.status).toBe(422);
    expect(wrongRequest.text).toContain("not sealed to this relay's key");
    const sealedAway = await node.digest([{ hash: ask, spec: INTRO }], { mailKey, recipients: [memberKey] });
    const wrongDigest = await post(mike, await node.mailRequest(sealedAway));
    expect(wrongDigest.status).toBe(422);
    expect(wrongDigest.text).toContain("the digest is not sealed");
    expect(resend.sent).toHaveLength(0);
    expect(await mailed()).toBe(0);
  });

  it("mails the digest once, with a link per option, and keeps no secret, request or plaintext", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey, subject: "Digestif, October 29: 1 ask", to: "mike@example.com" });
    const body = await node.mailRequest(digest);
    const sent = await post(mike, body);
    expect(sent.status, sent.text).toBe(202);
    expect(sent.body).toEqual({ status: "sent", digest: digest.hash });
    expect(resend.sent).toHaveLength(1);
    const mail = resend.sent[0]!;
    expect(mail.authorization).toBe(`Bearer ${env.RESEND_API_KEY}`);
    expect(mail.body.from).toBe("Digestif <digest@mail.digestif.io>");
    expect(mail.body.to).toEqual(["mike@example.com"]);
    expect(mail.body.subject).toBe("Digestif, October 29: 1 ask");
    for (const label of ["Make the intro", "Decline"]) {
      expect(mail.body.text).toContain(linkUrlOf(digest, label));
      expect(mail.body.html).toContain(linkUrlOf(digest, label).replace(/&/g, "&amp;"));
    }
    expect(mail.body.text).toContain("Make the intro (recommended)");
    expect(mail.body.text).toContain("Roman (Ada): shipped the D1 fold.");

    const again = await post(mike, body);
    expect(again.status).toBe(200);
    expect(again.body).toEqual({ status: "already_sent", digest: digest.hash });
    expect(resend.sent).toHaveLength(1);

    expect(await countRows(env.DB, "mailed_digests", "digest = ?", digest.hash)).toBe(1);
    expect(await countRows(env.DB, "links", "digest = ? AND ask = ? AND used_at IS NULL", digest.hash, ask)).toBe(2);
    const tables = await dumpTables(env.DB);
    for (const link of digest.links) expect(tables).not.toContain(link.secret);
    for (const leak of ["mike@example.com", "Digestif, October 29", "Make the intro", "Introduce Phong", "shipped the D1 fold", "/v0/links/"]) {
      expect(tables, leak).not.toContain(leak);
    }
    expect(tables).not.toContain(env.RESEND_API_KEY);
  });

  it("drops its claim when the mail service refuses, so a retry mails", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    const body = await node.mailRequest(digest);
    resend.status = 500;
    const failed = await post(mike, body);
    resend.status = 200;
    expect(failed.status).toBe(502);
    expect(failed.body).toMatchObject({ code: "mail_failed" });
    expect(await countRows(env.DB, "mailed_digests", "digest = ?", digest.hash)).toBe(0);
    expect(await countRows(env.DB, "links", "digest = ?", digest.hash)).toBe(0);
    const retried = await post(mike, body);
    expect(retried.status).toBe(202);
    expect(await countRows(env.DB, "links", "digest = ?", digest.hash)).toBe(2);
  });
});

describe("GET /v0/links/:id", () => {
  let digest: Digest;
  let ask: string;

  beforeAll(async () => {
    ask = await node.ask(INTRO);
    digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
  });

  it("renders the confirm page naming the ask and the option, and changes nothing", async () => {
    const url = linkUrlOf(digest, "Make the intro");
    const before = { envelopes: await countRows(env.DB, "envelopes"), tables: await dumpTables(env.DB) };
    const first = await page(url);
    const second = await page(url);
    expect(second).toBe(first);
    expect(first).toContain("Introduce Phong to Andrey?");
    expect(first).toContain("Make the intro");
    expect(first).toContain(`<form method="post" action="/v0/links/${new URL(url).pathname.split("/").pop()!}">`);
    expect(first).toContain(`name="s" value="${new URL(url).searchParams.get("s")!}"`);
    expect(first).toContain(">Confirm<");
    expect(await countRows(env.DB, "envelopes")).toBe(before.envelopes);
    expect(await dumpTables(env.DB)).toBe(before.tables);
    expect(await decisionsHeld()).toHaveLength(0);
  });

  it("renders a page for an unknown link, a wrong secret and a missing one", async () => {
    const url = new URL(linkUrlOf(digest, "Decline"));
    expect(await page(`${RELAY}/v0/links/${"A".repeat(22)}?s=${url.searchParams.get("s")!}`)).toContain("Unknown link");
    expect(await page(`${RELAY}${url.pathname}?s=${"B".repeat(43)}`)).toContain("Link incomplete");
    expect(await page(`${RELAY}${url.pathname}?s=not*base64url`)).toContain("Link incomplete");
    expect(await page(`${RELAY}${url.pathname}`)).toContain("Link incomplete");
    expect(await page(`${RELAY}${url.pathname}?s=${url.searchParams.get("s")!}`)).toContain(">Confirm<");
  });

  it("renders the expired page for a link past its expiry", async () => {
    const lapsed: AskSpec = { ...INTRO, title: "A lapsed ask", lapses_at: new Date(Date.now() - 60_000).toISOString() };
    const hash = await node.ask(lapsed);
    const old = await node.digest([{ hash, spec: lapsed }], { mailKey });
    expect((await post(mike, await node.mailRequest(old))).status).toBe(202);
    expect(await page(linkUrlOf(old, "Decline"))).toContain("Link expired");
    expect(await confirm(linkUrlOf(old, "Decline"))).toContain("Link expired");
    expect(await decisionsHeld()).toHaveLength(0);
  });
});

describe("POST /v0/links/:id", () => {
  it("appends the decision, marks every link of the ask used, and renders the done page", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
    const decisionsBefore = (await decisionsHeld()).length;
    const yes = linkUrlOf(digest, "Make the intro");
    const done = await confirm(yes);
    expect(done).toContain("Your answer went in");
    expect(done).toContain("Make the intro");
    expect(done).toContain("Introduce Phong to Andrey?");
    const decisions = await decisionsHeld();
    expect(decisions).toHaveLength(decisionsBefore + 1);
    const appended = decisions[decisions.length - 1]!;
    expect(appended.envelope.author).toBe(mailKey.key);
    expect(appended.envelope.prev).toBe(ask);
    expect(appended.body).toMatchObject({ ask });
    await checkRefold();
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NOT NULL", ask)).toBe(2);
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NULL", ask)).toBe(0);

    // Single use: the other option's link, and the same one again, answer the used page and append nothing.
    expect(await page(linkUrlOf(digest, "Decline"))).toContain("Already answered");
    expect(await confirm(linkUrlOf(digest, "Decline"))).toContain("Already answered");
    expect(await confirm(yes)).toContain("Already answered");
    expect(await decisionsHeld()).toHaveLength(decisionsBefore + 1);
    const tables = await dumpTables(env.DB);
    for (const link of digest.links) expect(tables).not.toContain(link.secret);
  });

  it("refuses a wrong secret and a form without one, appending nothing", async () => {
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
    const before = (await decisionsHeld()).length;
    expect(await confirm(linkUrlOf(digest, "Decline"), "C".repeat(43))).toContain("Link incomplete");
    expect(await confirm(linkUrlOf(digest, "Decline"), "")).toContain("Link incomplete");
    expect(await confirm(`${RELAY}/v0/links/${"D".repeat(22)}?s=x`)).toContain("Unknown link");
    expect(await decisionsHeld()).toHaveLength(before);
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NULL", ask)).toBe(2);
  });

  it("refuses a decision signed by a key that is not an admitted mail key of the author's identity", async () => {
    const ask = await node.ask(INTRO);
    const stranger = Signer.random();
    const forged = await node.digest([{ hash: ask, spec: INTRO }], { mailKey: stranger });
    expect((await post(mike, await node.mailRequest(forged))).status).toBe(202);
    const before = (await decisionsHeld()).length;
    expect(await page(linkUrlOf(forged, "Decline"))).toContain(">Confirm<");
    expect(await confirm(linkUrlOf(forged, "Decline"))).toContain("Answer refused");
    expect(await decisionsHeld()).toHaveLength(before);
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NULL", ask)).toBe(2);

    // Another member's mail key is admitted, but not of the digest author's identity.
    const adaMail = await world.addDevice(ada, "mail");
    const adas = await node.digest([{ hash: ask, spec: INTRO }], { mailKey: adaMail });
    expect((await post(mike, await node.mailRequest(adas))).status).toBe(202);
    expect(await confirm(linkUrlOf(adas, "Decline"))).toContain("Answer refused");
    expect(await decisionsHeld()).toHaveLength(before);
  });

  it("refuses a decision whose prev is not the link's ask", async () => {
    const ask = await node.ask(INTRO);
    const other = await node.ask({ ...INTRO, title: "Another ask" });
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey, prevOf: () => other });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
    const before = (await decisionsHeld()).length;
    expect(await confirm(linkUrlOf(digest, "Make the intro"))).toContain("different ask");
    expect(await decisionsHeld()).toHaveLength(before);
  });

  it("renders the refused page when the chain rules refuse the decision (a fork on the mail key's seq)", async () => {
    const first = await node.ask(INTRO);
    const second = await node.ask({ ...INTRO, title: "A second ask" });
    const seq = node.nextMailSeq();
    const a = await node.digest([{ hash: first, spec: INTRO }], { mailKey, seqOf: () => seq });
    const b = await node.digest([{ hash: second, spec: { ...INTRO, title: "A second ask" } }], { mailKey, seqOf: () => seq });
    expect((await post(mike, await node.mailRequest(a))).status).toBe(202);
    expect((await post(mike, await node.mailRequest(b))).status).toBe(202);
    const before = (await decisionsHeld()).length;
    expect(await confirm(linkUrlOf(a, "Decline"))).toContain("Your answer went in");
    const refused = await confirm(linkUrlOf(b, "Decline"));
    expect(refused).toContain("Answer refused");
    expect(refused).toContain("fork");
    expect(await decisionsHeld()).toHaveLength(before + 1);
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NULL", second)).toBe(2);
    await checkRefold();
  });

  it("refuses a decision from a mail key revoked since the digest was mailed", async () => {
    const [bo] = (await world.members(["bo"])) as [Member];
    const boMail = await world.addDevice(bo, "mail");
    const boNode = new Node(world, bo.device, otherKey, relayKey);
    const ask = await boNode.ask(INTRO);
    const digest = await boNode.digest([{ hash: ask, spec: INTRO }], { mailKey: boMail });
    expect((await post(bo, await boNode.mailRequest(digest))).status).toBe(202);
    const revoke = await world.revoke(bo.device, bo.identity, boMail.key, [], RELAY, undefined, { [boMail.key]: [] });
    await world.publish([RELAY], bo.device, revoke);
    const before = (await decisionsHeld()).length;
    expect(await confirm(linkUrlOf(digest, "Make the intro"))).toContain("not_admitted");
    expect(await decisionsHeld()).toHaveLength(before);
  });
  it("appends one decision when two links of one ask are confirmed at once", async () => {
    // miniflare serializes D1 through SELF.fetch, so the race is staged at the unit level (as in
    // race.test.ts): the "Decline" confirm runs to completion just before the "Make the intro"
    // confirm's write batch. The mail key is chainless, so only the links' single use stops the
    // second decision; it must be in the same transaction as the append.
    const ask = await node.ask(INTRO);
    const digest = await node.digest([{ hash: ask, spec: INTRO }], { mailKey });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
    const before = (await decisionsHeld()).length;
    let fired = false;
    const real = env.DB;
    const db = new Proxy(real, {
      get(target, property) {
        if (property === "batch") {
          return async (statements: D1PreparedStatement[]) => {
            if (!fired) {
              fired = true;
              expect(await confirm(linkUrlOf(digest, "Decline"))).toContain("Your answer went in");
            }
            return target.batch(statements);
          };
        }
        const value = Reflect.get(target, property, target) as unknown;
        return typeof value === "function" ? (value as (...a: unknown[]) => unknown).bind(target) : value;
      },
    });
    const yes = new URL(linkUrlOf(digest, "Make the intro"));
    const request = new Request(`${RELAY}${yes.pathname}`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ s: yes.searchParams.get("s")! }).toString(),
    });
    const relay = { db, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now: new Date(), mailer: undefined };
    const response = await confirmLink(relay, request, yes, yes.pathname.split("/").pop()!);
    expect(fired).toBe(true);
    expect(await response.text()).toContain("Already answered");
    const decisions = (await decisionsHeld()).filter((d) => d.envelope.prev === ask);
    expect(decisions).toHaveLength(1);
    expect((await decisionsHeld()).length).toBe(before + 1);
    expect(await countRows(env.DB, "links", "ask = ? AND used_at IS NULL", ask)).toBe(0);
    await checkRefold();
  });

  it("escapes the ask title and the option label on the confirm and done pages", async () => {
    const hostile: AskSpec = {
      ...INTRO,
      title: `<script>alert("title")</script>`,
      options: [
        { id: "yes", label: `<img src=x onerror="alert('label')">`, recommended: true },
        { id: "no", label: "Decline" },
      ],
    };
    const ask = await node.ask(hostile);
    const digest = await node.digest([{ hash: ask, spec: hostile }], { mailKey });
    expect((await post(mike, await node.mailRequest(digest))).status).toBe(202);
    const url = linkUrlOf(digest, hostile.options[0]!.label);
    for (const html of [await page(url), await confirm(url)]) {
      expect(html).not.toContain("<script");
      expect(html).not.toContain("<img");
      expect(html).toContain("&lt;script&gt;alert(&quot;title&quot;)&lt;/script&gt;");
      expect(html).toContain("&lt;img src=x onerror=&quot;alert(&#39;label&#39;)&quot;&gt;");
      expect(html).not.toMatch(/(src|href)=["']?(https?:)?\/\//);
      expect(html).not.toContain("<link");
    }
  });
});

describe("/app/", () => {
  it("serves the phone app's index and falls back to it for any path under /app/", async () => {
    const index = await SELF.fetch(`${RELAY}/app/`);
    expect(index.status).toBe(200);
    expect(index.headers.get("content-type")).toContain("text/html");
    const html = await index.text();
    expect(html).toContain("Digestif");
    const direct = await SELF.fetch(`${RELAY}/app/index.html`);
    expect(direct.status).toBe(200);
    expect(await direct.text()).toBe(html);
    for (const path of ["/app/asks", "/app/asks/sha256:abc", "/app/missing.js?x=1"]) {
      const response = await SELF.fetch(`${RELAY}${path}`);
      expect(response.status, path).toBe(200);
      expect(response.headers.get("content-type"), path).toContain("text/html");
      expect(await response.text(), path).toBe(html);
    }
  });

  it("redirects /app to /app/ and answers 404 to a method the app does not take", async () => {
    const bare = await SELF.fetch(`${RELAY}/app`, { redirect: "manual" });
    expect(bare.status).toBe(302);
    expect(bare.headers.get("location")).toBe(`${RELAY}/app/`);
    const posted = await SELF.fetch(`${RELAY}/app/`, { method: "POST" });
    expect(posted.status).toBe(404);
    expect(await posted.json()).toMatchObject({ code: "malformed" });
  });
});

describe("the digest hash", () => {
  it("is the hash the node computes", () => {
    expect(envelopeHash((circleFile.root as SignedEnvelope).envelope)).toBe(circleFile.root_hash);
  });
});
