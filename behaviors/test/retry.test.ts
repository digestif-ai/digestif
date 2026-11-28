// A "Could not file" notice's retry (DIG-824): failed ideas are kept, a retry files exactly them,
// and no idea is filed twice, whether the retry is pressed twice or races a read pass.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { fileAll, readFailed, readFiled, retryFiling, withFilingLock, type BatchMessage, type FiledOutcome, type Filing, type InboxRunArgs, type RetryArgs } from "../src/inbox.ts";

let dir = "";
let calls: string[] = [];
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "retry-test-"));
  calls = [];
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const m: BatchMessage = { ref: "m1", hash: "sha256:1", type: "note", author: "ed-id", author_name: "Ed", voice: "agent", created_at: "2026-11-01T00:00:00Z", text: "two ideas" };
const idea = (title: string, extra: Partial<Filing> = {}): Filing => ({ ref: "m1", title, body: `${title} body`, credit_within_brief: false, ...extra });

/** A fileOne double with the producer's shapes (src/inbox.ts, FiledOutcome): a link, an existing link, or an error. */
const filer = (answers: Record<string, FiledOutcome>, wait = 0) => async (f: Filing): Promise<FiledOutcome> => {
  calls.push(f.title);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  return answers[f.title] ?? { error: "it filed nothing" };
};

const base = (fileOne: NonNullable<InboxRunArgs["fileOne"]>): InboxRunArgs =>
  ({
    stateDir: dir,
    harness: {},
    inboxPrompt: "file work in acme/digestif",
    brief: "",
    rules: "",
    learnings: "",
    deny: [],
    allow: [],
    members: [{ identity: "me-id", name: "Ada", is_self: true }],
    batch: [m],
    post: async () => ({}),
    log: () => {},
    fileOne,
  }) as unknown as InboxRunArgs;

const readPass = (a: InboxRunArgs, filings: Filing[]) => fileAll(filings, new Map([[m.ref, m]]), "Ada", a, [], new Map());
const retry = (fileOne: NonNullable<InboxRunArgs["fileOne"]>, titles: string[], extract?: RetryArgs["extract"]) => retryFiling(m, titles, { ...base(fileOne), ...(extract === undefined ? {} : { extract }) });

const A = "https://github.com/acme/digestif/issues/1";
const B = "https://github.com/acme/digestif/issues/2";

test("a failed filing keeps the idea under the ledger's key; a success writes the ledger and removes it", async () => {
  const a = base(filer({ One: { link: A } }));
  assert.equal(await readPass(a, [idea("One"), idea("Two", { quote: "the words" })]), 1);
  assert.deepEqual(readFiled(dir), { "sha256:1 0": A });
  assert.deepEqual(readFailed(dir), { "sha256:1 1": { ref: "m1", title: "Two", body: "Two body", quote: "the words" } });
  const b = base(filer({ Two: { link: B } }));
  await readPass(b, [idea("One"), idea("Two")]);
  assert.deepEqual(readFiled(dir), { "sha256:1 0": A, "sha256:1 1": B });
  assert.deepEqual(readFailed(dir), {});
});

test("a retry files the failed idea, not the filed one, and writes one line each", async () => {
  await readPass(base(filer({ One: { link: A } })), [idea("One"), idea("Two")]);
  calls = [];
  const r = await retry(filer({ Two: { link: B } }), ["One", "Two"]);
  assert.deepEqual(calls, ["Two"]);
  assert.deepEqual(r.lines, [`Already filed One: ${A}`, `Filed Two: ${B}`], "one line for each idea the notice lists, in its order");
  assert.equal(r.text, `Already filed One: ${A}\nFiled Two: ${B}`);
});

