#!/usr/bin/env node
// digestif-conformance: the Digestif conformance suite. `digestif-conformance help` for usage.
import { parseArgs } from "node:util";
import { DEFAULT_CIRCLE_PATH, TestCircle } from "../src/circle.ts";
import { FakeRelay } from "../src/fake-relay.ts";
import type { Outcome } from "../src/harness.ts";
import { REFERENCE_NODE } from "../src/node-runner.ts";
import { runNodeSuite, runRelaySuite } from "../src/suites.ts";
import { nodeCases } from "../src/cases/node.ts";
import { relayCases } from "../src/cases/relay.ts";

const USAGE = `digestif-conformance <command>

  relay --url URL [--url URL] [--circle FILE] [--case ID...]
      Run the relay cases over HTTP. Each relay must be configured with the circle's root hash
      (circle show). Cases needing two relays are skipped with one.
  node [--node "COMMAND"] [--case ID...]
      Run the node cases on fresh local fake relays. COMMAND is the node adapter (README, "Testing a
      node"); the default is the reference node.
  self-test
      Relay cases against two local fake relays, then node cases against the reference node.
  fake-relay [--circle FILE] [--port N] [--mode checked|unchecked]
      Serve a local relay rooted in the circle until interrupted.
  circle show [--circle FILE]
      Print the circle's root hash and root dinner, which a relay under test is configured with.
  circle new --out FILE [--label TEXT] [--relay URL...]
      Write a fresh throwaway test circle.
  list
      Print every case id and the protocol line it covers.

--case takes an id, an id prefix (relay.clock) or a glob (relay.*.refused). The default circle is
fixtures/test-circle.json.`;

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    url: { type: "string", multiple: true },
    circle: { type: "string" },
    case: { type: "string", multiple: true },
    node: { type: "string" },
    port: { type: "string" },
    mode: { type: "string" },
    out: { type: "string" },
    label: { type: "string" },
    relay: { type: "string", multiple: true },
  },
});

function circle(): TestCircle {
  return TestCircle.load(values.circle ?? DEFAULT_CIRCLE_PATH);
}

function exitWith(outcomes: Outcome[]): never {
  process.exit(outcomes.some((o) => o.result === "fail") ? 1 : 0);
}

const only = values.case;
const [command, sub] = positionals;
switch (command) {
  case "relay": {
    if (!values.url?.length) throw new Error("relay needs --url");
    exitWith(await runRelaySuite(circle(), values.url, only ? { only } : {}));
  }
  case "node":
    exitWith(await runNodeSuite(values.node ?? REFERENCE_NODE, only ? { only } : {}));
  case "self-test": {
    const c = circle();
    const relays = [new FakeRelay({ root: c.rootHash }), new FakeRelay({ root: c.rootHash })];
    const urls = await Promise.all(relays.map((r) => r.listen()));
    const relayOutcomes = await runRelaySuite(c, urls, only ? { only } : {});
    await Promise.all(relays.map((r) => r.close()));
    const nodeOutcomes = await runNodeSuite(values.node ?? REFERENCE_NODE, only ? { only } : {});
    exitWith([...relayOutcomes, ...nodeOutcomes]);
  }
  case "fake-relay": {
    const c = circle();
    const mode = values.mode === "unchecked" ? "unchecked" : "checked";
    const url = await new FakeRelay({ root: c.rootHash, mode }).listen(Number(values.port ?? "0"));
    console.log(`fake relay (${mode}) rooted in ${c.rootHash} at ${url}`);
    break;
  }
  case "circle":
    if (sub === "show") {
      const c = circle();
      console.log(JSON.stringify({ root_hash: c.rootHash, root: c.root }, null, 2));
    } else if (sub === "new") {
      if (values.out === undefined) throw new Error("circle new needs --out");
      const file = TestCircle.create(values.label ?? "Digestif conformance test circle", values.relay ?? []);
      TestCircle.write(values.out, file);
      console.log(`${values.out}: root ${file.root_hash}`);
    } else {
      console.log(USAGE);
      process.exit(2);
    }
    break;
  case "list":
    for (const c of [...relayCases, ...nodeCases]) console.log(`${c.id}${c.relays && c.relays > 1 ? ` (${c.relays} relays)` : ""}\n    ${c.title}\n    covers: ${c.covers}`);
    break;
  default:
    console.log(USAGE);
    process.exit(command === "help" ? 0 : 2);
}
