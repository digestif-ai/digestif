import eslint from '@eslint/js';
import tseslint from '@typescript-eslint/eslint-plugin';
import tsparser from '@typescript-eslint/parser';
import sveltePlugin from 'eslint-plugin-svelte';
import svelteParser from 'svelte-eslint-parser';
import globals from 'globals';
import prettierConfig from 'eslint-config-prettier';

const noUnusedVars = ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_', destructuredArrayIgnorePattern: '^_' }];
const runes = { $state: 'readonly', $derived: 'readonly', $effect: 'readonly', $props: 'readonly', $bindable: 'readonly' };
const tsRules = {
  'no-unused-vars': 'off',
  '@typescript-eslint/no-unused-vars': noUnusedVars,
  '@typescript-eslint/no-explicit-any': 'error',
  '@typescript-eslint/no-floating-promises': 'error'
};

/** @type {import('eslint').Linter.Config[]} */
export default [
  { ignores: ['.svelte-kit/**', 'build/**', 'src/generated/**', 'node_modules/**', 'test-results/**', 'playwright-report/**'] },
  eslint.configs.recommended,
  {
    files: ['**/*.ts'],
    ignores: ['playwright/**', 'playwright.config.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: { ecmaVersion: 'latest', sourceType: 'module', project: './tsconfig.json' },
      globals: { ...globals.browser, ...globals.node, ...runes }
    },
    plugins: { '@typescript-eslint': tseslint },
    rules: { ...tsRules, '@typescript-eslint/consistent-type-imports': 'error' }
  },
  {
    files: ['playwright/**/*.ts', 'playwright.config.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: { ecmaVersion: 'latest', sourceType: 'module', project: './playwright/tsconfig.json' },
      globals: { ...globals.node }
    },
    plugins: { '@typescript-eslint': tseslint },
    rules: tsRules
  },
  {
    files: ['**/*.svelte'],
    languageOptions: {
      parser: svelteParser,
      parserOptions: {
        parser: tsparser,
        ecmaVersion: 'latest',
        sourceType: 'module',
        project: './tsconfig.json',
        extraFileExtensions: ['.svelte']
      },
      globals: { ...globals.browser, ...runes }
    },
    plugins: { svelte: sveltePlugin, '@typescript-eslint': tseslint },
    rules: {
      ...sveltePlugin.configs.recommended.rules,
      'svelte/no-at-html-tags': 'error',
      ...tsRules
    }
  },
  { files: ['**/*.js'], languageOptions: { ecmaVersion: 'latest', sourceType: 'module', globals: { ...globals.node } } },
  prettierConfig
];
