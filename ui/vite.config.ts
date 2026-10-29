/// <reference types="vitest/config" />
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';
import { mockNode } from './mock/plugin.ts';

/** A running node to develop against; without it `vite dev` answers from mock/node.ts. */
const NODE = process.env['DIGESTIF_NODE'];

export default defineConfig({
  plugins: [
    tailwindcss(),
    // A static single-page build: the node embeds build/ in its binary and answers every path it
    // does not know with index.html, so the client router takes it from there.
    sveltekit({
      preprocess: vitePreprocess(),
      adapter: adapter({ fallback: 'index.html' })
    }),
    mockNode()
  ],
  server: {
    // the WebCrypto reference lives beside the node, outside ui/
    fs: { allow: ['.', '../node/mail/webcrypto'] },
    ...(NODE === undefined ? {} : { proxy: { '/api/v0': { target: NODE, changeOrigin: false } } })
  },
  test: {
    include: ['src/**/*.test.ts', 'mock/**/*.test.ts']
  }
});
