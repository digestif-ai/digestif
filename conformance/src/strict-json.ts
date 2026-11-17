// JSON.parse for a signed document: a document whose object holds a member twice is refused.
// JSON.parse keeps the last of two members of one name and the node's OCaml readers keep the first,
// so the same signed bytes would read two ways; the node refuses such a document too
// (node/core/jcs.ml, duplicate_member). No imports, so a Worker and scripts/ both load it.

/** The first member name some object in `text` (valid JSON) holds twice, compared decoded; undefined when none does. */
export function duplicateMember(text: string): string | undefined {
  // One entry per open container: the names an object has read so far, or null for an array.
  const open: Array<Set<string> | null> = [];
  let expectName = false;
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text.charAt(j) !== '"') j += text.charAt(j) === "\\" ? 2 : 1;
      const names = open[open.length - 1];
      if (expectName && names) {
        const name = JSON.parse(text.slice(i, j + 1)) as string;
        if (names.has(name)) return name;
        names.add(name);
        expectName = false;
      }
      i = j + 1;
      continue;
    }
    if (c === "{") {
      open.push(new Set());
      expectName = true;
    } else if (c === "[") {
      open.push(null);
      expectName = false;
    } else if (c === "}" || c === "]") {
      open.pop();
      expectName = false;
    } else if (c === ",") {
      expectName = open[open.length - 1] instanceof Set;
    } else if (c === ":") {
      expectName = false;
    }
    i++;
  }
  return undefined;
}

/** `text` parsed, throwing when it is not JSON or some object in it holds a member twice. */
export function parseUnique(text: string, what: string): unknown {
  const value = JSON.parse(text) as unknown;
  const name = duplicateMember(text);
  if (name !== undefined) throw new Error(`${what} holds member ${JSON.stringify(name)} twice`);
  return value;
}
