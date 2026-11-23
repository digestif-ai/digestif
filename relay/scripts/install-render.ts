#!/usr/bin/env node
// Prints the hosted install script the relay renders for a manifest (src/install-render.ts over
// src/install-template.ts), so ci/install-hosted-test.sh can hold it byte for byte equal to what
// ci/install-hosted.sh writes for the release asset.
//
//   node relay/scripts/install-render.ts MANIFEST MANIFEST_URL
import { readFileSync } from "node:fs";
import type { Json } from "../../conformance/src/encoding.ts";
import { renderInstall } from "../src/install-render.ts";
import { INSTALL_TEMPLATE } from "../src/install-template.ts";

const [manifest, url] = process.argv.slice(2);
if (manifest === undefined || url === undefined) {
  console.error("usage: node relay/scripts/install-render.ts MANIFEST MANIFEST_URL");
  process.exit(2);
}
process.stdout.write(renderInstall(INSTALL_TEMPLATE, JSON.parse(readFileSync(manifest, "utf8")) as Json, url));
