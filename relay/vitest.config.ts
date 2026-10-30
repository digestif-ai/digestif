import { readFileSync } from "node:fs";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Tests run inside workerd with the Worker's bindings: a fresh local D1 per test file, with the
// migrations applied by test/apply-migrations.ts before the first test. The Worker under test is
// the mailer: its sealing key is the first recipient of node/mail/test/vectors.json (a published
// test vector, never a real key), and the Resend key is a value no service would accept; the
// tests intercept the send (test/helpers.ts) so nothing reaches Resend.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  const vectors = JSON.parse(readFileSync(path.join(import.meta.dirname, "..", "node", "mail", "test", "vectors.json"), "utf8")) as {
    seal: { recipients: { private: string; public: string }[] };
  };
  const sealing = vectors.seal.recipients[0];
  if (sealing === undefined) throw new Error("vectors.json has no seal recipient");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            MAILER: "1",
            RELAY_SEALING_KEY: sealing.private,
            RESEND_API_KEY: ["not", "a", "key", String(Date.now())].join("-"),
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
      testTimeout: 120_000,
    },
  };
});
