// The relay's configuration: its home circle, the limits, the hosting limits and the mailer, Worker
// variables and secrets per deployment.
import { importEncryptionKey, unb64url } from "../../node/mail/webcrypto/mail.mjs";

export interface RelayLimits {
  max_envelope_bytes: number;
  max_appends_per_device_per_day: number;
  max_page_size: number;
  skew_seconds: number;
}

/** docs/protocol.md "Relay limits". */
export const DEFAULT_LIMITS: RelayLimits = {
  max_envelope_bytes: 65536,
  max_appends_per_device_per_day: 500,
  max_page_size: 500,
  skew_seconds: 3600,
};

export class ConfigError extends Error {}

function limit(name: string, value: string | undefined, fallback: number): number {
  if (value === undefined || value === "") return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw new ConfigError(`${name} must be a positive integer, not ${JSON.stringify(value)}`);
  return n;
}

export function limitsOf(env: Env): RelayLimits {
  return {
    max_envelope_bytes: limit("MAX_ENVELOPE_BYTES", env.MAX_ENVELOPE_BYTES, DEFAULT_LIMITS.max_envelope_bytes),
    max_appends_per_device_per_day: limit("MAX_APPENDS_PER_DEVICE_PER_DAY", env.MAX_APPENDS_PER_DEVICE_PER_DAY, DEFAULT_LIMITS.max_appends_per_device_per_day),
    max_page_size: limit("MAX_PAGE_SIZE", env.MAX_PAGE_SIZE, DEFAULT_LIMITS.max_page_size),
    skew_seconds: limit("SKEW_SECONDS", env.SKEW_SECONDS, DEFAULT_LIMITS.skew_seconds),
  };
}

export const ROOT = /^sha256:[0-9a-f]{64}$/;

/**
 * The home circle (docs/protocol.md, Hosted circles): the root HOME_ROOT names, read from
 * CIRCLE_ROOT while HOME_ROOT is unset, so a deployment configured before relays hosted many
 * circles keeps its circle as home. Null on a relay with neither set: it has no home and hosts
 * nothing until its operator founds one.
 */
export function homeOf(env: Env): string | null {
  for (const name of ["HOME_ROOT", "CIRCLE_ROOT"] as const) {
    const value = env[name];
    if (value === undefined || value === "") continue;
    if (!ROOT.test(value)) throw new ConfigError(`${name} must be the home circle root's hash (its circle or founding dinner envelope), sha256:<64 hex>`);
    return value;
  }
  return null;
}

/** What hosting circles may spend (docs/protocol.md, Hosted circles), each a Worker variable with a default. */
export interface HostingLimits {
  /** Whether the relay opens new circles at all: HOSTING "0" or "off" stops it (not_hosting). */
  hosting: boolean;
  /** Bytes every hosted circle's reserved share must fit in together (relay_full). */
  relay_storage: number;
  /** Bytes one circle's store may hold, and the share each reserves (circle_full). */
  circle_storage: number;
  /** Circles one vouching member may open on this relay per 30 days (too_many_circles). */
  circles_per_member: number;
  /** Rows the home circle's move copies a day; 0 keeps the home circle on D1. */
  move_rows_per_day: number;
}

const GiB = 1024 * 1024 * 1024;
const MiB = 1024 * 1024;

export const DEFAULT_HOSTING: HostingLimits = {
  hosting: true,
  relay_storage: 4 * GiB,
  circle_storage: 256 * MiB,
  circles_per_member: 5,
  move_rows_per_day: 20_000,
};

/** A non-negative integer variable: 0 is a value (MOVE_ROWS_PER_DAY 0 keeps the home circle on D1). */
function count(name: string, value: string | undefined, fallback: number): number {
  if (value === undefined || value === "") return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0) throw new ConfigError(`${name} must be a non-negative integer, not ${JSON.stringify(value)}`);
  return n;
}

