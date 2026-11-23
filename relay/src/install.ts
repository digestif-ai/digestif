// The hosted install script, https://digestif.io/install.sh (docs/releases.md, "The hosted install
// script"). The relay renders it: it reads the newest published node version off the channel, checks
// that every key of the signer set the channel's signers/ chain leaves signed its manifest, and
// answers the install template (src/install-template.ts, ci/install-hosted.sh.in's copy) applied to that manifest. Anything it
// cannot read or verify is answered with a status `curl -f` stops on, never a script, so nothing
// a channel or release writer replaces reaches a member who did not see both signatures on it.
// The chain is folded from the set this build carries (node/update/release-signers.json, never the
// RELEASE_SIGNERS override, which only the conformance suite's top level sets), each link checked
// against the set before it with the channel's revocations applied, as a node's Policy.adopt_sets
// folds it (docs/releases.md, "Changing the signer set"); a set left holding a revoked key halts it.
// On SITE_HOST, the circle's bare domain, it answers this path and nothing else.
import "../../conformance/src/node-crypto.ts";
import { SignerSet, signerKeysOf, validSigners, type SignedDocument } from "../../conformance/src/admission.ts";
import { bytesOf, type Json } from "../../conformance/src/encoding.ts";
import { parseUnique } from "../../conformance/src/strict-json.ts";
import built from "../../node/update/release-signers.json";
import { Refusal } from "./errors.ts";
import { manifestPage, renderInstall, RenderError } from "./install-render.ts";
import { INSTALL_TEMPLATE } from "./install-template.ts";

export const INSTALL_PATH = "/install.sh";

/** The node's default channel (docs/releases.md, The channel): the root of the channel branch. */
export const CHANNEL = "https://raw.githubusercontent.com/digestif-ai/digestif/channel/";

const RELEASE_DOMAIN = "DIGESTIF-RELEASE-V0\n";
const RECALL_DOMAIN = "DIGESTIF-RECALL-V0\n";

/** Seconds a channel document and the rendered script are kept by Cloudflare and by the client. */
const MAX_AGE = 300;

/** The most of any channel document read, as a node bounds it. */
const MAX_DOCUMENT_BYTES = 1024 * 1024;

/** What stopped the script being rendered; logged, and answered as 502. */
class Unverified extends Error {}

