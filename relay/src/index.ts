// The Digestif relay: a Cloudflare Worker implementing spec/digestif-relay.json, hosting many circles
// (docs/protocol.md, Hosted circles). Each circle's routes live at its address, /c/<root hex>: the
// core routes, the mailer routes (/v0/mail, /v0/links, on the relay whose MAILER is "1"; 404
// not_mailer elsewhere) and its own bootstrap read. The home circle answers the same routes
// unprefixed. Three routes are the relay's own: the unsigned GET /v0/version and GET /v0/relay, and
// the bootstrap read GET /v0/invites/<invite key> across every circle. Beside them, the phone app
// under /app/ and the hosted install script at /install.sh on the relay whose INSTALL_SCRIPT_URL
// is set (src/install.ts).
import { envelopeHash } from "../../conformance/src/envelope.ts";
import { append, appendRaw, parseSigned, readBody, throttle } from "./append.ts";
import { app, APP_PREFIX } from "./app.ts";
import { addressOf, baseOf, checkState, circlePath, databaseFor, found, homeRow, hostedRow, inviteCircle, recordUnprefixed, unfound, type HostedRow } from "./circles.ts";
import { ensureCircle } from "./db.ts";
import { INSTALL_PATH, installScript } from "./install.ts";
import { ConfigError, homeOf, hostingOf, limitsOf, mailerOf, type HostingLimits, type Relay } from "./env.ts";
import { empty, isMovingAbort, json, moving, Refusal } from "./errors.ts";
import { confirmLink, linkPage } from "./links.ts";
import { mail } from "./mail.ts";
import { circle, invite, page } from "./read.ts";
import { relayInfo } from "./relay-info.ts";
import { releaseSignersOf } from "./signers.ts";
import { version } from "./version.ts";

// The class of each circle's store (src/store.ts), exported so the Worker's CIRCLE_STORE binding names it.
export { CircleStore } from "./store.ts";

const INVITES = "/v0/invites/";
const LINKS = "/v0/links/";

/** A path segment decoded, or 400 malformed for an escape that decodes to nothing (`%E0`, `%zz`). */
export function decodePath(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    throw new Refusal(400, "malformed", `the path segment ${segment} is not a valid percent-encoding`);
  }
}

/** One circle's routes, [path] being the part after its address. */
async function route(relay: Relay, request: Request, url: URL, path: string): Promise<Response> {
  const { method } = request;
  if (method === "POST" && path === "/v0/envelopes") return append(relay, request, url);
  if (method === "GET" && path === "/v0/envelopes") return page(relay, request, url);
  if (method === "GET" && path === "/v0/circle") return circle(relay, request, url);
  if (method === "GET" && path.startsWith(INVITES) && path.length > INVITES.length) {
    return invite(relay, request, url, decodePath(path.slice(INVITES.length)));
  }
  if ((method === "POST" && path === "/v0/mail") || path.startsWith(LINKS)) {
    const mailer = relay.mailer;
    if (mailer === undefined) throw new Refusal(404, "not_mailer", "this relay does not mail");
    if (path === "/v0/mail") return mail(relay, mailer, request, url);
    const id = decodePath(path.slice(LINKS.length));
    if (id !== "" && method === "GET") return linkPage(relay, request, url, id);
    if (id !== "" && method === "POST") return confirmLink(relay, request, url, id);
  }
  throw new Refusal(404, "malformed", `no route ${method} ${url.pathname}`);
}

/** What one request knows of the relay before it reaches a circle. */
interface Context {
  env: Env;
  request: Request;
  url: URL;
  now: Date;
  hosting: HostingLimits;
  home: string | null;
}

/** The per-circle context the routes take, over the store the registry row names. */
async function relayFor(context: Context, row: HostedRow): Promise<Relay> {
  const { env, url, now, hosting } = context;
  const relay: Relay = {
    db: databaseFor(env, row),
    root: row.root,
    address: addressOf(baseOf(env, url), row.root),
    limits: limitsOf(env),
    hosting,
    registry: env.DB,
    now,
    mailer: await mailerOf(env),
    releaseSigners: releaseSignersOf(env),
  };
  await ensureCircle(relay.db, relay.root);
  return relay;
}

/** The registry row of a circle: the home circle's made on its first request; undefined for one the relay does not host. */
async function rowOf(context: Context, root: string): Promise<HostedRow | undefined> {
  if (root === context.home) return homeRow(context.env, root, context.hosting, context.now);
  return hostedRow(context.env.DB, root);
}

