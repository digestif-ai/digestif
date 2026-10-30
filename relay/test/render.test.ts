// The digest email, docs/protocol.md "The digest": the plaintext of test/fixtures/digest-plaintext.json
// rendered to text and HTML, pinned by the snapshots beside it (vitest -u rewrites them). Links
// are placeholders: the fixture's link ids, with a fixed secret.
import { describe, expect, it } from "vitest";
import type { Json } from "../../conformance/src/encoding.ts";
import { formatWhen, linkIds, parseDigestPlaintext, renderHtml, renderText } from "../src/render.ts";
import fixture from "./fixtures/digest-plaintext.json";

const digest = parseDigestPlaintext(fixture as Json);
const url = (id: string): string => `https://relay-1.example/v0/links/${id}?s=SECRET`;

describe("the digest email", () => {
  it("parses the protocol's plaintext and lists every option's link", () => {
    expect(digest.to).toBe("mike@example.com");
    expect(digest.asks.map((a) => a.options.length)).toEqual([2, 2]);
    expect(linkIds(digest)).toEqual(["LINK-INTRO-YES", "LINK-INTRO-NO", "LINK-SHARE-YES", "LINK-SHARE-NO"]);
  });

  it("refuses a plaintext that is not the digest's shape", () => {
    expect(() => parseDigestPlaintext({ to: "x" })).toThrow(/digest\.subject/);
    expect(() => parseDigestPlaintext({ ...(fixture as { [key: string]: Json }), asks: [{ ask: "sha256:0", title: "t", options: [] }] })).toThrow(/no options/);
    expect(() => parseDigestPlaintext({ ...(fixture as { [key: string]: Json }), sections: [{ title: 1, lines: [] }] })).toThrow(/sections\[0\]\.title/);
  });

  it("renders the text email as the snapshot has it", async () => {
    const text = renderText(digest, url);
    await expect(text).toMatchFileSnapshot("./fixtures/digest.email.txt");
    expect(text).toContain("Make the intro (recommended)");
    expect(text).toContain("Hold them (recommended)");
    expect(text).not.toContain("Decline (recommended)");
    expect(text).toContain('No answer by 2026-11-01 15:00 UTC counts as "no".');
    expect(text).toContain('No answer by 2026-10-31 09:30 UTC counts as "Hold them".');
    expect(text).toContain("Updates\n-------\n");
    expect(text).toContain(url("LINK-INTRO-YES"));
  });

  it("renders the HTML email as the snapshot has it, escaped", async () => {
    const html = renderHtml(digest, url);
    await expect(html).toMatchFileSnapshot("./fixtures/digest.email.html");
    expect(html).toContain("&lt;two&gt; dates &amp; a question");
    expect(html).toContain("Make the intro (recommended)");
    expect(html).toContain(`href="${url("LINK-SHARE-NO").replace(/&/g, "&amp;")}"`);
    expect(html).toContain("<h2 style=\"font-size:16px;margin:24px 0 8px\">Updates</h2>");
    expect(html).toContain("2026-11-01 15:00 UTC");
  });

  it("shows a time the node wrote as written when it does not parse", () => {
    expect(formatWhen("2026-11-01T15:00:00.000Z")).toBe("2026-11-01 15:00 UTC");
    expect(formatWhen("soon")).toBe("soon");
  });
});
