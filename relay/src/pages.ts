// The answer link pages (docs/protocol.md "Mailer routes"): the confirm page, the done page, and
// one page for each way a link cannot be used. Every page is 200 text/html, as
// spec/digestif-relay.json lists; what happened is in the words, not the status.
import { escapeHtml as e } from "./render.ts";
import { THEME_CSS, type Tone } from "./theme.ts";

function badge(tone: Tone, text: string): string {
  return `<span class="dg-badge dg-${tone}" data-tone="${tone}">${e(text)}</span>`;
}

function page(title: string, body: string): Response {
  const html = [
    `<!doctype html>`,
    `<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="robots" content="noindex"><title>${e(title)}</title>`,
    `<style>${THEME_CSS}</style></head>`,
    `<body>`,
    `<main>`,
    body,
    `</main>`,
    `<p class="dg-foot">Digestif</p>`,
    `</body></html>`,
    ``,
  ].join("\n");
  return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

/** The confirm page, after the web UI's ask page: the ask is the heading, the option the one action. */
export function confirmPage(askTitle: string, label: string, action: string, secret: string): Response {
  return page(
    `Confirm: ${label}`,
    [
      `<h1>${e(askTitle)}</h1>`,
      `<article class="dg-card">`,
      `<p class="dg-label">Your answer</p>`,
      `<p class="dg-option"><strong>${e(label)}</strong></p>`,
      `<form method="post" action="${e(action)}">`,
      `<input type="hidden" name="s" value="${e(secret)}">`,
      `<button type="submit" class="dg-button">Confirm</button>`,
      `</form>`,
      `</article>`,
      `<p class="dg-note">Confirm sends this answer. The ask's other links stop working once it goes in.</p>`,
    ].join("\n"),
  );
}

/** The done page, a settled ask: the answer went in. */
export function donePage(askTitle: string, label: string): Response {
  return page(
    `Answered: ${label}`,
    [
      `<h1>${e(askTitle)}</h1>`,
      `<article class="dg-card">`,
      badge("good", "Answered"),
      `<p class="dg-option">You answered <strong>${e(label)}</strong>.</p>`,
      `<p class="dg-note">Your answer went in. You can close this page.</p>`,
      `</article>`,
    ].join("\n"),
  );
}

export type LinkTrouble = "unknown" | "used" | "expired" | "wrong_secret";

const TROUBLE: Record<LinkTrouble, [string, string]> = {
  unknown: ["Unknown link", "This link is not one this relay mailed. Check that the whole address was copied."],
  used: ["Already answered", "This ask was already answered from one of its links, so this link has been used."],
  expired: ["Link expired", "This ask has lapsed; the link no longer answers it."],
  wrong_secret: ["Link incomplete", "The secret in this link does not open it. Check that the whole address was copied."],
};

function trouble(title: string, text: string): Response {
  return page(title, [`<h1>${e(title)}</h1>`, `<article class="dg-card">`, `<p>${e(text)}</p>`, `</article>`].join("\n"));
}

/** A page saying which way the link cannot be used. */
export function troublePage(kind: LinkTrouble): Response {
  const [title, text] = TROUBLE[kind];
  return trouble(title, text);
}

/** The answer did not go in: the decision failed a check or the fold refused it. */
export function refusedPage(reason: string): Response {
  return trouble("Answer refused", `The answer did not go in: ${reason}.`);
}
