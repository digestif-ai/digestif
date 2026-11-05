// The relay release this Worker was built as (docs/protocol.md "Relay limits"), which GET /v0/circle
// reports as relay_version. The release build stamps it by defining RELAY_VERSION_STAMP when it
// bundles the Worker:
//
//   wrangler deploy --dry-run --outdir <dir> --define 'RELAY_VERSION_STAMP:"0.3.0"'
//
// esbuild replaces the identifier with the string, so it is part of the bytes the release signers
// sign and no deployment setting can change it. A Worker bundled without the define has no such
// global; `typeof` of an undeclared identifier is "undefined" rather than a ReferenceError, so an
// unstamped Worker reports no relay_version at all.
declare const RELAY_VERSION_STAMP: unknown;

/** The stamp as the field reports it: a non-empty string, else nothing. */
export function relayVersionOf(stamp: unknown): string | undefined {
  return typeof stamp === "string" && stamp !== "" ? stamp : undefined;
}

export const RELAY_VERSION: string | undefined = relayVersionOf(typeof RELAY_VERSION_STAMP === "undefined" ? undefined : RELAY_VERSION_STAMP);
