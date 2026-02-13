import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';

// Plugin to generate static HTML without type="module"
// ES modules don't work with custom URL schemes (editor://) due to CORS
function generateHtml(): Plugin {
  return {
    name: 'generate-html',
    closeBundle() {
      const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CodeMirror Editor</title>
  <link rel="stylesheet" href="/codemirror.css">
</head>
<body>
  <div id="editor"></div>
  <script src="/codemirror.js"></script>
</body>
</html>`;
      const outDir = resolve(__dirname, '../../final final/Resources/editor/codemirror');
      writeFileSync(resolve(outDir, 'codemirror.html'), html);
      console.log('Generated codemirror.html (no type="module")');
    },
  };
}

export default defineConfig({
  define: {
    __DEV__: JSON.stringify(process.env.NODE_ENV !== 'production'),
  },
  build: {
    outDir: '../../final final/Resources/editor/codemirror',
    emptyOutDir: true,
    // Build as library in IIFE format (not ES modules) for WKWebView compatibility
    lib: {
      entry: resolve(__dirname, 'src/main.ts'),
      name: 'CodeMirrorEditor',
      fileName: () => 'codemirror.js',
      formats: ['iife'],
    },
    rollupOptions: {
      output: {
        // Ensure CSS is extracted
        assetFileNames: 'codemirror.[ext]',
      },
    },
  },
  plugins: [generateHtml()],
});
