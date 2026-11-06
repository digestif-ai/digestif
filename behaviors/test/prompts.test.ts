// ISS-51009: the nightly note in two versions for a suggestion the member judges, the circle's live
// prompt, and the pull request an adopted suggestion is owed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { removesNothing } from "../src/checks.ts";
import { nightly, type NightlyOptions } from "../src/nightly.ts";
import { openPullRequest, promptId, promptsOf, releasePrompt, type Ran, type Suggestion } from "../src/prompts.ts";

const here = import.meta.dirname;
const harness = join(here, "fake-harness.mjs");
const fakeNode = join(here, "fake-digestif.mjs");

let dir: string;
let stateDir: string;
let calls: string;
let harnessLog: string;
let repo: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "digestif-prompts-test-"));
  stateDir = join(dir, "state");
  calls = join(dir, "digestif.log");
  harnessLog = join(dir, "harness.log");
  repo = join(dir, "repo");
  mkdirSync(repo);
  const env = { ...process.env, GIT_AUTHOR_NAME: "M", GIT_AUTHOR_EMAIL: "m@example.com", GIT_COMMITTER_NAME: "M", GIT_COMMITTER_EMAIL: "m@example.com", GIT_AUTHOR_DATE: "2026-10-29T12:00:00", GIT_COMMITTER_DATE: "2026-10-29T12:00:00", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
  for (const [subject, date] of [["Add a retry to the fetcher", "2026-10-28T12:00:00"], ["Fix the docs build", "2026-10-29T12:00:00"]] as const) {
    writeFileSync(join(repo, "f.txt"), subject);
    execFileSync("git", ["add", "."], { cwd: repo, env: { ...env, GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date } });
    execFileSync("git", ["commit", "-q", "-m", subject], { cwd: repo, env: { ...env, GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date } });
  }
  process.env["FAKE_DIGESTIF_LOG"] = calls;
  process.env["FAKE_FIXTURE"] = join(here, "harness-fixtures", "note.txt");
  process.env["FAKE_LOG"] = harnessLog;
});
afterEach(() => {
  for (const k of ["FAKE_DIGESTIF_LOG", "FAKE_FIXTURE", "FAKE_LOG"]) delete process.env[k];
  rmSync(dir, { recursive: true, force: true });
});

const selection = () => ({ sources: [{ id: "git", kind: "git" as const, label: "Git", paths: [repo], yields: [], selected: true }] });
const opts = (extra: Partial<NightlyOptions> = {}): NightlyOptions => ({
  stateDir,
  selection: selection(),
  now: new Date("2026-10-29T03:21:00"),
  noteTime: "03:20",
  node: fakeNode,
  writer: { harness },
  pii: removesNothing,
  rules: removesNothing,
  ...extra,
});
const notes = () =>
  (existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [])
    .map((l) => JSON.parse(l) as { args: string[]; stdin: string })
    .filter((c) => c.args[0] === "note");
/** The system prompt of every writer run the harness was given, in order. */
const writerPrompts = () =>
  readFileSync(harnessLog, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l) as { argv: string[]; check?: string })
    .filter((r) => r.check === undefined)
    .map((r) => r.argv[r.argv.indexOf("--system-prompt") + 1] ?? "");
const flag = (args: string[], name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);

const suggested = "SUGGESTED. Lead with the lesson. {{always_on_rules}}";
const suggestion = (text = suggested): Suggestion => ({ hash: "sha256:abc", change: "Lead with the lesson", text, prompt_id: promptId(text) });

