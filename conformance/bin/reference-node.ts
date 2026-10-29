#!/usr/bin/env node
// The reference node behind the node adapter contract: `reference-node.ts sync --home DIR
// --device-seed-file FILE --relay URL...`. Stateless, so --home is accepted and unused. `--break RULE`
// makes it get one rule wrong, which is how the self-test proves the node cases can fail.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { Signer } from "../src/keys.ts";
import { sync, type NodeBreak } from "../src/reference-node.ts";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    home: { type: "string" },
    "device-seed-file": { type: "string" },
    relay: { type: "string", multiple: true },
    break: { type: "string", multiple: true },
  },
});
if (positionals[0] !== "sync" || values["device-seed-file"] === undefined || (values.relay ?? []).length === 0) {
  process.stderr.write("usage: reference-node.ts sync --home DIR --device-seed-file FILE --relay URL [--relay URL...]\n");
  process.exit(2);
}
const device = Signer.fromSeed(readFileSync(values["device-seed-file"], "utf8").trim());
process.stdout.write(`${JSON.stringify(await sync(device, values.relay ?? [], new Set((values.break ?? []) as NodeBreak[])))}\n`);
