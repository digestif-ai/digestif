import { readFileSync } from "node:fs";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { TEST_RELAY_VERSION } from "./test/stamp.ts";

// DIG-319: the same suite as vitest.config.ts, with the Worker's store swapped for the circle's
// SQLite-backed Durable Object behind the D1-shaped adapter (src/store.ts). The Worker under test
// is spike/main.ts, which hands src/index.ts the adapter as its DB; spike/apply-migrations.ts swaps
// the tests' env.DB for the same adapter and keeps the local D1 as env.D1. Run with `npx vitest run --config vitest.do.config.ts`.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  const vectors = JSON.parse(readFileSync(path.join(import.meta.dirname, "..", "node", "mail", "test", "vectors.json"), "utf8")) as {
    seal: { recipients: { private: string; public: string }[] };
  };
  const sealing = vectors.seal.recipients[0];
  if (sealing === undefined) throw new Error("vectors.json has no seal recipient");
  return {
    define: { RELAY_VERSION_STAMP: JSON.stringify(TEST_RELAY_VERSION) },
    plugins: [
      cloudflareTest({
        main: "./spike/main.ts",
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
      include: ["test/**/*.test.ts", "spike/**/*.test.ts"],
      setupFiles: ["./spike/apply-migrations.ts"],
      testTimeout: 120_000,
    },
  };
});