test("a prompt's id is sha256 of its text, and a suggestion that is the current prompt writes one version", async () => {
  assert.equal(promptId("abc"), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  const release = await releasePrompt();
  assert.deepEqual(promptsOf({}, release), { current: { id: promptId(release), text: release } });
  assert.equal(promptsOf({ running: suggestion(release) }, release).suggested, undefined);
  assert.equal(promptsOf({ text: "LIVE {{always_on_rules}}", running: suggestion() }, release).current.text, "LIVE {{always_on_rules}}");
});

test("a member who judges a suggestion gets the note in two versions, which wait whatever the approval setting", async () => {
  const r = await nightly(opts({ notePrompt: async () => ({ running: suggestion() }), autoApprove: async () => true }));
  assert.equal(r.status, "posted");
  const [c, ...rest] = notes();
  assert.equal(rest.length, 0);
  assert.equal(flag(c!.args, "--prompt"), promptId(await releasePrompt()), "the current prompt's id");
  assert.ok(!c!.args.includes("--approve"), "a pair is the member's to pick");
  const pair = JSON.parse(readFileSync(flag(c!.args, "--pair")!, "utf8")) as { suggestion: string; prompt: string; text: string; checks: unknown[] };
  assert.equal(pair.suggestion, "sha256:abc");
  assert.equal(pair.prompt, promptId(suggested));
  assert.match(pair.text, /^Worked on:/);
  assert.ok(Array.isArray(pair.checks) && pair.checks.length > 0, "the second version was checked too");
  const prompts = writerPrompts();
  assert.equal(prompts.length, 2, "written twice, from the same record");
  assert.ok(prompts[0]!.startsWith("You write one person's nightly note"), "the release's prompt first");
  assert.ok(prompts[1]!.startsWith("SUGGESTED."), "then the suggested one");
});

test("a suggested prompt that cannot run leaves the note in one version", async () => {
  const r = await nightly(opts({ notePrompt: async () => ({ running: suggestion("No placeholder here.") }), autoApprove: async () => true }));
  assert.equal(r.status, "posted");
  const [c] = notes();
  assert.equal(flag(c!.args, "--pair"), undefined);
  assert.ok(c!.args.includes("--approve"), "one version follows the approval setting");
  assert.match(readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8"), /the suggested prompt could not be run/);
});

test("the circle's live prompt writes the note, and the note carries its id", async () => {
  const live = "LIVE prompt. {{always_on_rules}}";
  const r = await nightly(opts({ notePrompt: async () => ({ text: live }) }));
  assert.equal(r.status, "posted");
  assert.equal(flag(notes()[0]!.args, "--prompt"), promptId(live));
  assert.ok(writerPrompts()[0]!.startsWith("LIVE prompt."));
});

test("a node that cannot say which prompt stands leaves the release's", async () => {
  const r = await nightly(opts({ notePrompt: async () => Promise.reject(new Error("HTTP 500")) }));
  assert.equal(r.status, "posted");
  assert.equal(flag(notes()[0]!.args, "--prompt"), promptId(await releasePrompt()));
});

test("an owed pull request is opened and recorded after the hand-over; one that fails is a problem and never fails the run", async () => {
  const recorded: Array<[string, string]> = [];
  const r = await nightly(
    opts({
      pullRequests: {
        owed: async () => [suggestion()],
        open: async () => "https://github.com/digestif-ai/digestif/pull/9",
        record: async (h, u) => void recorded.push([h, u]),
      },
    }),
  );
  assert.equal(r.status, "posted");
  assert.deepEqual(recorded, [["sha256:abc", "https://github.com/digestif-ai/digestif/pull/9"]]);
  const failing = await nightly(
    opts({
      stateDir: join(dir, "again"),
      pullRequests: { owed: async () => [suggestion()], open: async () => Promise.reject(new Error("push refused")), record: async () => {} },
    }),
  );
  assert.equal(failing.status, "posted");
  const problems = readFileSync(calls, "utf8").trim().split("\n").map((l) => (JSON.parse(l) as { args: string[] }).args.join(" "));
  assert.ok(problems.includes("problem report --job pull_request --kind failed"));
});

test("openPullRequest clones, branches, replaces the prompt file, pushes and answers the url gh printed", async () => {
  const ran: string[] = [];
  let written = "";
  const runner = async (cmd: string, args: string[], cwd?: string): Promise<Ran> => {
    ran.push([cmd, ...args].join(" "));
    if (cmd === "gh" && args[0] === "repo") mkdirSync(join(args[3]!, "behaviors", "prompts"), { recursive: true });
    if (cmd === "git" && args[0] === "add") written = readFileSync(join(cwd!, args[1]!), "utf8");
    return { code: 0, stdout: cmd === "gh" && args[0] === "pr" ? "Creating pull request\nhttps://github.com/digestif-ai/digestif/pull/12\n" : "", stderr: "" };
  };
  const url = await openPullRequest(suggestion(), { runner });
  assert.equal(url, "https://github.com/digestif-ai/digestif/pull/12");
  assert.equal(written, suggested + "\n");
  assert.match(ran[0]!, /^gh repo clone digestif-ai\/digestif .* -- --depth 1$/);
  assert.deepEqual(ran[1], "git checkout -b note-prompt-abc");
  assert.ok(ran.some((r) => r === "git push --set-upstream origin note-prompt-abc"));
  assert.ok(ran.at(-1)!.startsWith("gh pr create --repo digestif-ai/digestif --head note-prompt-abc --base main --title Adopt the circle's nightly note prompt: Lead with the lesson"));
  await assert.rejects(openPullRequest(suggestion(), { runner: async () => ({ code: 1, stdout: "", stderr: "denied" }) }), /exited 1: denied/);
});
