// The two suites as functions, shared by the CLI and the self-test.
import { TestCircle } from "./circle.ts";
import { FakeRelay, type RelayLimits } from "./fake-relay.ts";
import { runCases, type Outcome } from "./harness.ts";
import { NodeRunner } from "./node-runner.ts";
import { World } from "./world.ts";
import { nodeCases, type NodeContext } from "./cases/node.ts";
import { relayCases } from "./cases/relay.ts";

export interface SuiteOptions {
  only?: string[];
  log?: (line: string) => void;
}

/** Runs the relay cases against relays already configured with the circle's root. */
export async function runRelaySuite(circle: TestCircle, urls: string[], options: SuiteOptions = {}): Promise<Outcome[]> {
  const world = new World(circle, urls);
  await world.setup();
  return runCases({
    cases: relayCases,
    relayCount: urls.length,
    context: async () => ({ value: world }),
    ...options,
  });
}

/** Runs the node cases, each on fresh local fake relays rooted in a fresh circle. */
export async function runNodeSuite(nodeCommand: string, options: SuiteOptions & { limits?: Partial<RelayLimits> } = {}): Promise<Outcome[]> {
  const node = new NodeRunner(nodeCommand);
  return runCases<NodeContext>({
    cases: nodeCases,
    relayCount: 2,
    context: async () => {
      const circle = new TestCircle(TestCircle.create("conformance node case", []));
      const relays = [
        new FakeRelay({ root: circle.rootHash, ...(options.limits ? { limits: options.limits } : {}) }),
        new FakeRelay({ root: circle.rootHash, ...(options.limits ? { limits: options.limits } : {}) }),
        new FakeRelay({ root: circle.rootHash, mode: "unchecked" }),
      ];
      const [a, b, hostile] = await Promise.all(relays.map((r) => r.listen()));
      const world = new World(circle, [a!, b!]);
      await world.setup();
      await world.publish([hostile!], world.host.device, circle.root, { unsigned: true });
      return {
        value: { world, a: a!, b: b!, hostile: hostile!, node },
        close: async () => {
          await Promise.all(relays.map((r) => r.close()));
        },
      };
    },
    ...options,
  });
}
