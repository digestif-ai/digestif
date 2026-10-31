// The relay's configuration: the circle root, the limits and the mailer, Worker variables and
// secrets per deployment.
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

const ROOT = /^sha256:[0-9a-f]{64}$/;

export function rootOf(env: Env): string {
  const root = env.CIRCLE_ROOT;
  if (typeof root !== "string" || !ROOT.test(root)) throw new ConfigError("CIRCLE_ROOT must be the founding dinner's hash, sha256:<64 hex>");
  return root;
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

/** What every handler needs: the database, the configuration and the relay's clock for this request. */
export interface Relay {
  db: D1Database;
  root: string;
  limits: RelayLimits;
  now: Date;
  /** Present on the mailing relay. */
  mailer: Mailer | undefined;
}
