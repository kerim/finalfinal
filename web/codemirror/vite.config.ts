import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    outDir: '../../final final/Resources/editor/codemirror',
    emptyOutDir: true,
    rollupOptions: {
      input: 'codemirror.html',
      output: {
        entryFileNames: 'codemirror.js',
        assetFileNames: 'codemirror.[ext]',
      },
    },
  },
});
