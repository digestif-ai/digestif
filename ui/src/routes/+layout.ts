// A static build: the node embeds it for its local UI, and the mailing relay serves it under /app/
// as the phone web app. Every page renders in the browser.
export const ssr = false;
export const prerender = false;
