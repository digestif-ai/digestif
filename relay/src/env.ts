// The relay's configuration: the circle root and the limits, Worker variables per deployment.
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

/** What every handler needs: the database, the configuration and the relay's clock for this request. */
export interface Relay {
  db: D1Database;
  root: string;
  limits: RelayLimits;
  now: Date;
}
