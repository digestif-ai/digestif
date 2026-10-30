// The look of the relay's pages and email, taken from the web UI (ui/src/app.css and the Svelte
// components under ui/src/lib/components). ui/ is Mike's and is read, never imported: a copy of
// the values lives here until ui/ exports its theme as a shared CSS file (relay/README.md,
// "Pages and email"). Each token below names where it came from. Tailwind's palette values are
// the stock stone, emerald, amber, red, sky and pink scales. No external resource, no web font.

/** Light and dark values of one token. */
interface Pair {
  light: string;
  dark: string;
}

/** The color tokens. The email reads `light`; the pages read both through `prefers-color-scheme`. */
export const COLOR = {
  // app.css `html`: bg-stone-50 / dark:bg-stone-950
  page: { light: "#fafaf9", dark: "#0c0a09" },
  // app.css `html`: text-stone-900 / dark:text-stone-100
  text: { light: "#1c1917", dark: "#f5f5f4" },
  // app.css `.dg-muted`: text-stone-500 / dark:text-stone-400
  muted: { light: "#78716c", dark: "#a8a29e" },
  // app.css `.dg-card`: bg-white / dark:bg-stone-900
  card: { light: "#ffffff", dark: "#1c1917" },
  // app.css `.dg-card` and `.dg-rows`: border-stone-200 / dark:border-stone-800
  line: { light: "#e7e5e4", dark: "#292524" },
  // app.css `--color-dg-accent` (links and the primary button); dark links use `.dg-link`'s pink-300
  accent: { light: "#7a2850", dark: "#f9a8d4" },
  // app.css `--color-dg-accent` as the primary button background, in both themes (Button.svelte `primary`)
  accentFill: { light: "#7a2850", dark: "#7a2850" },
  // app.css `--color-dg-accent-hover`
  accentHover: { light: "#5f1d3d", dark: "#5f1d3d" },
  // Button.svelte `primary`: text-white
  onAccent: { light: "#ffffff", dark: "#ffffff" },
  // Button.svelte `secondary`: border-stone-300 / dark:border-stone-700
  buttonLine: { light: "#d6d3d1", dark: "#44403c" },
} satisfies Record<string, Pair>;

/** StatusBadge.svelte TONES: the only other color. Each is a background and a text color. */
export const TONE = {
  // neutral: bg-stone-100 text-stone-600 / dark:bg-stone-800 dark:text-stone-300
  neutral: { bg: { light: "#f5f5f4", dark: "#292524" }, fg: { light: "#57534e", dark: "#d6d3d1" } },
  // good: bg-emerald-50 text-emerald-700 / dark:bg-emerald-950 dark:text-emerald-300
  good: { bg: { light: "#ecfdf5", dark: "#022c22" }, fg: { light: "#047857", dark: "#6ee7b7" } },
  // warn: bg-amber-50 text-amber-800 / dark:bg-amber-950 dark:text-amber-300
  warn: { bg: { light: "#fffbeb", dark: "#451a03" }, fg: { light: "#92400e", dark: "#fcd34d" } },
  // bad: bg-red-50 text-red-700 / dark:bg-red-950 dark:text-red-300
  bad: { bg: { light: "#fef2f2", dark: "#450a0a" }, fg: { light: "#b91c1c", dark: "#fca5a5" } },
  // info: bg-sky-50 text-sky-700 / dark:bg-sky-950 dark:text-sky-300
  info: { bg: { light: "#f0f9ff", dark: "#082f49" }, fg: { light: "#0369a1", dark: "#7dd3fc" } },
} satisfies Record<string, { bg: Pair; fg: Pair }>;

export type Tone = keyof typeof TONE;

// app.css `--font-sans`
export const FONT = `ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif`;

/** Radii: Tailwind rounded-lg (.dg-card), rounded-md (Button.svelte, .dg-input), rounded-full (StatusBadge.svelte). */
export const RADIUS = { card: "8px", control: "6px", pill: "9999px" } as const;

/** Spacing on Tailwind's 4px scale: gap-2, gap-3, p-4 and mb-4 in the ask page, px-4 in `.dg-row`. */
export const SPACE = { s1: "4px", s2: "8px", s3: "12px", s4: "16px", s6: "24px" } as const;

/** Type sizes: text-xs (.dg-label, StatusBadge), text-sm (body of rows and the ask page), text-xl (PageHeader h1). */
export const SIZE = { xs: "12px", sm: "14px", base: "16px", xl: "20px" } as const;

/** Button.svelte `min-h-11`: the 44px touch target. */
export const TOUCH = "44px";

function vars(side: "light" | "dark"): string {
  const colors = Object.entries(COLOR).map(([name, pair]) => `--dg-${name}:${pair[side]};`);
  const tones = Object.entries(TONE).flatMap(([name, t]) => [`--dg-${name}-bg:${t.bg[side]};`, `--dg-${name}-fg:${t.fg[side]};`]);
  return [...colors, ...tones].join("");
}

/** The stylesheet the Worker's pages inline in a `<style>` element. */
export const THEME_CSS = `:root{color-scheme:light dark;${vars("light")}}
@media (prefers-color-scheme:dark){:root{${vars("dark")}}}
*{box-sizing:border-box}
html{background:var(--dg-page);color:var(--dg-text);-webkit-text-size-adjust:100%}
body{margin:0 auto;max-width:560px;padding:${SPACE.s6} ${SPACE.s4};font-family:${FONT};font-size:${SIZE.base};line-height:1.5;-webkit-font-smoothing:antialiased;overflow-wrap:anywhere}
h1{font-size:${SIZE.xl};font-weight:600;line-height:1.3;margin:0 0 ${SPACE.s4}}
p{margin:0 0 ${SPACE.s3}}
strong{font-weight:600}
.dg-muted{color:var(--dg-muted)}
.dg-label{font-size:${SIZE.xs};font-weight:500;letter-spacing:.025em;text-transform:uppercase;color:var(--dg-muted);margin:0 0 ${SPACE.s1}}
.dg-card{background:var(--dg-card);border:1px solid var(--dg-line);border-radius:${RADIUS.card};padding:${SPACE.s4};margin:0 0 ${SPACE.s4}}
.dg-card>:last-child{margin-bottom:0}
.dg-option{font-size:${SIZE.sm};margin:0 0 ${SPACE.s3}}
.dg-note{font-size:${SIZE.sm};color:var(--dg-muted)}
.dg-button{display:inline-flex;align-items:center;justify-content:center;min-height:${TOUCH};padding:0 ${SPACE.s4};border:1px solid transparent;border-radius:${RADIUS.control};background:var(--dg-accentFill);color:var(--dg-onAccent);font:inherit;font-size:${SIZE.sm};font-weight:500;cursor:pointer}
.dg-button:hover,.dg-button:focus-visible{background:var(--dg-accentHover)}
.dg-badge{display:inline-flex;align-items:center;margin:0 0 ${SPACE.s3};padding:2px ${SPACE.s2};border-radius:${RADIUS.pill};font-size:${SIZE.xs};font-weight:500}
${Object.keys(TONE)
  .map((t) => `.dg-${t}{background:var(--dg-${t}-bg);color:var(--dg-${t}-fg)}`)
  .join("\n")}
.dg-foot{margin-top:${SPACE.s6};font-size:${SIZE.xs};color:var(--dg-muted)}
`;
