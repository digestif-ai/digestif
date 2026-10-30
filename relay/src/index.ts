// The Digestif relay: a Cloudflare Worker with D1 implementing spec/digestif-relay.json. The four
// core routes are here; the mailer routes (/v0/mail, /v0/links) belong to a later epic and answer
// not_mailer until then.
import { append } from "./append.ts";
import { ensureCircle } from "./db.ts";
import { ConfigError, limitsOf, rootOf, type Relay } from "./env.ts";
import { json, Refusal } from "./errors.ts";
import { circle, invite, page } from "./read.ts";

const INVITES = "/v0/invites/";

async function route(relay: Relay, request: Request, url: URL): Promise<Response> {
  const { method } = request;
  const path = url.pathname;
  if (method === "POST" && path === "/v0/envelopes") return append(relay, request, url);
  if (method === "GET" && path === "/v0/envelopes") return page(relay, request, url);
  if (method === "GET" && path === "/v0/circle") return circle(relay, request, url);
  if (method === "GET" && path.startsWith(INVITES) && path.length > INVITES.length) {
    return invite(relay, request, url, decodeURIComponent(path.slice(INVITES.length)));
  }
  if ((method === "POST" && path === "/v0/mail") || path.startsWith("/v0/links/")) {
    throw new Refusal(404, "not_mailer", "this relay does not mail");
  }
  throw new Refusal(404, "malformed", `no route ${method} ${path}`);
}

/** D1 reports a lost race (two appends taking one relay_id, or one hash) as a UNIQUE failure; the append is re-run once. */
function isUniqueConflict(error: unknown): boolean {
  return error instanceof Error && /UNIQUE constraint failed/.test(error.message);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      const relay: Relay = { db: env.DB, root: rootOf(env), limits: limitsOf(env), now: new Date() };
      await ensureCircle(env.DB, relay.root);
      const retry = request.method === "POST" ? request.clone() : undefined;
      try {
        return await route(relay, request, url);
      } catch (error) {
        if (!isUniqueConflict(error) || retry === undefined) throw error;
        return await route({ ...relay, now: new Date() }, retry, url);
      }
    } catch (error) {
      if (error instanceof Refusal) return error.response();
      if (error instanceof ConfigError) {
        console.error(`digestif-relay misconfigured: ${error.message}`);
        return json(500, { code: "malformed", message: `the relay is misconfigured: ${error.message}` });
      }
      console.error(error);
      return json(500, { code: "malformed", message: "the relay failed to handle this request" });
    }
  },
} satisfies ExportedHandler<Env>;
