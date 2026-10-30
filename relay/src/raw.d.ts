// vite's `?raw` imports, which test/deploy.test.ts uses to read wrangler.jsonc and README.md.
declare module "*?raw" {
  const text: string;
  export default text;
}
