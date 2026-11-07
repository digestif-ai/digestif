// Whether this environment can bind and connect to 127.0.0.1. A Dev Factory sandbox on macOS has
// no loopback: a test that starts a local server and reads it waits on a connection that never
// completes until the probe's cap kills the run. The check runs once, at import, with its own
// deadline, so a suite without loopback skips its socket cases with a reason instead of hanging.
// DIG-298
import { createServer } from "node:net";
import { connect } from "node:net";

function probe(timeoutMs = 2000): Promise<string | false> {
  return new Promise((resolve) => {
    let done = false;
    const server = createServer((s) => s.destroy());
    const finish = (reason: string | false) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      server.close();
      resolve(reason);
    };
    const timer = setTimeout(() => finish("127.0.0.1 did not answer within 2 s"), timeoutMs);
    server.once("error", (e) => finish(`cannot bind 127.0.0.1: ${(e as NodeJS.ErrnoException).code ?? e.message}`));
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      const client = connect({ host: "127.0.0.1", port });
      client.once("connect", () => {
        client.destroy();
        finish(false);
      });
      client.once("error", (e) => finish(`cannot connect to 127.0.0.1: ${(e as NodeJS.ErrnoException).code ?? e.message}`));
    });
  });
}

/** `false` when loopback works; otherwise the reason to skip, for a test's `{ skip }` option. */
export const noLoopback: string | false = await probe();
