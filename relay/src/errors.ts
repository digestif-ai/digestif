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
  | "unknown_digest";

export class Refusal extends Error {
  readonly status: number;
  readonly code: ErrorCode;

  constructor(status: number, code: ErrorCode, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }

  /** 422 answers a list of relay_error; every other status answers one. */
  response(): Response {
    const payload = { code: this.code, message: this.message };
    return json(this.status, this.status === 422 ? [payload] : payload);
  }
}

export function json(status: number, payload: unknown): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}

export function empty(status: number): Response {
  return new Response(null, { status });
}
