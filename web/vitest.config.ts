import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['milkdown/src/__tests__/**/*.test.ts', 'codemirror/src/__tests__/**/*.test.ts'],
  },
});
