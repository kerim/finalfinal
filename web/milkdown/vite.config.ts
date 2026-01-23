import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    outDir: '../../final final/Resources/editor/milkdown',
    emptyOutDir: true,
    rollupOptions: {
      input: 'milkdown.html',
      output: {
        entryFileNames: 'milkdown.js',
        assetFileNames: 'milkdown.[ext]',
      },
    },
  },
});