test("a ledger that cannot be read files nothing and is left as it was; so is a failed.json that cannot", async () => {
  writeFileSync(join(dir, "filed.json"), "{not json");
  const fileOne = filer({ One: { link: A } });
  assert.equal(await readPass(base(fileOne), [idea("One")]), 0);
  assert.deepEqual(calls, []);
  assert.equal(readFileSync(join(dir, "filed.json"), "utf8"), "{not json");
  const r = await retry(fileOne, ["One"], async () => [idea("One")]);
  assert.deepEqual(r.lines, ["Could not file One: the ledger could not be read"]);
  assert.deepEqual(calls, []);
  rmSync(join(dir, "filed.json"));
  writeFileSync(join(dir, "failed.json"), "[1]");
  assert.equal(await readPass(base(fileOne), [idea("One")]), 1, "the ledger is the truth");
  assert.equal(readFileSync(join(dir, "failed.json"), "utf8"), "[1]");
});

const leave = (owner: string, ageMs = 0): string => {
  const lock = join(dir, "filing.lock");
  mkdirSync(lock);
  if (owner !== "") writeFileSync(join(lock, "owner"), owner);
  const t = new Date(Date.now() - ageMs);
  utimesSync(lock, t, t);
  return lock;
};

test("a lock held by a live filing in this process is not displaced while it works", async () => {
  let release = (): void => {};
  const holder = withFilingLock(dir, () => new Promise<void>((r) => (release = r)));
  let got = false;
  const waiting = withFilingLock(dir, async () => {
    got = true;
  });
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(got, false, "the holder keeps it");
  release();
  await holder;
  await waiting;
  assert.equal(got, true);
  assert.equal(existsSync(join(dir, "filing.lock")), false, "released");
});

test("a lock left by a run that died is taken: its pid gone, this pid with a token not held here, a stale touch, or no readable owner", async () => {
  const cases: [string, number][] = [
    ["2147483646 dead-token", 0], // pid gone
    [`${process.pid} other-token`, 1000], // an earlier run's, whose pid this process now has
    [`${process.ppid} live-token`, 3 * 60 * 60 * 1000], // a live pid that reused the number, not touched for hours
    ["", 60 * 1000], // no owner file
    ["not-a-pid x", 60 * 1000], // garbled owner
    ["0 ", 60 * 1000], // pid 0 is no run
  ];
  for (const [owner, age] of cases) {
    const lock = join(dir, "filing.lock");
    leave(owner, age);
    let got = false;
    await withFilingLock(dir, async () => {
      got = true;
    });
    assert.equal(got, true, `taken over: ${JSON.stringify(owner)}`);
    assert.equal(existsSync(lock), false);
  }
});

test("a lock whose owner is another live run, touched lately, is not taken", async () => {
  const lock = leave(`${process.ppid} live-token`, 1000);
  let got = false;
  const waiting = withFilingLock(dir, async () => {
    got = true;
  });
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(got, false);
  rmSync(lock, { recursive: true });
  await waiting;
  assert.equal(got, true);
});

test("a retry's line for an idea with no kept entry waits for a read pass filing it and says where it went", async () => {
  await readPass(base(filer({})), [idea("One")]); // One is kept as failed; Two has no kept entry
  assert.deepEqual(Object.keys(readFailed(dir)), ["sha256:1 0"]);
  calls = [];
  const slow = filer({ One: { link: A }, Two: { link: B } }, 60);
  const pass = readPass(base(slow), [idea("One"), idea("Two")]);
  await new Promise((r) => setTimeout(r, 15));
  const r = await retry(slow, ["One", "Two"]);
  assert.equal(await pass, 2);
  assert.deepEqual(calls, ["One", "Two"], "one fileOne call each");
  assert.deepEqual(r.lines, [`Already filed One: ${A}`, `Already filed Two: ${B}`], "not 'could not be matched'");
});

test("a retry that fails again keeps the idea and says Could not file with the reason; an existing answer is Already filed", async () => {
  await readPass(base(filer({})), [idea("One"), idea("Two")]);
  const r = await retry(filer({ One: { existing: "ISS-9" } }), ["One", "Two"]);
  assert.deepEqual(r.lines, ["Already filed One: ISS-9", "Could not file Two: it filed nothing"]);
  assert.deepEqual(Object.keys(readFailed(dir)), ["sha256:1 1"]);
  assert.deepEqual(readFiled(dir)["sha256:1 0"], { existing: "ISS-9" });
});

