import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';

// Plugin to generate static HTML without type="module"
function generateHtml(): Plugin {
  return {
    name: 'generate-html',
    closeBundle() {
      const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Milkdown Editor</title>
  <style>
    :root {
      --editor-bg: #ffffff;
      --editor-text: #000000;
      --editor-selection: rgba(0, 122, 255, 0.3);
      --accent-color: #007aff;
    }
    html, body {
      margin: 0;
      padding: 0;
      height: 100%;
      background: var(--editor-bg);
      color: var(--editor-text);
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    #editor {
      padding: 20px;
      min-height: 100%;
      outline: none;
    }
  </style>
  <link rel="stylesheet" href="/milkdown.css">
</head>
<body>
  <div id="editor"></div>
  <script src="/milkdown.js"></script>
</body>
</html>`;
      const outDir = resolve(__dirname, '../../final final/Resources/editor/milkdown');
      writeFileSync(resolve(outDir, 'milkdown.html'), html);
      console.log('Generated milkdown.html (no type="module")');
    },
  };
}

export default defineConfig({
  define: {
    __DEV__: JSON.stringify(process.env.NODE_ENV !== 'production'),
  },
  build: {
    outDir: '../../final final/Resources/editor/milkdown',
    emptyOutDir: true,
    // Build as library in IIFE format (not ES modules) for WKWebView compatibility
    lib: {
      entry: resolve(__dirname, 'src/main.ts'),
      name: 'MilkdownEditor',
      fileName: () => 'milkdown.js',
      formats: ['iife'],
    },
    rollupOptions: {
      output: {
        // Ensure CSS is extracted
        assetFileNames: 'milkdown.[ext]',
      },
    },
  },
  plugins: [generateHtml()],
});
