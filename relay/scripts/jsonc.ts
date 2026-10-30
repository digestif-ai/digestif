// Reads wrangler.jsonc (comments and trailing commas allowed) without a dependency; shared by
// scripts/deploy.sh (through `node scripts/jsonc.ts`) and test/deploy.test.ts.

// Drops line and block comments outside strings, and trailing commas, then parses.
export function parseJsonc(text: string): unknown {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text.charAt(j) !== '"') j += text.charAt(j) === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j + 1;
    } else if (c === "/" && text.charAt(i + 1) === "/") {
      while (i < text.length && text.charAt(i) !== "\n") i++;
    } else if (c === "/" && text.charAt(i + 1) === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      out += c;
      i++;
    }
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1")) as unknown;
}

// CLI: node scripts/jsonc.ts <file> <dot.path>   prints the value (strings raw, others as JSON).
if (typeof process !== "undefined" && process.argv[1]?.endsWith("jsonc.ts") === true) {
  const { readFileSync } = await import("node:fs");
  const [file, path] = process.argv.slice(2);
  if (file === undefined || path === undefined) throw new Error("usage: jsonc.ts <file> <dot.path>");
  let v: unknown = parseJsonc(readFileSync(file, "utf8"));
  for (const k of path.split(".")) v = (v as Record<string, unknown> | undefined)?.[k];
  if (v !== undefined) console.log(typeof v === "string" ? v : JSON.stringify(v));
}
