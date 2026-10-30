import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

// The web UI's TypeScript rules (ui/eslint.config.js): no explicit any, no floating promise, type-only
// imports written as such, unused names allowed with a leading underscore. The library and the
// commands are linted with type information; the tests keep the plain rules, since node:test's
// `test()` returns a promise nobody awaits by design.
const rules = {
  "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
  "@typescript-eslint/no-explicit-any": "error",
  "@typescript-eslint/consistent-type-imports": "error",
};

export default tseslint.config(
  { ignores: ["node_modules/**", "eslint.config.js"] },
  { files: ["**/*.mjs"], languageOptions: { globals: { process: "readonly", setTimeout: "readonly" } } },
  eslint.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked.map((c) => ({ ...c, files: ["src/**/*.ts", "bin/**/*.ts"] })),
  {
    files: ["src/**/*.ts", "bin/**/*.ts"],
    languageOptions: { parserOptions: { project: "./tsconfig.json", tsconfigRootDir: import.meta.dirname } },
    rules: { ...rules, "@typescript-eslint/no-floating-promises": "error" },
  },
  ...tseslint.configs.recommended.map((c) => ({ ...c, files: ["test/**/*.ts"] })),
  { files: ["test/**/*.ts"], rules },
);
