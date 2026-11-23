// The home circle's move from the relay's D1 into its own store (src/move.ts): batches by relay_id
// within the day's allowance, a batch interrupted mid-way rolled back whole and resumed from its
// recorded cursor, appends during the copy landing in D1 and copied, appends during the drain
// answered 503 moving while reads keep answering, and the store, once it serves, holding D1's log,
// relay ids and fold exactly. Every step runs with a clock days ahead, so no alarm the steps set
// fires on its own during the test: the test drives each step itself.
import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { forgetMemos, hostedRow, startMove } from "../src/circles.ts";
import { circleEpoch, ENVELOPE_COLUMNS, foldLog, forgetKeptFold, keyJson, loadKeys } from "../src/db.ts";
import { beginMove, moveState, moveStep } from "../src/move.ts";
import { circleDatabase, type CircleStore } from "../src/store.ts";
import { RELAY } from "./helpers.ts";
import { TEST_ROOT } from "./root.ts";

const realFetch = globalThis.fetch;
const DAY_MS = 24 * 60 * 60 * 1000;
/** The steps' clock: days ahead of the wall clock, so the alarms they set never fire during the test. */
let clock = Date.now() + 30 * DAY_MS;

let world: World;
let member: Member;

function stub(): DurableObjectStub<CircleStore> {
  return env.CIRCLE_STORE.get(env.CIRCLE_STORE.idFromName(TEST_ROOT));
}

/** A native object's member, a method bound to it: the runtime refuses one called on a proxy. */
function bound(target: object, name: string | symbol): unknown {
  const value = Reflect.get(target, name, target) as unknown;
  return typeof value === "function" ? (value as (...args: unknown[]) => unknown).bind(target) : value;
}

/** One move step on the home circle's store, with [storage] wrapped when a case interrupts it. */
async function step(wrap?: (storage: DurableObjectStorage) => DurableObjectStorage): Promise<string> {
  return runInDurableObject(stub(), (_instance, state) => moveStep(wrap === undefined ? state.storage : wrap(state.storage), env.DB, new Date(clock)));
}

async function store(): Promise<string | undefined> {
  return (await hostedRow(env.DB, TEST_ROOT))?.store;
}

async function rows(db: D1Database, table: string, order: string): Promise<unknown[]> {
  return (await db.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all()).results;
}

/** A summary by the member, appended at the home circle's unprefixed address. */
async function summary(text: string): Promise<{ status: number; body: unknown; text: string }> {
  return world.client(RELAY, member.device).append(await world.summary(member.device, text));
}

