// The Digestif relay: a Cloudflare Worker with D1 implementing spec/digestif-relay.json. The
// scaffold: the routes exist and refuse as the spec says a relay with nobody admitted does. The
// handlers land with the stories that follow (D1.2 to D1.5); the mailer routes (/v0/mail,
// /v0/links) belong to a later epic and answer not_mailer until then.
import { ensureCircle } from "./db.ts";
import { ConfigError, limitsOf, rootOf, type Relay } from "./env.ts";
import { json, Refusal } from "./errors.ts";

const INVITES = "/v0/invites/";

function route(_relay: Relay, request: Request, url: URL): Promise<Response> {
  const { method } = request;
  const path = url.pathname;
  const signed =
    (method === "POST" && path === "/v0/envelopes") ||
    (method === "GET" && path === "/v0/envelopes") ||
    (method === "GET" && path === "/v0/circle") ||
    (method === "GET" && path.startsWith(INVITES) && path.length > INVITES.length);
  if (signed) throw new Refusal(401, "not_admitted", "Digestif-Key is required");
  if ((method === "POST" && path === "/v0/mail") || path.startsWith("/v0/links/")) {
    throw new Refusal(404, "not_mailer", "this relay does not mail");
  }
  throw new Refusal(404, "malformed", `no route ${method} ${path}`);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      const relay: Relay = { db: env.DB, root: rootOf(env), limits: limitsOf(env), now: new Date() };
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
