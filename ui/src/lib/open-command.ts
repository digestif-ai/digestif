/**
 * The line that opens a page of this node from a browser with no session: `digestif open` takes the
 * page's link and lands on it (node/bin/main.ml, open). The link is single-quoted for the shell, so
 * a query's `&` or `?` reaches the command whole. ISS-78222
 */
export function openCommand(url: { href: string }): string {
  const link = url.href.replace(/'/g, `'\\''`);
  return `digestif open '${link}'`;
}
