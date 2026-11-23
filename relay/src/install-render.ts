// The hosted install script as the template applies to one release manifest (docs/releases.md, "The
// hosted install script"): ci/install-hosted.sh.in with the version, the link to the signed manifest,
// and each platform's archive url and sha256 filled in. ci/install-hosted.sh writes the release asset
// with the same rules and ci/install-hosted-test.sh holds the two byte for byte equal, so the script
// the relay answers is the one the Release workflow attaches. No Worker and no Node import, so
// relay/scripts/install-render.ts runs it under Node for that comparison.
import type { Json } from "../../conformance/src/encoding.ts";

/** Characters a url may hold to be written between single quotes in the script unescaped. */
const SAFE = /^[A-Za-z0-9._~:/?#@=%+-]+$/;
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const PLATFORM = /^(darwin|linux)-(arm64|x86_64)$/;
const HEX = /^[0-9a-f]{64}$/;

/** A manifest the template cannot be applied to: the reason, said the way ci/install-hosted.sh says it. */
export class RenderError extends Error {}

/** A manifest value as a message names it. */
function shown(value: Json | undefined): string {
  return typeof value === "string"
    ? value
    : (JSON.stringify(value) ?? "nothing");
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The case arms for each artifact, as ci/install-hosted.sh writes them. */
function artifactCases(artifacts: Json | undefined): string {
  if (!Array.isArray(artifacts))
    throw new RenderError("the manifest lists no artifacts");
  let cases = "";
  for (const artifact of artifacts) {
    const { platform, url, sha256 } = isObject(artifact) ? artifact : {};
    if (typeof platform !== "string" || !PLATFORM.test(platform))
      throw new RenderError(`the manifest names platform ${shown(platform)}`);
    if (typeof url !== "string" || !/^[a-z]+:\/\//.test(url) || !SAFE.test(url))
      throw new RenderError(`${platform}'s url ${shown(url)} is not absolute`);
    const hex =
      typeof sha256 === "string" && sha256.startsWith("sha256:")
        ? sha256.slice("sha256:".length)
        : sha256;
    if (typeof hex !== "string" || !HEX.test(hex))
      throw new RenderError(
        `${platform}'s sha256 ${shown(sha256)} is not sha256:<64 hex>`,
      );
    cases += `  ${platform})\n    url='${url}'\n    expected='${hex}'\n    ;;\n`;
  }
  if (cases === "") throw new RenderError("the manifest lists no artifacts");
  return cases;
}

/**
 * The template applied to [manifest], linking [manifestUrl]. Every line is the template's line
 * with @VERSION@ and @MANIFEST_URL@ replaced, and the line that is exactly @ARTIFACTS@ is the case
 * arms; a last line with no newline is left out, as the shell's `read` leaves it.
 */
export function renderInstall(
  template: string,
  manifest: Json,
  manifestUrl: string,
): string {
  if (!isObject(manifest))
    throw new RenderError("the manifest is not a JSON object");
  const version = manifest["version"];
  if (typeof version !== "string")
    throw new RenderError("the manifest names no version");
  if (!VERSION.test(version))
    throw new RenderError(`the manifest names version ${version}`);
  if (!/^https?:\/\//.test(manifestUrl) || !SAFE.test(manifestUrl))
    throw new RenderError(`${manifestUrl} is not an http(s) url`);
  const cases = artifactCases(manifest["artifacts"]);
  const lines = template.split("\n").slice(0, -1);
  return lines
    .map((line) =>
      line === "@ARTIFACTS@"
        ? cases
        : `${line.replaceAll("@VERSION@", version).replaceAll("@MANIFEST_URL@", manifestUrl)}\n`,
    )
    .join("");
}

/** The page that shows a published version's manifest beside its signatures: the version's GitHub release. */
export function manifestPage(version: string): string {
  return `https://github.com/digestif-ai/digestif/releases/tag/v${version}`;
}
