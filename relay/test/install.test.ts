// The hosted install script (src/install.ts): rendered from the newest published manifest only once
// every key of the build's own signer set signed it. The two fixtures are the channel's 0.1.149
// manifest and signatures, byte for byte (a .txt so no formatter rewrites them), signed by the real
// release keys node/update/release-signers.json names.
import { env } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { testReleaseSigners } from "../../conformance/src/admission.ts";
import { bytesOf, type Json } from "../../conformance/src/encoding.ts";
import { Signer } from "../../conformance/src/keys.ts";
import worker from "../src/index.ts";
import { builtSigners, CHANNEL, renderedScript } from "../src/install.ts";
import { manifestPage, renderInstall } from "../src/install-render.ts";
import { INSTALL_TEMPLATE } from "../src/install-template.ts";
import templateFile from "../../ci/install-hosted.sh.in?raw";
import realManifest from "./fixtures/channel/0.1.149.manifest.txt?raw";
import realSignatures from "./fixtures/channel/0.1.149.manifest.sig.txt?raw";

const site = { ...env, SITE_HOST: "digestif.test" };
const realFetch = globalThis.fetch;
const asked: string[] = [];

/** Serves [files], paths relative to the channel, in place of the network; anything else is a 404. */
function channel(files: Record<string, string>): void {
  globalThis.fetch = (input: string | URL | Request) => {
    const url = new Request(input).url;
    asked.push(url);
    const path = url.startsWith(CHANNEL) ? url.slice(CHANNEL.length) : undefined;
    const body = path === undefined ? undefined : files[path];
    return Promise.resolve(body === undefined ? new Response("Not Found", { status: 404 }) : new Response(body));
  };
}

function index(versions: string[], extra: Record<string, unknown> = {}): string {
  const releases = versions.map((v) => ({ version: v, manifest: `${v}/manifest.json`, signatures: `${v}/manifest.sig.json` }));
  return JSON.stringify({ format: "digestif-feed-v0", releases, revocations: [], ...extra });
}

function manifestOf(version: string): string {
  const artifacts = [{ platform: "linux-x86_64", url: `https://example.test/${version}.tar.gz`, sha256: `sha256:${"c".repeat(64)}`, size: 1 }];
  return JSON.stringify({ format: "digestif-release-v1", version, published_at: "2026-11-23T00:00:00.000Z", notes: "n", artifacts }, null, 2);
}

function signatures(domain: string, document: string, signers: Signer[]): string {
  const signed = new Uint8Array([...bytesOf(domain), ...bytesOf(document)]);
  return JSON.stringify({ signatures: signers.map((s) => ({ key: s.key, signature: s.sign(signed) })) });
}

const real = { "index.json": index(["0.1.148", "0.1.149", "0.1.12"]), "0.1.149/manifest.json": realManifest, "0.1.149/manifest.sig.json": realSignatures };

function get(url: string, method = "GET"): Promise<Response> {
  return worker.fetch(new Request(url, { method }), site);
}

afterEach(() => {
  globalThis.fetch = realFetch;
  asked.length = 0;
});

