// The digest email, docs/protocol.md "The digest": the plaintext of test/fixtures/digest-plaintext.json
// rendered to text and HTML, pinned by the snapshots beside it (vitest -u rewrites them). Links
// are placeholders: the fixture's link ids, with a fixed secret.
import { describe, expect, it } from "vitest";
import type { Json } from "../../conformance/src/encoding.ts";
import { formatWhen, linkIds, parseDigestPlaintext, renderHtml, renderText } from "../src/render.ts";
import { confirmPage, donePage, refusedPage, troublePage } from "../src/pages.ts";
import { THEME_CSS } from "../src/theme.ts";
import fixture from "./fixtures/digest-plaintext.json";

const plaintext = fixture as unknown as { [key: string]: Json };
const digest = parseDigestPlaintext(plaintext);
const url = (id: string): string => `https://relay-1.example/v0/links/${id}?s=SECRET`;

describe("the digest email", () => {
  it("parses the protocol's plaintext and lists every option's link", () => {
    expect(digest.to).toBe("mike@example.com");
    expect(digest.inbox.map((entry) => entry.options?.length ?? 0)).toEqual([0, 2, 2, 0]);
    expect(linkIds(digest)).toEqual(["LINK-BEHAVIOR-INSTALL", "LINK-BEHAVIOR-NOT-NOW", "LINK-UNPAUSE", "LINK-STAY", "LINK-ACK"]);
  });

  // ISS-52614 (docs/protocol.md "The digest"): the Inbox part leads.
  it("renders the Inbox part first: a page link, answer links and Acknowledge", () => {
    const inbox = parseDigestPlaintext({
      to: "mike@example.com",
      subject: "Digestif, November 6: 3 in, 1 out, 3 in your Inbox",
      sections: [{ title: "Your agent did", lines: ["Phong's note: drafted the intro above."] }],
      inbox: [
        { item: "item-1", kind: "notice", title: "Introduce Phong to Andrey", line: "Draft by your agent to Phong and Andrey", page: { label: "Read the draft", url: "http://127.0.0.1:7070/inbox/item-1" } },
        {
          item: "sha256:3",
          kind: "choice",
          title: "Digestif paused. Unpause?",
          line: "Choice from your node",
          options: [
            { id: "unpause", label: "Unpause", recommended: true, link: "LINK-UNPAUSE" },
            { id: "stay_paused", label: "Stay paused", link: "LINK-STAY" },
          ],
          default: "stay_paused",
        },
        { item: "sha256:4", kind: "notice", title: "Your first note is ready on your machine.", line: "Notice from your node", acknowledge: { link: "LINK-ACK" } },
      ],
    });
    expect(linkIds(inbox)).toEqual(["LINK-UNPAUSE", "LINK-STAY", "LINK-ACK"]);
    for (const out of [renderText(inbox, url), renderHtml(inbox, url)]) {
      expect(out.indexOf("Inbox")).toBeLessThan(out.indexOf("Your agent did"));
      expect(out).toContain("Read the draft");
      expect(out).toContain("http://127.0.0.1:7070/inbox/item-1");
      expect(out).toContain("Unpause (recommended)");
      expect(out).toContain(out.includes("<html") ? "No pick counts as &quot;Stay paused&quot;." : 'No pick counts as "Stay paused".');
      expect(out).toContain("Acknowledge");
      expect(out).toContain(url("LINK-ACK").replace(/&/g, out.includes("<html") ? "&amp;" : "&"));
    }
    expect(() => parseDigestPlaintext({ to: "x", subject: "s", sections: [], inbox: [{ item: "i", kind: "choice", title: "t", line: "l", options: [] }] })).toThrow(/no options/);
  });

  it("refuses a plaintext that is not the digest's shape", () => {
    expect(() => parseDigestPlaintext({ to: "x" })).toThrow(/digest\.subject/);
    expect(() => parseDigestPlaintext({ ...plaintext, inbox: [{ item: "i", kind: "notice", line: "l" }] })).toThrow(/inbox\[0\]\.title/);
    expect(() => parseDigestPlaintext({ ...plaintext, sections: [{ title: 1, lines: [] }] })).toThrow(/sections\[0\]\.title/);
  });

  // ISS-52615: the asks list is gone from the digest, so one a plaintext still carries is not read.
  it("reads no asks list", () => {
    const withAsks = { ...plaintext, asks: [{ ask: "sha256:0", title: "An old ask", options: [{ label: "Yes", link: "LINK-OLD" }] }] };
    const parsed = parseDigestPlaintext(withAsks);
    expect(parsed).toEqual(digest);
    expect(linkIds(parsed)).not.toContain("LINK-OLD");
    for (const out of [renderText(parsed, url), renderHtml(parsed, url)]) {
      expect(out).not.toContain("An old ask");
      expect(out).not.toContain("Asks");
    }
  });

  it("renders the text email as the snapshot has it", async () => {
    const text = renderText(digest, url);
    await expect(text).toMatchFileSnapshot("./fixtures/digest.email.txt");
    expect(text).toContain("Not now (recommended)");
    expect(text).toContain("Unpause (recommended)");
    expect(text).not.toContain("Install (recommended)");
    expect(text).toContain('No pick by 2026-11-01 15:00 UTC counts as "Not now".');
    expect(text).toContain('No pick counts as "Stay paused".');
    expect(text).toContain("Updates\n-------\n");
    expect(text).toContain(url("LINK-BEHAVIOR-INSTALL"));
  });

  // ISS-42319 (DES-37153, the digest screen): what asks the member to act leads, then the lines
  // that ask nothing, then who the mail was sent to.
  it("puts the Inbox before the sections and names who it was sent to", () => {
    for (const out of [renderText(digest, url), renderHtml(digest, url)]) {
      const last = out.indexOf("Your first note is ready on your machine.");
      const first = out.indexOf(digest.sections[0]?.title ?? "");
      expect(out.indexOf("Introduce Phong to Andrey")).toBeGreaterThan(-1);
      expect(last).toBeGreaterThan(out.indexOf("Introduce Phong to Andrey"));
      expect(first).toBeGreaterThan(last);
      expect(out).toContain("Sent to mike@example.com from your Digestif node.");
    }
  });

  it("renders the HTML email as the snapshot has it, escaped", async () => {
    const html = renderHtml(digest, url);
    await expect(html).toMatchFileSnapshot("./fixtures/digest.email.html");
    expect(html).toContain("&lt;two&gt; dates &amp; a question");
    expect(html).toContain("Not now (recommended)");
    expect(html).toContain(`href="${url("LINK-STAY").replace(/&/g, "&amp;")}"`);
    expect(html).toContain("Install Roman&#39;s eval-harness behavior?");
    expect(html).toMatch(/<h2 style="[^"]*text-transform:uppercase[^"]*">Updates<\/h2>/);
    expect(html).toContain("Each link answers once and expires");
    expect(html).not.toContain("<script");
    expect(html).toContain("2026-11-01 15:00 UTC");
  });

  it("shows a time the node wrote as written when it does not parse", () => {
    expect(formatWhen("2026-11-01T15:00:00.000Z")).toBe("2026-11-01 15:00 UTC");
    expect(formatWhen("soon")).toBe("soon");
  });
});

describe("the theme stylesheet", () => {
  it("names no external URL, import or font", () => {
    expect(THEME_CSS).not.toMatch(/https?:|\/\/|@import|@font-face|url\(/);
  });
});

describe("the answer-link pages", () => {
  it("carry no script and no external resource", async () => {
    const pages = [
      confirmPage("Item <b>", "Yes", "/v0/links/ID", "SECRET"),
      donePage("Item", "Yes"),
      troublePage("unknown"),
      troublePage("used"),
      troublePage("closed"),
      troublePage("expired"),
      troublePage("wrong_secret"),
      refusedPage("because"),
    ];
    for (const response of pages) {
      const html = await response.text();
      expect(html).not.toMatch(/<script/i);
      expect(html).toContain("<style>");
      expect(html).not.toMatch(/(src|href)=["']?(https?:)?\/\//);
    }
  });
});
