#!/usr/bin/env node
// digestif-install-launchd: the interim runner of the nightly pipeline (until the node gains a
// behavior hook, #54). Fills launchd/com.digestif.nightly.plist.in and loads it with
// `launchctl bootstrap`. See behaviors/README.md.
import { execFileSync } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { LABEL, loadTemplate, renderPlist } from "../src/launchd.ts";
import { defaultStateDir } from "../src/nightly.ts";

const usage = `usage: digestif-install-launchd --sources <file> [--state-dir <dir>] [--minute <n>] [--node <digestif>]
                               [--harness <path>] [--brief <file>] [--rules <file>] [--allow <name>]...
                               [--print | --uninstall]

Writes ~/Library/LaunchAgents/${LABEL}.plist and loads it with launchctl bootstrap. The other options
are digestif-nightly's and are passed to it. --print prints the plist and loads nothing;
--uninstall boots the agent out and removes the plist.`;

async function main(): Promise<number> {
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: "string" },
        "state-dir": { type: "string" },
        minute: { type: "string" },
        node: { type: "string" },
        harness: { type: "string" },
        brief: { type: "string" },
        rules: { type: "string" },
        allow: { type: "string", multiple: true },
        print: { type: "boolean" },
        uninstall: { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
      allowPositionals: false,
    }).values;
  } catch (e) {
    console.error(`digestif-install-launchd: ${(e as Error).message}\n${usage}`);
    return 2;
  }
  if (args.help) {
    console.log(usage);
    return 0;
  }
  const plistPath = join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`);
  const domain = `gui/${process.getuid?.() ?? 0}`;
  if (args.uninstall) {
    try {
      execFileSync("launchctl", ["bootout", `${domain}/${LABEL}`], { stdio: "ignore" });
    } catch {
      // not loaded
    }
    await rm(plistPath, { force: true });
    return 0;
  }
  if (args.sources === undefined) {
    console.error(`digestif-install-launchd: --sources is required\n${usage}`);
    return 2;
  }
  const stateDir = resolve(args["state-dir"] ?? defaultStateDir());
  const script = resolve(dirname(fileURLToPath(import.meta.url)), "nightly.ts");
  const abs = (p: string | undefined) => (p === undefined ? undefined : resolve(p));
  const program = [
    process.execPath,
    script,
    "--sources",
    resolve(args.sources),
    "--state-dir",
    stateDir,
    ...(args.minute === undefined ? [] : ["--minute", args.minute]),
    ...(args.node === undefined ? [] : ["--node", args.node]),
    ...(args.harness === undefined ? [] : ["--harness", args.harness]),
    ...(abs(args.brief) === undefined ? [] : ["--brief", abs(args.brief) as string]),
    ...(abs(args.rules) === undefined ? [] : ["--rules", abs(args.rules) as string]),
    ...(args.allow ?? []).flatMap((a) => ["--allow", a]),
  ];
  const plist = renderPlist(await loadTemplate(), { program, path: process.env["PATH"] ?? "/usr/bin:/bin", stateDir });
  if (args.print) {
    process.stdout.write(plist);
    return 0;
  }
  await mkdir(join(stateDir, "logs"), { recursive: true });
  await mkdir(dirname(plistPath), { recursive: true });
  await writeFile(plistPath, plist);
  try {
    execFileSync("launchctl", ["bootout", `${domain}/${LABEL}`], { stdio: "ignore" });
  } catch {
    // not loaded yet
  }
  execFileSync("launchctl", ["bootstrap", domain, plistPath], { stdio: "inherit" });
  console.log(`loaded ${LABEL} from ${plistPath}`);
  return 0;
}

process.exitCode = await main();