/** The keys of the signer set this build carries: where the fold of the channel's signers/ chain starts. */
export function builtSigners(): string[] {
  const keys = signerKeysOf(built);
  if (keys === undefined) throw new Unverified("node/update/release-signers.json is not a digestif-signers-v0 of at least two keys");
  return keys;
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** An index entry's https url: a path relative to the channel or an https url, never anything else. */
function channelUrl(entry: Json | undefined): string {
  if (typeof entry !== "string") throw new Unverified(`the index names ${JSON.stringify(entry)} where a document belongs`);
  const url = new URL(entry, CHANNEL);
  if (url.protocol !== "https:") throw new Unverified(`the index names ${entry}, which is not https`);
  return url.href;
}

/** A channel document's exact bytes, at most MAX_DOCUMENT_BYTES. */
async function read(url: string): Promise<Uint8Array> {
  const response = await fetch(url, { redirect: "follow", cf: { cacheTtl: MAX_AGE, cacheEverything: true } });
  if (!response.ok) throw new Unverified(`${url} answered ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > MAX_DOCUMENT_BYTES) throw new Unverified(`${url} is larger than ${MAX_DOCUMENT_BYTES} bytes`);
  return bytes;
}

function parse(bytes: Uint8Array, what: string): Json {
  try {
    return parseUnique(new TextDecoder().decode(bytes), what) as Json;
  } catch (error) {
    throw new Unverified(`${what} is not JSON holding each member once: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/** The signatures a channel signatures document lists; any entry not a key and a signature is left out. */
async function signaturesAt(signaturesUrl: string, what: string): Promise<SignedDocument["signatures"]> {
  const body = parse(await read(signaturesUrl), `${what}'s signatures`);
  const signatures: SignedDocument["signatures"] = [];
  if (isObject(body) && Array.isArray(body["signatures"])) {
    for (const s of body["signatures"]) {
      if (isObject(s) && typeof s["key"] === "string" && typeof s["signature"] === "string") signatures.push({ key: s["key"], signature: s["signature"] });
    }
  }
  return signatures;
}

/** The keys whose signature over the domain line and [bytes] verifies. */
async function signedBy(domain: string, bytes: Uint8Array, signaturesUrl: string, what: string): Promise<Set<string>> {
  return validSigners(domain, { bytes, value: {}, signatures: await signaturesAt(signaturesUrl, what) });
}

/** Every document an index list (`signers`, `revocations`) names, with its signatures; an entry that cannot be read refuses the script. */
async function signedDocuments(index: { [key: string]: Json }, list: string): Promise<SignedDocument[]> {
  const out: SignedDocument[] = [];
  const entries = index[list];
  if (entries === undefined) return out;
  if (!Array.isArray(entries)) throw new Unverified(`the index's ${list} is not a list`);
  for (const entry of entries) {
    if (!isObject(entry)) throw new Unverified(`the index's ${list} holds ${JSON.stringify(entry)}`);
    const url = channelUrl(entry["document"]);
    const bytes = await read(url);
    const value = parse(bytes, url);
    if (!isObject(value)) throw new Unverified(`${url} is not a JSON object`);
    out.push({ bytes, value, signatures: await signaturesAt(channelUrl(entry["signatures"]), url) });
  }
  return out;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}

/**
 * The signer set the channel's signers/ chain leaves, folded from [start] as node/update/lib/policy.ml's
 * adopt_sets folds it: each distinct change in created_at order, adopted when every key of the set
 * before it and of the new set signed it over DIGESTIF-SIGNERS-V0 and the new set has at least two
 * keys, none twice and none revoked; in passes until one adopts nothing, so the order the index lists
 * them in does not matter; the channel's revocations applied before the first link and after every
 * one, a revocation counting when a key of the set signed it. A change a node would skip as unreadable
 * (a created_at that is not a string) is skipped here too.
 */
export async function channelSigners(index: { [key: string]: Json }, start: string[]): Promise<SignerSet> {
  const set = new SignerSet(start);
  const revocations = await signedDocuments(index, "revocations");
  const revoke = () => {
    for (const r of revocations) set.revokeDocument(r);
  };
  revoke();
  const createdAt = (d: SignedDocument) => d.value["created_at"] ?? "";
  let pending: SignedDocument[] = [];
  for (const change of await signedDocuments(index, "signers")) {
    if (typeof createdAt(change) !== "string") continue;
    if (!pending.some((d) => sameBytes(d.bytes, change.bytes))) pending.push(change);
  }
  pending.sort((a, b) => {
    const x = createdAt(a) as string;
    const y = createdAt(b) as string;
    return x < y ? -1 : x > y ? 1 : 0;
  });
  for (let progress = true; progress; ) {
    progress = false;
    const rest: SignedDocument[] = [];
    for (const change of pending) {
      if (set.adoptDocument(change)) {
        progress = true;
        revoke();
      } else rest.push(change);
    }
    pending = rest;
  }
  return set;
}

/** A version's numbers, or undefined for one that is not MAJOR.MINOR.PATCH. */
function versionOf(text: Json | undefined): number[] | undefined {
  if (typeof text !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(text)) return undefined;
  return text.split(".").map(Number);
}

function newer(a: number[], b: number[]): boolean {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i]! > b[i]!;
  return false;
}

/**
 * The versions a recall the channel lists takes out, a recall counting when any key of [keys]
 * signed it, as a node's recall_of counts one (node/update/lib/policy.ml).
 */
async function recalled(index: { [key: string]: Json }, keys: string[]): Promise<Set<string>> {
  const out = new Set<string>();
  const recalls = index["recalls"];
  if (!Array.isArray(recalls)) return out;
  for (const entry of recalls) {
    if (!isObject(entry)) continue;
    const bytes = await read(channelUrl(entry["document"]));
    const recall = parse(bytes, "a recall");
    if (!isObject(recall) || recall["format"] !== "digestif-recall-v0" || typeof recall["version"] !== "string") continue;
    const valid = await signedBy(RECALL_DOMAIN, bytes, channelUrl(entry["signatures"]), `the recall of ${recall["version"]}`);
    if (keys.some((k) => valid.has(k))) out.add(recall["version"]);
  }
  return out;
}

/** The newest version the index publishes that no recall takes out. */
function newest(index: { [key: string]: Json }, taken: Set<string>): { [key: string]: Json } {
  let best: { entry: { [key: string]: Json }; numbers: number[] } | undefined;
  const releases = index["releases"];
  for (const entry of Array.isArray(releases) ? releases : []) {
    if (!isObject(entry)) continue;
    const numbers = versionOf(entry["version"]);
    if (numbers === undefined || taken.has(entry["version"] as string)) continue;
    if (best === undefined || newer(numbers, best.numbers)) best = { entry, numbers };
  }
  if (best === undefined) throw new Unverified("the channel publishes no version");
  return best.entry;
}

/**
 * The newest published node version's install script, rendered only from a manifest every key of the
 * set the channel's signers/ chain leaves from [start] signed, and only while no key of that set is revoked.
 */
export async function renderedScript(start: string[]): Promise<string> {
  const index = parse(await read(new URL("index.json", CHANNEL).href), "the channel's index.json");
  if (!isObject(index) || index["format"] !== "digestif-feed-v0") throw new Unverified("the channel's index.json is not a digestif-feed-v0");
  const set = await channelSigners(index, start);
  const halted = set.keys.filter((k) => set.revoked.has(k));
  if (halted.length > 0) throw new Unverified(`the signer set holds the revoked ${halted.join(", ")}`);
  const keys = set.keys;
  const entry = newest(index, await recalled(index, keys));
  const version = entry["version"] as string;
  const bytes = await read(channelUrl(entry["manifest"]));
  const valid = await signedBy(RELEASE_DOMAIN, bytes, channelUrl(entry["signatures"]), `${version}'s manifest`);
  const missing = keys.filter((k) => !valid.has(k));
  if (missing.length > 0) throw new Unverified(`${version}'s manifest is not signed by ${missing.join(", ")}`);
  const manifest = parse(bytes, `${version}'s manifest`);
  if (!isObject(manifest) || manifest["format"] !== "digestif-release-v1") throw new Unverified(`${version}'s manifest is not a digestif-release-v1`);
  if (manifest["version"] !== version) throw new Unverified(`the index lists ${version} at a manifest of ${JSON.stringify(manifest["version"])}`);
  try {
    return renderInstall(INSTALL_TEMPLATE, manifest, manifestPage(version));
  } catch (error) {
    if (error instanceof RenderError) throw new Unverified(`${version}: ${error.message}`);
    throw error;
  }
}

export async function installScript(request: Request): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") throw new Refusal(404, "malformed", `no route ${request.method} ${INSTALL_PATH}`);
  let script: string;
  try {
    script = await renderedScript(builtSigners());
  } catch (error) {
    // A channel that cannot be reached is refused as one that does not verify.
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`install script: ${reason}`);
    // curl -f stops on this status, so sh never runs the body.
    return new Response(`the install script could not be verified: ${reason}\n`, { status: 502, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
  }
  const headers = { "content-type": "text/x-shellscript; charset=utf-8", "cache-control": `public, max-age=${MAX_AGE}` };
  return new Response(request.method === "HEAD" ? null : bytesOf(script), { status: 200, headers });
}