export function hostingOf(env: Env): HostingLimits {
  const switched = env.HOSTING;
  if (switched !== undefined && !["", "1", "on", "0", "off"].includes(switched)) throw new ConfigError(`HOSTING must be on or off, not ${JSON.stringify(switched)}`);
  return {
    hosting: switched !== "0" && switched !== "off",
    relay_storage: limit("RELAY_STORAGE", env.RELAY_STORAGE, DEFAULT_HOSTING.relay_storage),
    circle_storage: limit("CIRCLE_STORAGE", env.CIRCLE_STORAGE, DEFAULT_HOSTING.circle_storage),
    circles_per_member: limit("CIRCLES_PER_MEMBER", env.CIRCLES_PER_MEMBER, DEFAULT_HOSTING.circles_per_member),
    move_rows_per_day: count("MOVE_ROWS_PER_DAY", env.MOVE_ROWS_PER_DAY, DEFAULT_HOSTING.move_rows_per_day),
  };
}

/** The mailing relay's half of the configuration (docs/protocol.md "Mailer routes"), present on the one relay that mails. */
export interface Mailer {
  /** The relay's X25519 key: digests and mail requests are sealed to its public half. */
  sealing: { privateKey: CryptoKey; publicRaw: Uint8Array<ArrayBuffer> };
  resendKey: string;
  from: string;
  /** The URL answer links name; the request's origin when unset. */
  url: string | undefined;
}

/** Resend's send endpoint; the tests intercept it, nothing else reaches it. */
export const RESEND_URL = "https://api.resend.com/emails";
export const DEFAULT_MAIL_FROM = "Digestif <digest@mail.digestif.io>";

const cachedSealing = new Map<string, Promise<Mailer["sealing"]>>();

/** The sealing key as a CryptoKey, imported once per isolate: the secret is a base64url raw 32-byte X25519 private key. */
function sealingOf(secret: string): Promise<Mailer["sealing"]> {
  let cached = cachedSealing.get(secret);
  if (cached === undefined) {
    cached = (async () => {
      let raw: Uint8Array<ArrayBuffer>;
      try {
        raw = unb64url(secret);
      } catch {
        throw new ConfigError("RELAY_SEALING_KEY must be base64url");
      }
      if (raw.length !== 32) throw new ConfigError("RELAY_SEALING_KEY must be a raw 32-byte X25519 private key, base64url");
      return importEncryptionKey(raw);
    })();
    cachedSealing.set(secret, cached);
  }
  return cached;
}

/** The mailer, when MAILER is "1" (the dinners relay only); undefined on a relay that does not mail. */
export async function mailerOf(env: Env): Promise<Mailer | undefined> {
  if (env.MAILER !== "1") return undefined;
  if (typeof env.RELAY_SEALING_KEY !== "string" || env.RELAY_SEALING_KEY === "") throw new ConfigError("MAILER is on but RELAY_SEALING_KEY is not set");
  if (typeof env.RESEND_API_KEY !== "string" || env.RESEND_API_KEY === "") throw new ConfigError("MAILER is on but RESEND_API_KEY is not set");
  const url = env.RELAY_URL === undefined || env.RELAY_URL === "" ? undefined : env.RELAY_URL.replace(/\/+$/, "");
  return {
    sealing: await sealingOf(env.RELAY_SEALING_KEY),
    resendKey: env.RESEND_API_KEY,
    from: env.MAIL_FROM === undefined || env.MAIL_FROM === "" ? DEFAULT_MAIL_FROM : env.MAIL_FROM,
    url,
  };
}

/**
 * What every circle route needs: the circle's database (its store, or the relay's D1 for a home
 * circle not yet moved), its root and address, the configuration and the relay's clock for this
 * request.
 */
export interface Relay {
  db: D1Database;
  root: string;
  /** The circle's address on this relay, `<base>/c/<root hex>`: what its answer links name. */
  address: string;
  limits: RelayLimits;
  /** What hosting circles may spend: a circle's store refuses appends past its share. */
  hosting: HostingLimits;
  /** The relay's D1, which holds what spans circles: the registry and the invite index (src/circles.ts). */
  registry: D1Database;
  now: Date;
  /** Present on the mailing relay. */
  mailer: Mailer | undefined;
  /** The release signer set the admission fold starts from (src/signers.ts). */
  releaseSigners: string[];
}