beforeAll(async () => {
  forgetMemos();
  globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url.startsWith(RELAY)) return SELF.fetch(url, init);
    return realFetch(input, init);
  };
  world = new World(
    { hostIdentity: Signer.fromSeed(circleFile.host_identity_seed), hostDevice: Signer.fromSeed(circleFile.host_device_seed), root: circleFile.root as SignedEnvelope, rootHash: circleFile.root_hash },
    [RELAY],
  );
  await world.setup();
  [member] = (await world.members(["mover", "stayer"])) as [Member, Member];
  for (let i = 0; i < 12; i++) await world.publish([RELAY], member.device, await world.summary(member.device, `before the move ${i}`));
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("the home circle's move into its store", () => {
  it("starts with the home circle on D1, its registry row made on its first request", async () => {
    expect(await store()).toBe("d1");
    // What startMove does, on the steps' clock: the row goes moving, and the store takes the move.
    // The steps below drive it, so the alarm it sets is dropped and never runs beside them.
    await env.DB.prepare("UPDATE hosted_circles SET store = 'moving' WHERE root = ? AND store = 'd1'").bind(TEST_ROOT).run();
    await runInDurableObject(stub(), (_instance, state) => beginMove(state.storage, TEST_ROOT, 10, 4, new Date(clock)));
    await runInDurableObject(stub(), (_instance, state) => state.storage.deleteAlarm());
    expect(await store()).toBe("moving");
    expect(await runInDurableObject(stub(), (_instance, state) => moveState(state.storage))).toMatchObject({ root: TEST_ROOT, phase: "copying", last_relay_id: 0, rows_per_day: 10, batch: 4 });
  });

  it("rolls back a batch interrupted mid-way, and resumes from the recorded cursor", async () => {
    expect(await step()).toBe("copied");
    const cursor = (await runInDurableObject(stub(), (_i, state) => moveState(state.storage)))?.last_relay_id;
    expect(cursor).toBe(4);
    let inserts = 0;
    const interrupted = step((storage) =>
      new Proxy(storage, {
        get(target, property) {
          if (property !== "sql") return bound(target, property);
          return new Proxy(target.sql, {
            get(sql, name) {
              if (name !== "exec") return bound(sql, name);
              return (query: string, ...binds: SqlStorageValue[]) => {
                if (query.startsWith("INSERT OR IGNORE INTO envelopes") && ++inserts === 3) throw new Error("the step was cut off");
                return sql.exec(query, ...binds);
              };
            },
          });
        },
      }),
    );
    await expect(interrupted).rejects.toThrow(/cut off/);
    const after = await runInDurableObject(stub(), (_i, state) => ({
      cursor: moveState(state.storage)?.last_relay_id,
      held: state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM envelopes").one().n,
    }));
    expect(after).toEqual({ cursor: 4, held: 4 });
    expect(await step()).toBe("copied");
  });

  it("copies no more than the day's allowance, and goes on the next UTC day", async () => {
    expect(await step()).toBe("copied");
    expect(await step()).toBe("waiting");
    expect((await runInDurableObject(stub(), (_i, state) => moveState(state.storage)))?.rows_today).toBe(10);
    clock += DAY_MS;
    expect(await step()).toBe("copied");
  });

  it("lands an append made during the copy in D1, and copies it", async () => {
    const appended = await summary("during the copy");
    expect(appended.status).toBe(201);
    let result = "";
    for (let i = 0; i < 50; i++) {
      result = await step();
      if (result === "waiting") clock += DAY_MS;
      else if (result !== "copied") break;
    }
    expect(result).toBe("draining");
    expect(await store()).toBe("draining");
  });

  it("answers an append 503 moving while the copy drains, and keeps answering reads from D1", async () => {
    const refused = await world.client(RELAY, member.device).append(await world.summary(member.device, "during the drain"));
    expect(refused.status).toBe(503);
    expect((refused.body as { code: string }).code).toBe("moving");
    expect((await world.client(RELAY, member.device).circle()).status).toBe(200);
    // A write that reaches D1's tables behind the router's back is refused by D1 itself.
    await expect(env.DB.prepare("INSERT INTO mailed_digests (digest, sent_at) VALUES ('x', 'y')").run()).rejects.toThrow(/circle_moving/);
  });

  it("cuts over once drained: the store holds D1's log, relay ids and fold, and serves the next append after them", async () => {
    expect(await step()).toBe("done");
    expect(await store()).toBe("object");
    const object = circleDatabase(env.CIRCLE_STORE, TEST_ROOT);
    const order = "relay_id";
    expect(await object.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes ORDER BY ${order}`).all().then((r) => r.results)).toEqual(
      await env.DB.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes ORDER BY ${order}`).all().then((r) => r.results),
    );
    for (const [table, by] of [["admitted_keys", "key"], ["invites", "key"]] as const) {
      expect(await rows(object, table, by), table).toEqual(await rows(env.DB, table, by));
    }
    expect(await object.prepare("SELECT root, epoch, admission_cutover FROM circle WHERE id = 1").first()).toEqual(await env.DB.prepare("SELECT root, epoch, admission_cutover FROM circle WHERE id = 1").first());
    forgetKeptFold();
    const fold = await foldLog(object, TEST_ROOT, { all: true });
    expect((await loadKeys(object)).map(keyJson)).toEqual(fold.admittedKeys().map(keyJson));
    expect(await circleEpoch(object)).toBe(fold.epoch);

    const held = (await env.DB.prepare("SELECT MAX(relay_id) AS last FROM envelopes").first<{ last: number }>())!.last;
    const next = await world.client(RELAY, member.device).append(await world.summary(member.device, "after the move"));
    expect(next.status, next.text).toBe(201);
    expect((next.body as { relay_id: number }).relay_id).toBe(held + 1);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM envelopes WHERE relay_id > ?").bind(held).first("n")).toBe(0);
    const page = await world.client(RELAY, member.device).fetchAll();
    expect(page.map((e) => e.relay_id)).toEqual([...page.map((e) => e.relay_id)].sort((a, b) => a - b));
    expect(page[page.length - 1]?.relay_id).toBe(held + 1);
  });

  it("stays done: a later start and a later alarm change nothing", async () => {
    forgetMemos();
    await startMove(env, TEST_ROOT, 10, 4);
    expect(await step()).toBe("idle");
    expect(await store()).toBe("object");
  });
});
