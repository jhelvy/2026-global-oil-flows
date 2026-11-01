import { defineConfig } from 'vite';

// A single classic script with the data inside it. Browsers block module scripts and fetch
// on file:// pages, so this is what lets the rendered index.html open with a double-click.
export default defineConfig({
  json: { stringify: true },
  build: {
    lib: {
      entry: 'src/main.js',
      name: 'OilFlows',
      formats: ['iife'],
      fileName: () => 'oil-flows.js',
    },
  },
});
