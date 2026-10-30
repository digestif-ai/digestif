// The Digestif relay: a Cloudflare Worker with D1 implementing spec/digestif-relay.json. The four
// core routes, the mailer routes (/v0/mail, /v0/links, on the relay whose MAILER is "1"; 404
// not_mailer elsewhere) and the phone app under /app/.
import { append } from "./append.ts";
import { app, APP_PREFIX } from "./app.ts";
import { ensureCircle } from "./db.ts";
import { ConfigError, limitsOf, mailerOf, rootOf, type Relay } from "./env.ts";
import { json, Refusal } from "./errors.ts";
import { confirmLink, linkPage } from "./links.ts";
import { mail } from "./mail.ts";
import { circle, invite, page } from "./read.ts";

const INVITES = "/v0/invites/";
const LINKS = "/v0/links/";

async function route(relay: Relay, request: Request, url: URL): Promise<Response> {
  const { method } = request;
  const path = url.pathname;
  if (method === "POST" && path === "/v0/envelopes") return append(relay, request, url);
  if (method === "GET" && path === "/v0/envelopes") return page(relay, request, url);
  if (method === "GET" && path === "/v0/circle") return circle(relay, request, url);
  if (method === "GET" && path.startsWith(INVITES) && path.length > INVITES.length) {
    return invite(relay, request, url, decodeURIComponent(path.slice(INVITES.length)));
  }
  if ((method === "POST" && path === "/v0/mail") || path.startsWith(LINKS)) {
    const mailer = relay.mailer;
    if (mailer === undefined) throw new Refusal(404, "not_mailer", "this relay does not mail");
    if (path === "/v0/mail") return mail(relay, mailer, request, url);
    const id = decodeURIComponent(path.slice(LINKS.length));
    if (id !== "" && method === "GET") return linkPage(relay, request, url, id);
    if (id !== "" && method === "POST") return confirmLink(relay, request, url, id);
  }
  throw new Refusal(404, "malformed", `no route ${method} ${path}`);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === APP_PREFIX || url.pathname.startsWith(`${APP_PREFIX}/`)) return await app(env.ASSETS, request, url);
      const relay: Relay = { db: env.DB, root: rootOf(env), limits: limitsOf(env), now: new Date(), mailer: await mailerOf(env) };
      await ensureCircle(env.DB, relay.root);
      return await route(relay, request, url);
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
