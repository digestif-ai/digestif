// The reference node: what a node's sync must conclude from a set of relays, written once in the
// plainest form so the OCaml node can be held to it. It reads every relay, verifies every envelope,
// dedupes by hash, folds the union in the canonical order below, and reports the fold, the feed,
// forks and gaps. It keeps no state between runs.
//
// Canonical order: repeatedly take, of the envelopes not yet folded, every one that folds, in
// (created_at, hash) order, until a pass folds nothing. The order is a property of the SET of
// envelopes, never of which relay answered first, which is what makes divergent histories merge to
// the same fold and feed. A revoked key is read by its revoke's cutoff, never by this order: a device
// key up to `after_seq`, a mail key by the hashes `mail_read` lists. created_at is the author's clock,
// and a thief holding the key writes it.
import { hashOf, type Json } from "./encoding.ts";
import { envelopeHash, isCircleState, verifyEnvelope, type Envelope, type StoredEnvelope } from "./envelope.ts";
import { Fold, type FoldBreak } from "./fold.ts";
import { Signer } from "./keys.ts";
import { RelayClient } from "./request.ts";

/** What `<node> sync` prints, one JSON object on stdout. Every list is sorted, so two states compare as text. */
export interface NodeState {
  epoch: number;
  keys: Array<{ key: string; role: string; identity: string; revoked: boolean }>;
  /** Content envelope hashes a person would see, in feed order: (created_at, hash). Retracts and their targets are absent. */
  feed: string[];
  faults: Array<{ kind: "fork"; author: string; seq: number; hashes: string[] }>;
  gaps: Array<{ author: string; missing: number[] }>;
}

/** Rules the reference node can be told to get wrong, so the self-test can prove each node case catches it. */
export type NodeBreak = "dedupe" | "fork" | "gap" | "backfill" | "revocation" | "cutoff" | "mail-cutoff" | "bootstrap" | "retract-author" | "mail" | "relay-order" | "self-device" | "device-signature" | "host-device-window";

interface Held {
  hash: string;
  envelope: Envelope;
  body: Json | undefined;
}

function byTimeThenHash(a: Held, b: Held): number {
  if (a.envelope.created_at !== b.envelope.created_at) return a.envelope.created_at < b.envelope.created_at ? -1 : 1;
  return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0;
}

/** Keeps one copy per hash, preferring a copy that still carries a body that matches. */
export function union(pages: StoredEnvelope[][], breaks: ReadonlySet<NodeBreak> = new Set()): Held[] {
  const held = new Map<string, Held>();
  const copies: Held[] = [];
  for (const page of breaks.has("backfill") ? pages.slice(0, 1) : pages) {
    for (const stored of page) {
      const envelope = stored.envelope;
      if (!verifyEnvelope(envelope)) continue;
      const hash = envelopeHash(envelope);
      const body = stored.body === null ? undefined : stored.body;
      const bodyOk = body !== undefined && hashOf(body) === envelope.body_hash;
      if (breaks.has("dedupe")) copies.push({ hash, envelope, body: bodyOk ? body : undefined });
      const existing = held.get(hash);
      if (existing === undefined || (existing.body === undefined && bodyOk)) {
        held.set(hash, { hash, envelope, body: bodyOk ? body : undefined });
      }
    }
  }
  return breaks.has("dedupe") ? copies : [...held.values()];
}

/** Folds the envelopes in canonical order, leaving out `excluded`. Returns the fold and what it folded, in order. */
function foldInOrder(root: string, envelopes: Held[], excluded: ReadonlySet<string>, breaks: ReadonlySet<NodeBreak>): { fold: Fold; folded: Held[] } {
  const foldBreaks: FoldBreak[] = [];
  if (breaks.has("revocation")) foldBreaks.push("revocation");
  if (breaks.has("bootstrap")) foldBreaks.push("spent", "expiry");
  if (breaks.has("retract-author")) foldBreaks.push("retract-author");
  if (breaks.has("mail-cutoff")) foldBreaks.push("mail-cutoff");
  if (breaks.has("self-device")) foldBreaks.push("self-device");
  if (breaks.has("device-signature")) foldBreaks.push("device-signature");
  if (breaks.has("host-device-window")) foldBreaks.push("host-device-window");
  const fold = new Fold(root, { breaks: foldBreaks, readsCutoffs: !breaks.has("cutoff") });
  const folded: Held[] = [];
  let pending = envelopes.filter((h) => !excluded.has(h.hash)).sort(byTimeThenHash);
  for (let progress = true; progress && pending.length > 0; ) {
    progress = false;
    const remaining: Held[] = [];
    for (const held of pending) {
      const position = folded.length + 1;
      const error =
        held.body === undefined && isCircleState(held.envelope.kind)
          ? "malformed"
          : held.body === undefined
            ? fold.activeAuthor(held.envelope.author, { seq: held.envelope.seq, hash: held.hash }) === undefined
              ? "not_admitted"
              : null
            : fold.apply({ hash: held.hash, envelope: held.envelope, body: held.body, position, now: new Date(held.envelope.created_at) });
      if (error === null) {
        folded.push(held);
        progress = true;
      } else {
        remaining.push(held);
      }
    }
    pending = remaining;
  }
  return { fold, folded };
}

