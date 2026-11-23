// GET /v0/relay (docs/protocol.md, Hosted circles): what anyone may read of a relay, unsigned. A
// founding node reads it to write a circle's relay message (whether it mails and its sealing key's
// public half), and to see whether the relay hosts new circles now; an operator reads its home
// circle; the release that drops the unprefixed routes waits on the last request one received.
import { b64url } from "../../conformance/src/encoding.ts";
import { mailerOf, type HostingLimits } from "./env.ts";
import { json } from "./errors.ts";
import { RELAY_VERSION, relayVersionField } from "./version.ts";

export async function relayInfo(env: Env, home: string | null, hosting: HostingLimits): Promise<Response> {
  const mailer = await mailerOf(env);
  const read = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare("SELECT COUNT(*) AS n FROM hosted_circles"),
    env.DB.prepare("SELECT last_unprefixed_at FROM relay_state WHERE id = 1"),
  ]);
  const hosted = (read[0]?.results[0]?.["n"] as number | undefined) ?? 0;
  const last = (read[1]?.results[0]?.["last_unprefixed_at"] as string | null | undefined) ?? null;
  // Room for one more circle's share beside every hosted circle's: what a founding append checks.
  const room = (hosted + 1) * hosting.circle_storage <= hosting.relay_storage;
  return json(200, {
    ...relayVersionField(RELAY_VERSION),
    mailer: mailer !== undefined,
    ...(mailer === undefined ? {} : { encryption_key: `x25519:${b64url(mailer.sealing.publicRaw)}` }),
    hosting: hosting.hosting && room,
    home,
    last_unprefixed_at: last,
  });
}