describe("the hosted install script", () => {
  it("carries ci/install-hosted.sh.in as it stands", () => {
    expect(INSTALL_TEMPLATE).toBe(templateFile);
  });

  it("answers the template applied to the newest manifest both release keys signed", async () => {
    channel(real);
    const response = await get("https://digestif.test/install.sh");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/x-shellscript; charset=utf-8");
    const text = await response.text();
    expect(text).toBe(renderInstall(INSTALL_TEMPLATE, JSON.parse(realManifest) as Json, manifestPage("0.1.149")));
    expect(text).toContain("version='0.1.149'");
    expect(text).toContain("manifest='https://github.com/digestif-ai/digestif/tree/channel/0.1.149'");
    expect(asked).not.toContain(`${CHANNEL}0.1.148/manifest.json`);
  });

  it("answers HEAD with no body", async () => {
    channel(real);
    const response = await get("https://digestif.test/install.sh", "HEAD");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("");
  });

  it("refuses a manifest one release key did not sign, with a status curl -f stops on", async () => {
    const one = JSON.parse(realSignatures) as { signatures: unknown[] };
    channel({ ...real, "0.1.149/manifest.sig.json": JSON.stringify({ signatures: one.signatures.slice(0, 1) }) });
    const response = await get("https://digestif.test/install.sh");
    expect(response.status).toBe(502);
    expect(response.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(await response.text()).toContain("is not signed by");
  });

  it("refuses a manifest changed after it was signed", async () => {
    channel({ ...real, "0.1.149/manifest.json": realManifest.replace("b3280614", "b3280615") });
    expect((await get("https://digestif.test/install.sh")).status).toBe(502);
  });

  it("refuses a newest version it cannot verify rather than answering an older one", async () => {
    channel({ ...real, "index.json": index(["0.1.149", "0.1.150"]) });
    expect((await get("https://digestif.test/install.sh")).status).toBe(502);
  });

  it("refuses when the channel cannot be read", async () => {
    channel({});
    expect((await get("https://digestif.test/install.sh")).status).toBe(502);
  });

  it("judges by the build's signer set, never the RELEASE_SIGNERS the top level sets", async () => {
    expect(site.RELEASE_SIGNERS).toBeTruthy();
    const test = testReleaseSigners();
    const manifest = manifestOf("9.9.9");
    channel({ "index.json": index(["9.9.9"]), "9.9.9/manifest.json": manifest, "9.9.9/manifest.sig.json": signatures("DIGESTIF-RELEASE-V0\n", manifest, test) });
    const response = await get("https://digestif.test/install.sh");
    expect(response.status).toBe(502);
    expect(builtSigners()).not.toContain(test[0]?.key);
  });

  it("is not answered on any host but SITE_HOST: elsewhere it is one more circle route without an address", async () => {
    channel(real);
    expect((await worker.fetch(new Request("http://relay.test/install.sh"), site)).status).toBe(410);
    expect((await worker.fetch(new Request("https://digestif.test/install.sh"), { ...env, SITE_HOST: undefined })).status).toBe(410);
    expect(asked).toEqual([]);
  });

  it("answers nothing else on the bare domain", async () => {
    channel(real);
    for (const path of ["/", "/v0/circle", "/app/"]) expect((await get(`https://digestif.test${path}`)).status, path).toBe(404);
    expect(asked).toEqual([]);
  });
});

describe("the newest version", () => {
  const signers = testReleaseSigners();
  const keys = signers.map((s) => s.key);
  const files = (versions: string[], extra: Record<string, unknown> = {}): Record<string, string> => {
    const out: Record<string, string> = { "index.json": index(versions, extra) };
    for (const v of versions) {
      out[`${v}/manifest.json`] = manifestOf(v);
      out[`${v}/manifest.sig.json`] = signatures("DIGESTIF-RELEASE-V0\n", manifestOf(v), signers);
    }
    return out;
  };
  const recall = (version: string, by: Signer[]): Record<string, string> => {
    const document = JSON.stringify({ format: "digestif-recall-v0", version, reason: "r", recalled_at: "2026-11-23T00:00:00.000Z" });
    return { [`recalls/${version}.json`]: document, [`recalls/${version}.sig.json`]: signatures("DIGESTIF-RECALL-V0\n", document, by) };
  };
  const recalls = (version: string) => ({ recalls: [{ version, document: `recalls/${version}.json`, signatures: `recalls/${version}.sig.json` }] });

  it("is the highest version by its numbers, not the last listed", async () => {
    channel(files(["0.2.10", "0.2.9"]));
    expect(await renderedScript(keys)).toContain("version='0.2.10'");
  });

  it("skips a version a key of the set recalled", async () => {
    channel({ ...files(["0.2.9", "0.2.10"], recalls("0.2.10")), ...recall("0.2.10", signers.slice(1)) });
    expect(await renderedScript(keys)).toContain("version='0.2.9'");
  });

  it("keeps a version a recall by a key outside the set names", async () => {
    const outsider = [Signer.random()];
    channel({ ...files(["0.2.9", "0.2.10"], recalls("0.2.10")), ...recall("0.2.10", outsider) });
    expect(await renderedScript(keys)).toContain("version='0.2.10'");
  });

  it("refuses a manifest whose version is not the one the index lists", async () => {
    const f = files(["0.2.10"]);
    channel({ ...f, "0.2.10/manifest.json": manifestOf("0.2.11"), "0.2.10/manifest.sig.json": signatures("DIGESTIF-RELEASE-V0\n", manifestOf("0.2.11"), signers) });
    await expect(renderedScript(keys)).rejects.toThrow("the index lists 0.2.10");
  });

  it("refuses an index entry that is not https", async () => {
    channel({ "index.json": JSON.stringify({ format: "digestif-feed-v0", releases: [{ version: "1.0.0", manifest: "file:///etc/passwd", signatures: "x" }] }) });
    await expect(renderedScript(keys)).rejects.toThrow("not https");
  });
});

describe("the signer set the channel's signers/ chain leaves", () => {
  const start = testReleaseSigners();
  const startKeys = start.map((s) => s.key);
  const [a, b] = start as [Signer, Signer];
  const c = Signer.random();
  const d = Signer.random();

  /** A digestif-signers-v0 naming [next], at signers/<name>, signed by [by]. */
  const change = (name: string, next: Signer[], by: Signer[], createdAt: string): Record<string, string> => {
    const document = JSON.stringify({ format: "digestif-signers-v0", created_at: createdAt, signers: next.map((s, i) => ({ name: `s${i}`, key: s.key })) });
    return { [`signers/${name}.json`]: document, [`signers/${name}.sig.json`]: signatures("DIGESTIF-SIGNERS-V0\n", document, by) };
  };
  const revocation = (name: string, key: Signer, by: Signer[]): Record<string, string> => {
    const document = JSON.stringify({ format: "digestif-revocation-v0", key: key.key, reason: "leaked", revoked_at: "2026-11-23T00:00:00.000Z" });
    return { [`revocations/${name}.json`]: document, [`revocations/${name}.sig.json`]: signatures("DIGESTIF-REVOCATION-V0\n", document, by) };
  };
  const entries = (dir: string, names: string[]) => names.map((n) => ({ document: `${dir}/${n}.json`, signatures: `${dir}/${n}.sig.json` }));
  /** Version 1.0.0 signed by [by], under an index listing the signers/ and revocations/ documents named. */
  const release = (by: Signer[], signerNames: string[], revocationNames: string[] = []): Record<string, string> => ({
    "index.json": index(["1.0.0"], { signers: entries("signers", signerNames), revocations: entries("revocations", revocationNames) }),
    "1.0.0/manifest.json": manifestOf("1.0.0"),
    "1.0.0/manifest.sig.json": signatures("DIGESTIF-RELEASE-V0\n", manifestOf("1.0.0"), by),
  });

  it("verifies a release the new set signed once a change both sets signed is on the channel", async () => {
    channel({ ...release([b, c], ["1"]), ...change("1", [b, c], [a, b, c], "2026-11-20T00:00:00.000Z") });
    expect(await renderedScript(startKeys)).toContain("version='1.0.0'");
  });

  it("refuses a release only the keys the chain removed signed", async () => {
    channel({ ...release([a, b], ["1"]), ...change("1", [b, c], [a, b, c], "2026-11-20T00:00:00.000Z") });
    await expect(renderedScript(startKeys)).rejects.toThrow("is not signed by " + c.key);
  });

  it("folds the chain link by link in created_at order, whatever order the index lists it in", async () => {
    channel({
      ...release([c, d], ["2", "1"]),
      ...change("1", [b, c], [a, b, c], "2026-11-20T00:00:00.000Z"),
      ...change("2", [c, d], [b, c, d], "2026-11-21T00:00:00.000Z"),
    });
    expect(await renderedScript(startKeys)).toContain("version='1.0.0'");
  });

  it("adopts no change a key of the current set did not sign", async () => {
    channel({ ...release([b, c], ["1"]), ...change("1", [b, c], [b, c], "2026-11-20T00:00:00.000Z") });
    await expect(renderedScript(startKeys)).rejects.toThrow("is not signed by " + a.key);
  });

  it("adopts no change a key of the new set did not sign", async () => {
    channel({ ...release([b, c], ["1"]), ...change("1", [b, c], [a, b], "2026-11-20T00:00:00.000Z") });
    await expect(renderedScript(startKeys)).rejects.toThrow("is not signed by " + a.key);
  });

  it("adopts no change naming a revoked key", async () => {
    channel({ ...release([b, c], ["1"], ["c"]), ...change("1", [b, c], [a, b, c], "2026-11-20T00:00:00.000Z"), ...revocation("c", c, [a]) });
    await expect(renderedScript(startKeys)).rejects.toThrow("is not signed by " + a.key);
  });

  it("refuses while a key of the set is revoked, by a revocation a key of the set signed", async () => {
    channel({ ...release([a, b], [], ["a"]), ...revocation("a", a, [b]) });
    await expect(renderedScript(startKeys)).rejects.toThrow(`the signer set holds the revoked ${a.key}`);
  });

  it("ignores a revocation no key of the set signed", async () => {
    channel({ ...release([a, b], [], ["a"]), ...revocation("a", a, [d]) });
    expect(await renderedScript(startKeys)).toContain("version='1.0.0'");
  });

  it("serves once a change takes the revoked key out", async () => {
    channel({ ...release([b, c], ["1"], ["a"]), ...revocation("a", a, [b]), ...change("1", [b, c], [a, b, c], "2026-11-20T00:00:00.000Z") });
    expect(await renderedScript(startKeys)).toContain("version='1.0.0'");
  });

  it("refuses when a signers/ document it lists cannot be read", async () => {
    const files = { ...release([a, b], ["1"]) };
    channel(files);
    await expect(renderedScript(startKeys)).rejects.toThrow("signers/1.json answered 404");
  });
});
