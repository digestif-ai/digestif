import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { test } from "node:test";
import { LABEL, loadTemplate, renderPlist } from "../src/launchd.ts";

test("the plist template fills every path and escapes what XML needs", async () => {
  const out = renderPlist(await loadTemplate(), {
    program: ["/opt/node", "/opt/bin/nightly.ts", "--allow", "A & B <x>"],
    path: "/usr/bin:/bin",
    stateDir: "/data/behaviors",
  });
  assert.ok(!/@[A-Z_]+@/.test(out));
  assert.ok(out.includes(`<string>${LABEL}</string>`));
  assert.ok(out.includes("<string>A &amp; B &lt;x&gt;</string>"));
  assert.ok(out.includes("<string>/data/behaviors/logs/launchd.err.log</string>"));
  assert.match(out, /<key>StartInterval<\/key>\s*<integer>300<\/integer>/);
});

test("a template with a placeholder nobody fills is an error", () => {
  assert.throws(() => renderPlist("@UNKNOWN@", { program: [], path: "", stateDir: "" }), /unfilled/);
});

test("install-launchd --print renders the plist and loads nothing", () => {
  const r = spawnSync(
    process.execPath,
    [join(import.meta.dirname, "..", "bin", "install-launchd.ts"), "--print", "--sources", "s.json", "--state-dir", "/tmp/x-state", "--note-time", "03:20"],
    { encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  assert.ok(r.stdout.includes("nightly.ts") && r.stdout.includes("<string>03:20</string>") && r.stdout.includes("/tmp/x-state"));
});

test("install-launchd --print makes every path absolute: launchd runs the agent from /", () => {
  const cwd = import.meta.dirname;
  const r = spawnSync(
    process.execPath,
    [join(cwd, "..", "bin", "install-launchd.ts"), "--print", "--sources", "s.json", "--state-dir", "st", "--node", "./bin/digestif", "--harness", "claude"],
    { encoding: "utf8", cwd },
  );
  assert.equal(r.status, 0, r.stderr);
  const strings = [...r.stdout.matchAll(/<string>([^<]*)<\/string>/g)].map((m) => m[1]!);
  const after = (flag: string) => strings[strings.indexOf(flag) + 1];
  assert.equal(after("--sources"), join(cwd, "s.json"));
  assert.equal(after("--state-dir"), join(cwd, "st"));
  assert.equal(after("--node"), join(cwd, "bin", "digestif"));
  assert.equal(after("--harness"), "claude", "a bare name is looked up on the plist's PATH");
  assert.ok(!/DIGESTIF_SESSION|ANTHROPIC_/.test(r.stdout), "no credentials in the plist");
});
