import {defineConfig} from 'vite';
import {resolve} from 'node:path';

const REPOSITORY = resolve(import.meta.dirname, '../..');

// Godot loads web/*.js with JavaScriptBridge.eval, so the output must be one
// classic script with the workers inlined, not an ES module.
export default defineConfig({
  publicDir: false,
  // The benchmark (npm run bench) loads its targets from web/targets.
  define: {__REPOSITORY__: JSON.stringify(REPOSITORY.replaceAll('\\', '/'))},
  server: {
    port: 5180,
    fs: {allow: ['../..']},
  },
  build: {
    outDir: '../../web',
    emptyOutDir: false,
    lib: {
      entry: 'src/index.js',
      name: 'ShivooMindAR',
      formats: ['iife'],
      fileName: () => 'mindar_image.js',
    },
  },
});