/** A request to the circle [root], [path] the part after its address. */
async function circleRequest(context: Context, root: string, path: string): Promise<Response> {
  const row = await rowOf(context, root);
  if (row === undefined) {
    if (context.request.method === "POST" && path === "/v0/envelopes") return foundCircle(context, root);
    throw new Refusal(404, "circle_unknown", `this relay hosts no circle ${root}`);
  }
  checkState(row, context.request.method === "POST");
  return route(await relayFor(context, row), context.request, context.url, path);
}

/**
 * The bootstrap append of a root this relay does not host yet: the founding of its circle
 * (src/circles.ts, found). Nothing else may reach a circle before its root does. A store that
 * refuses the root closes the circle again.
 */
async function foundCircle(context: Context, root: string): Promise<Response> {
  const { env, request, url, now, hosting } = context;
  const limits = limitsOf(env);
  const raw = await readBody({ limits }, request);
  if (envelopeHash(parseSigned(raw).envelope) !== root) throw new Refusal(404, "circle_unknown", `this relay hosts no circle ${root}; only its root may open it`);
  const row = await found(env, { root, home: context.home, request, url, hosting, now, skewSeconds: limits.skew_seconds });
  try {
    return await appendRaw(await relayFor(context, row), request, url, raw);
  } catch (error) {
    if (error instanceof Refusal) await unfound(env, root);
    throw error;
  }
}

/** The relay's own bootstrap read: the circle the invite key opens, by the index; the home circle's when the index has none. */
async function inviteAnywhere(context: Context, key: string): Promise<Response> {
  const root = (await inviteCircle(context.env.DB, key)) ?? context.home;
  if (root === null) return empty(404);
  const row = await rowOf(context, root);
  if (row === undefined) return empty(404);
  checkState(row, false);
  return invite(await relayFor(context, row), context.request, context.url, key);
}

async function serve(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const install = env.INSTALL_SCRIPT_URL;
  if (install !== undefined && install !== "" && url.pathname === INSTALL_PATH) return installScript(install, request);
  if (env.SITE_HOST !== undefined && env.SITE_HOST !== "" && url.hostname === env.SITE_HOST) {
    throw new Refusal(404, "malformed", `no route ${request.method} ${url.pathname}`);
  }
  if (url.pathname === APP_PREFIX || url.pathname.startsWith(`${APP_PREFIX}/`)) return app(env.ASSETS, request, url);
  const path = url.pathname;
  if (request.method === "GET" && path === "/v0/version") return version();
  const context: Context = { env, request, url, now: new Date(), hosting: hostingOf(env), home: homeOf(env) };
  if (request.method === "GET" && path === "/v0/relay") return relayInfo(env, context.home, context.hosting);
  if (request.method === "POST" && path.endsWith("/v0/envelopes")) await throttle(env.APPEND_LIMITER, request);
  const scoped = circlePath(path);
  if (scoped !== undefined) {
    // The relay's own unsigned reads answer at a circle's address too: a node keeps that address as its relay url.
    if (request.method === "GET" && scoped.rest === "/v0/version") return version();
    if (request.method === "GET" && scoped.rest === "/v0/relay") return relayInfo(env, context.home, context.hosting);
    return circleRequest(context, scoped.root, scoped.rest);
  }
  if (request.method === "GET" && path.startsWith(INVITES) && path.length > INVITES.length) return inviteAnywhere(context, decodePath(path.slice(INVITES.length)));
  // An unprefixed route: the home circle's, at the address every node used before relays hosted many circles.
  if (context.home === null) throw new Refusal(404, "circle_unknown", "this relay has no home circle: a circle's routes are under /c/<the 64 hex digits of its root>");
  await recordUnprefixed(env.DB, context.now);
  return circleRequest(context, context.home, path);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await serve(request, env);
    } catch (error) {
      if (error instanceof Refusal) return error.response();
      if (isMovingAbort(error)) return moving().response();
      if (error instanceof ConfigError) {
        console.error(`digestif-relay misconfigured: ${error.message}`);
        return json(500, { code: "malformed", message: `the relay is misconfigured: ${error.message}` });
      }
      console.error(error);
      return json(500, { code: "malformed", message: "the relay failed to handle this request" });
    }
  },
} satisfies ExportedHandler<Env>;