test("a retry pressed twice files each idea once", async () => {
  await readPass(base(filer({})), [idea("One"), idea("Two")]);
  calls = [];
  const fileOne = filer({ One: { link: A }, Two: { link: B } }, 10);
  const [x, y] = await Promise.all([retry(fileOne, ["One", "Two"]), retry(fileOne, ["One", "Two"])]);
  assert.deepEqual(calls.sort(), ["One", "Two"], "one fileOne call each");
  assert.deepEqual([...x.lines, ...y.lines].sort(), [`Already filed One: ${A}`, `Already filed Two: ${B}`, `Filed One: ${A}`, `Filed Two: ${B}`], "the press that waited for the lock reports where they were filed");
  const z = await retry(fileOne, ["One", "Two"]);
  assert.deepEqual(calls.sort(), ["One", "Two"], "and a press after them files nothing");
  assert.deepEqual(z.lines, [`Already filed One: ${A}`, `Already filed Two: ${B}`], "it says where they are");
});

test("a retry started while a read pass is filing the same key files nothing more", async () => {
  await readPass(base(filer({})), [idea("One")]);
  calls = [];
  const fileOne = filer({ One: { link: A } }, 60);
  const pass = readPass(base(fileOne), [idea("One")]);
  await new Promise((r) => setTimeout(r, 15));
  const r = await retry(fileOne, ["One"]);
  assert.equal(await pass, 1);
  assert.deepEqual(calls, ["One"], "exactly one fileOne call");
  assert.deepEqual(r.lines, [`Already filed One: ${A}`]);
  assert.deepEqual(readFailed(dir), {});
});

test("a read pass started while a retry is filing the same key files nothing more", async () => {
  await readPass(base(filer({})), [idea("One")]);
  calls = [];
  const fileOne = filer({ One: { link: A } }, 60);
  const r = retry(fileOne, ["One"]);
  await new Promise((res) => setTimeout(res, 15));
  assert.equal(await readPass(base(fileOne), [idea("One")]), 1, "the pass reads the link the retry filed");
  assert.deepEqual((await r).lines, [`Filed One: ${A}`]);
  assert.deepEqual(calls, ["One"]);
});

test("a notice with no kept ideas: they are taken from the note in order and filed under the ledger's keys, the filed one skipped", async () => {
  await readPass(base(filer({ One: { link: A } })), [idea("One")]);
  rmSync(join(dir, "failed.json"), { force: true });
  assert.equal(existsSync(join(dir, "failed.json")), false);
  calls = [];
  const r = await retry(filer({ Two: { link: B } }), ["One", "Two"], async () => [idea("One"), idea("Two")]);
  assert.deepEqual(calls, ["Two"]);
  assert.deepEqual(r.lines, [`Already filed One: ${A}`, `Filed Two: ${B}`]);
  assert.deepEqual(readFiled(dir), { "sha256:1 0": A, "sha256:1 1": B });
});

test("a notice with no kept ideas whose ideas cannot be matched to the note files nothing (fail closed)", async () => {
  const fileOne = filer({ One: { link: A }, Two: { link: B } });
  const wrong = [
    async () => [idea("One")], // count
    async () => [idea("Two"), idea("One")], // order
    async () => undefined, // no usable answer
  ];
  for (const extract of wrong) {
    const r = await retry(fileOne, ["One", "Two"], extract);
    assert.deepEqual(r.lines, ["Could not file One: the idea could not be matched", "Could not file Two: the idea could not be matched"]);
  }
  assert.deepEqual(calls, []);
  assert.deepEqual(readFiled(dir), {});
});

test("the filing lock is one per state directory and is let go when the work throws", async () => {
  const order: string[] = [];
  await Promise.all([
    withFilingLock(dir, async () => {
      order.push("a in");
      await new Promise((r) => setTimeout(r, 40));
      order.push("a out");
    }),
    withFilingLock(dir, async () => {
      order.push("b in");
    }),
  ]);
  assert.deepEqual(order, ["a in", "a out", "b in"]);
  await assert.rejects(withFilingLock(dir, async () => { throw new Error("boom"); }), /boom/);
  assert.equal(await withFilingLock(dir, async () => "again"), "again");
});
