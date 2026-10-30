// The phone app, docs/protocol.md "The phone": the node's web UI built for a phone, served as
// static assets under /app/ (wrangler.jsonc: assets.directory, run_worker_first, and
// html_handling none so the binding never redirects to a path without the prefix). The Worker
// strips the prefix and answers index.html for a path the build has no file for, so /app/ itself
// and the app's client-side routes load on a reload.
import { Refusal } from "./errors.ts";

export const APP_PREFIX = "/app";

export async function app(assets: Fetcher, request: Request, url: URL): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") throw new Refusal(404, "malformed", `no route ${request.method} ${url.pathname}`);
  if (url.pathname === APP_PREFIX) return Response.redirect(new URL(`${APP_PREFIX}/${url.search}`, url).toString(), 302);
  const inner = new URL(url);
  inner.pathname = url.pathname.slice(APP_PREFIX.length);
  const found = await assets.fetch(new Request(inner, request));
  if (found.status !== 404) return found;
  inner.pathname = "/index.html";
  inner.search = "";
  return assets.fetch(new Request(inner, { method: request.method, headers: request.headers }));
}
