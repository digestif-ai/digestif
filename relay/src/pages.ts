// The answer link pages (docs/protocol.md "Mailer routes"): the confirm page, the done page, and
// one page for each way a link cannot be used. Every page is 200 text/html, as
// spec/digestif-relay.json lists; what happened is in the words, not the status.
import { escapeHtml as e } from "./render.ts";

const STYLE =
  "font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#222;max-width:480px;margin:0 auto;padding:48px 16px;line-height:1.45";
const BUTTON = "padding:10px 20px;border-radius:4px;border:0;background:#1a5fb4;color:#fff;font-size:16px;font-weight:bold;cursor:pointer";

function page(title: string, body: string): Response {
  const html = [
    `<!doctype html>`,
    `<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>${e(title)}</title></head>`,
    `<body style="${STYLE}">`,
    body,
    `<p style="margin-top:48px;color:#888;font-size:13px">Digestif</p>`,
    `</body></html>`,
    ``,
  ].join("\n");
  return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

/** The confirm page: the ask and the option, one Confirm button posting the secret back. */
export function confirmPage(askTitle: string, label: string, action: string, secret: string): Response {
  return page(
    `Confirm: ${label}`,
    [
      `<p style="color:#555;margin:0 0 8px">${e(askTitle)}</p>`,
      `<h1 style="font-size:22px;margin:0 0 24px">${e(label)}</h1>`,
      `<form method="post" action="${e(action)}">`,
      `<input type="hidden" name="s" value="${e(secret)}">`,
      `<button type="submit" style="${BUTTON}">Confirm</button>`,
      `</form>`,
    ].join("\n"),
  );
}

/** The done page: the answer went in. */
export function donePage(askTitle: string, label: string): Response {
  return page(
    `Answered: ${label}`,
    [
      `<p style="color:#555;margin:0 0 8px">${e(askTitle)}</p>`,
      `<h1 style="font-size:22px;margin:0 0 16px">${e(label)}</h1>`,
      `<p>Your answer went in. You can close this page.</p>`,
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

/** A page saying which way the link cannot be used. */
export function troublePage(trouble: LinkTrouble): Response {
  const [title, text] = TROUBLE[trouble];
  return page(title, `<h1 style="font-size:22px;margin:0 0 16px">${e(title)}</h1>\n<p>${e(text)}</p>`);
}

/** The answer did not go in: the decision failed a check or the fold refused it. */
export function refusedPage(reason: string): Response {
  return page(
    "Answer refused",
    `<h1 style="font-size:22px;margin:0 0 16px">Answer refused</h1>\n<p>The answer did not go in: ${e(reason)}.</p>`,
  );
}