/**
 * Folds the union, then reads every revoked key by its cutoff: an envelope outside the cutoff
 * that folded (because its created_at put it ahead of the revoke) is left out and the union folded
 * again, until nothing folded is past a cutoff. A backdated envelope can have admitted guests or keys
 * of its own, which is why it is refolded rather than dropped from the feed.
 */
function foldUnion(root: string, envelopes: Held[], breaks: ReadonlySet<NodeBreak>): { fold: Fold; folded: Held[] } {
  const excluded = new Set<string>();
  for (;;) {
    const result = foldInOrder(root, envelopes, excluded, breaks);
    if (breaks.has("cutoff")) return result;
    const past = result.folded.filter((h) => result.fold.pastCutoff(h.envelope, h.hash));
    if (past.length === 0) return result;
    for (const held of past) excluded.add(held.hash);
  }
}

export function computeState(root: string, envelopes: Held[], breaks: ReadonlySet<NodeBreak> = new Set()): NodeState {
  const { fold, folded } = foldUnion(root, envelopes, breaks);

  const roleOf = (key: string) => fold.keys.get(key)?.role;
  const chains = new Map<string, Map<number, Set<string>>>();
  for (const held of envelopes) {
    const role = roleOf(held.envelope.author);
    if (role !== "device" && !(role === "mail" && breaks.has("mail"))) continue;
    if (!breaks.has("cutoff") && fold.pastCutoff(held.envelope, held.hash)) continue;
    const chain = chains.get(held.envelope.author) ?? new Map<number, Set<string>>();
    chain.set(held.envelope.seq, (chain.get(held.envelope.seq) ?? new Set<string>()).add(held.hash));
    chains.set(held.envelope.author, chain);
  }
  const faults: NodeState["faults"] = [];
  const gaps: NodeState["gaps"] = [];
  const forked = new Set<string>();
  for (const [author, chain] of chains) {
    for (const [seq, hashes] of chain) {
      if (hashes.size > 1 && !breaks.has("fork")) {
        faults.push({ kind: "fork", author, seq, hashes: [...hashes].sort() });
        for (const hash of hashes) forked.add(hash);
      }
    }
    const max = Math.max(...chain.keys());
    const missing: number[] = [];
    for (let seq = 1; seq <= max; seq++) if (!chain.has(seq)) missing.push(seq);
    if (missing.length > 0 && !breaks.has("gap")) gaps.push({ author, missing });
  }

  const retracted = new Set<string>();
  for (const held of folded) {
    if (held.envelope.kind === "retract" && held.body !== undefined && typeof held.body === "object" && !Array.isArray(held.body) && held.body !== null) {
      const target = held.body["target"];
      if (typeof target === "string") retracted.add(target);
    }
  }
  const feed = folded
    .filter((h) => !isCircleState(h.envelope.kind) && h.envelope.kind !== "retract")
    .filter((h) => !retracted.has(h.hash) && !forked.has(h.hash))
    .sort(breaks.has("relay-order") ? (a, b) => envelopes.indexOf(a) - envelopes.indexOf(b) : byTimeThenHash)
    .map((h) => h.hash);

  return {
    epoch: fold.epoch,
    keys: fold.admittedKeys().map((k) => ({ key: k.key, role: k.role, identity: k.identity, revoked: k.revoked_at !== undefined })),
    feed,
    faults: faults.sort((a, b) => (a.author + a.seq < b.author + b.seq ? -1 : 1)),
    gaps: gaps.sort((a, b) => (a.author < b.author ? -1 : 1)),
  };
}

/** Reads every relay as `device` and computes the state. The circle root is what the relays report. */
export async function sync(device: Signer, relays: string[], breaks: ReadonlySet<NodeBreak> = new Set()): Promise<NodeState> {
  const pages: StoredEnvelope[][] = [];
  let root: string | undefined;
  for (const url of relays) {
    const client = new RelayClient(url, device);
    const circle = await client.circle();
    if (circle.status !== 200) throw new Error(`GET /v0/circle on ${url} answered ${circle.status}: ${circle.text}`);
    const relayRoot = (circle.body as { root: string }).root;
    if (root !== undefined && relayRoot !== root) throw new Error(`${url} roots ${relayRoot}, not ${root}`);
    root = relayRoot;
    pages.push(await client.fetchAll());
  }
  if (root === undefined) throw new Error("no relays");
  return computeState(root, union(pages, breaks), breaks);
}
