#!/usr/bin/env node

/**
 * Generates getting-started.md from README.md by removing the Installation section.
 *
 * Usage: node scripts/generate-getting-started.js
 *
 * This maintains a single source of truth (README.md) while providing
 * in-app documentation that doesn't include installation instructions.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');

const readmePath = join(projectRoot, 'README.md');
const outputPath = join(projectRoot, 'final final', 'Resources', 'getting-started.md');

// Read README.md
const readme = readFileSync(readmePath, 'utf-8');

// Remove the Installation section (from "# Installation" to the next "# " heading)
// The regex matches:
// - "# Installation" heading
// - Everything until (but not including) the next level-1 heading
const withoutInstallation = readme.replace(
  /^# Installation\n[\s\S]*?(?=^# )/m,
  ''
);

// Write to getting-started.md
writeFileSync(outputPath, withoutInstallation, 'utf-8');

console.log('Generated:', outputPath);
