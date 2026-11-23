// Refusals and the relay_error shape of spec/digestif-relay.json.
import type { FoldError } from "../../conformance/src/fold.ts";

export type ErrorCode =
  | FoldError
  | "stale_request"
  | "replayed_nonce"
  | "sequence_regression"
  | "fork"
  | "too_large"
  | "rate_limited"
  | "not_mailer"
  | "unknown_digest"
  | "mail_failed"
  | "circle_unknown"
  | "circle_suspended"
  | "moving"
  | "not_vouched"
  | "not_hosting"
  | "relay_full"
  | "circle_full"
  | "too_many_circles";

export class Refusal extends Error {
  readonly status: number;
  readonly code: ErrorCode;
  readonly headers: Record<string, string>;

  constructor(status: number, code: ErrorCode, message: string, headers: Record<string, string> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }

  /** 422 answers a list of relay_error; every other status answers one. */
  response(): Response {
    const payload = { code: this.code, message: this.message };
    return json(this.status, this.status === 422 ? [payload] : payload, this.headers);
  }
}

/**
 * The home circle's copy is cutting over (src/move.ts): a write answers this, and a node retries it as
 * any transient failure.
 */
export function moving(): Refusal {
  return new Refusal(503, "moving", "this circle is moving into its own store; retry in a few seconds", { "retry-after": "5" });
}

/** A write the home circle's moved-tables triggers aborted (migrations/0006_hosted_circles.sql). */
export function isMovingAbort(error: unknown): boolean {
  return error instanceof Error && /circle_moving/.test(error.message);
}

export function json(status: number, payload: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json", ...headers } });
}

export function empty(status: number): Response {
  return new Response(null, { status });
}
