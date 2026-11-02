// The hosted install script, https://digestif.io/install.sh (docs/releases.md, "The hosted install
// script"). The Release workflow attaches a release's script to its GitHub release, and the newest
// published release is the one GitHub's releases/latest/download/install.sh names, so publishing
// a release is what publishes its script: the relay whose INSTALL_SCRIPT_URL names that address
// fetches it and answers it as its own. On SITE_HOST, the circle's bare domain, it answers that
// path and nothing else.
import { Refusal } from "./errors.ts";

export const INSTALL_PATH = "/install.sh";

/** Seconds a fetched script is kept by Cloudflare and by the client before it is asked for again. */
const MAX_AGE = 300;

export async function installScript(source: string, request: Request): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") throw new Refusal(404, "malformed", `no route ${request.method} ${INSTALL_PATH}`);
  const upstream = await fetch(source, { redirect: "follow", cf: { cacheTtl: MAX_AGE, cacheEverything: true } });
  if (!upstream.ok) {
    console.error(`install script: ${source} answered ${upstream.status}`);
    // curl -f stops on this status, so sh never runs the body.
    return new Response(`the install script could not be read (${upstream.status})\n`, { status: 502, headers: { "content-type": "text/plain; charset=utf-8" } });
  }
  const headers = { "content-type": "text/x-shellscript; charset=utf-8", "cache-control": `public, max-age=${MAX_AGE}` };
  return new Response(request.method === "HEAD" ? null : await upstream.text(), { status: 200, headers });
}
