// The relay release this Worker was built as (docs/protocol.md "Relay version"), which GET /v0/circle
// and the unsigned GET /v0/version report as relay_version. The release build stamps it by defining
// RELAY_VERSION_STAMP when it bundles the Worker:
//
//   wrangler deploy --dry-run --outdir <dir> --define 'RELAY_VERSION_STAMP:"0.3.0"'
//
// esbuild replaces the identifier with the string, so it is part of the bytes the release signers
// sign and no deployment setting can change it. A Worker bundled without the define has no such
// global; `typeof` of an undeclared identifier is "undefined" rather than a ReferenceError, so an
// unstamped Worker reports no relay_version at all.
import { json } from "./errors.ts";

declare const RELAY_VERSION_STAMP: unknown;

/** The stamp as the field reports it: a non-empty string, else nothing. */
export function relayVersionOf(stamp: unknown): string | undefined {
  return typeof stamp === "string" && stamp !== "" ? stamp : undefined;
}

export const RELAY_VERSION: string | undefined = relayVersionOf(typeof RELAY_VERSION_STAMP === "undefined" ? undefined : RELAY_VERSION_STAMP);

/** The relay_version field as both reads report it: the stamp, or no field at all on an unstamped Worker. */
export function relayVersionField(version: string | undefined): { relay_version?: string } {
  return version === undefined ? {} : { relay_version: version };
}

/**
 * GET /v0/version: the relay release, unsigned. The version is public by construction (the signed
 * bundle, the channel index, the git tag), so anyone may read which release a relay runs; the
 * admitted keys stay behind the signed GET /v0/circle.
 */
export function version(): Response {
  return json(200, relayVersionField(RELAY_VERSION));
}
