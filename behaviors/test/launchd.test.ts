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
    [join(import.meta.dirname, "..", "bin", "install-launchd.ts"), "--print", "--sources", "s.json", "--state-dir", "/tmp/x-state", "--minute", "200"],
    { encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  assert.ok(r.stdout.includes("nightly.ts") && r.stdout.includes("<string>200</string>") && r.stdout.includes("/tmp/x-state"));
});
