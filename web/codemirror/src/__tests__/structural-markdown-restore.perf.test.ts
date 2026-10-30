// @vitest-environment jsdom
//
// t-4a8fd8af, Phase 4b, Markdown slice 4, round B: WR16, a MEASUREMENT (not a test of behaviour).
//
// How long does the planning / diff step of a `whole` Restore Entire Project take on a big book when the version differs a lot from the
// document? `planRestore` (api-structural-markdown-restore.ts) turns the document into the version's text as a refined diff
// (`computeRefinedChanges`, text-diff.ts: line-level Myers, character-level inside a short changed run, one span past the limits).
// The plan's addendum (section 8) says: if this takes more than 100 ms on the dev Mac, `computeRefinedChanges` gets an optional
// `charRunLimit` for the restore. This file only measures and prints; it asserts that the plan succeeds and nothing about time.
//
// Each line looks like:   RESULT planRestore ms=12.3 variant=H1 run=2 oldChars=700000 newChars=700000 hunks=1
// The driver reads them from the vitest output (`pnpm exec vitest run codemirror/src/__tests__/structural-markdown-restore.perf.test.ts`
// with the output not silenced). Deterministic: a seeded generator, the same text on every run and every machine.
//
// Variants (a 700 000-character, 12-chapter document):
//   H1   every paragraph's middle third reworded: about 1 800 changed lines, thousands of line-level edits (past the line limit).
//   H2   three 150 000-character paragraphs with about 900 one-character edits each (a changed run longer than the character limit).
//   H2b  the worst case for character refinement: three 99 000-character paragraphs with 450 one-character substitutions each, so each
//        changed run is just under the run limit and just under the edit limit and the character-level Myers really runs.

import { Text } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import type { MarkdownRestoreRequest } from '../api-structural-markdown';
import { planRestore } from '../api-structural-markdown-restore';

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const WORDS = [
  'archive',
  'register',
  'village',
  'harvest',
  'council',
  'merchant',
  'ledger',
  'season',
  'river',
  'market',
  'letter',
  'witness',
  'boundary',
  'tenant',
  'granary',
  'chapel',
  'census',
  'winter',
  'orchard',
  'bridge',
  'lantern',
  'tithe',
  'garrison',
  'weaver',
  'quarry',
  'meadow',
  'ferry',
  'charter',
  'cellar',
  'beacon',
];

/** `chars` characters of pseudo-random words, ending in a full stop, on ONE line. */
function prose(rand: () => number, chars: number): string {
  let out = '';
  while (out.length < chars) out += `${WORDS[Math.floor(rand() * WORDS.length)]} `;
  return `${out
    .slice(0, chars - 1)
    .trimEnd()
    .padEnd(chars - 1, 'x')}.`;
}

/** The document: a heading and the paragraphs of each chapter, blocks separated by a blank line, one newline at the end. */
function assemble(chapters: string[][]): string {
  return `${chapters.map((paragraphs, i) => [`# Chapter ${i + 1}`, ...paragraphs].join('\n\n')).join('\n\n')}\n`;
}

const TARGET_CHARS = 700_000;
const CHAPTERS = 12;
const SEPARATOR = 2;

/** The number of ordinary paragraphs per chapter that makes the document about TARGET_CHARS long with three giants of `giantChars`
 * (decided from the NOMINAL giant size, so the document before and after the edits has the same paragraphs). */
function paragraphsPerChapter(paragraphChars: number, giantChars: number): number {
  const fillChars = TARGET_CHARS - 3 * (giantChars + SEPARATOR);
  return Math.floor(fillChars / CHAPTERS / (paragraphChars + SEPARATOR));
}

/** 12 chapters of `perChapter` ordinary paragraphs each, with the `giants` (one per entry, spliced into the chapters named by `giantAt`). */
function book(
  seed: number,
  paragraphChars: number,
  perChapter: number,
  giants: string[],
  giantAt: number[]
): string[][] {
  const rand = mulberry32(seed);
  const chapters: string[][] = [];
  for (let c = 0; c < CHAPTERS; c++) {
    const paragraphs: string[] = [];
    for (let p = 0; p < perChapter; p++) paragraphs.push(prose(rand, paragraphChars));
    chapters.push(paragraphs);
  }
  giantAt.forEach((chapter, k) => {
    chapters[chapter].splice(1, 0, giants[k]);
  });
  return chapters;
}

/** `text` with `edits` evenly spaced one-character changes (a substitution of the character by another letter when `substitute`, else
 * an extra letter inserted after it). */
function withEdits(text: string, edits: number, substitute: boolean): string {
  const step = Math.floor(text.length / (edits + 1));
  let out = '';
  let last = 0;
  for (let k = 1; k <= edits; k++) {
    const at = k * step;
    out += text.slice(last, at);
    const ch = text[at];
    out += substitute ? (ch === 'q' ? 'z' : 'q') : `${ch}q`;
    last = at + 1;
  }
  return out + text.slice(last);
}

function measure(variant: string, before: string, after: string): void {
  const doc = Text.of(before.split('\n'));
  const request: MarkdownRestoreRequest = {
    kind: 'restore',
    opId: 'perf',
    mode: 'whole',
    rootId: null,
    leaders: [],
    stopLine: null,
    endLeaderId: null,
    text: after,
  };
  for (let run = 1; run <= 3; run++) {
    const started = performance.now();
    const plan = planRestore(doc, request);
    const ms = performance.now() - started;
    expect(plan.ok, `${variant}: the plan was refused`).toBe(true);
    const hunks = plan.ok ? plan.hunks : -1;
    console.log(
      `RESULT planRestore ms=${ms.toFixed(1)} variant=${variant} run=${run} oldChars=${before.length} newChars=${after.length} hunks=${hunks}`
    );
  }
}

describe('WR16 (MEASUREMENT) the planning step of a whole restore on a 700 000-character book', () => {
  it('WR16 H1: every paragraph in the document has its middle third reworded in the version', () => {
    const base = book(1, 380, Math.floor(TARGET_CHARS / CHAPTERS / (380 + SEPARATOR)), [], []);
    const rand = mulberry32(99);
    const reworded = base.map((paragraphs) =>
      paragraphs.map((paragraph) => {
        const third = Math.floor(paragraph.length / 3);
        return paragraph.slice(0, third) + prose(rand, third) + paragraph.slice(2 * third);
      })
    );
    measure('H1', assemble(base), assemble(reworded));
  }, 300_000);

  it('WR16 H2: three 150 000-character paragraphs with about 900 small edits each', () => {
    const rand = mulberry32(7);
    const giants = [prose(rand, 150_000), prose(rand, 150_000), prose(rand, 150_000)];
    const perChapter = paragraphsPerChapter(380, 150_000);
    const base = book(2, 380, perChapter, giants, [1, 5, 9]);
    const edited = book(
      2,
      380,
      perChapter,
      giants.map((giant) => withEdits(giant, 900, false)),
      [1, 5, 9]
    );
    measure('H2', assemble(base), assemble(edited));
  }, 300_000);

  it('WR16 H2b: three 99 000-character paragraphs with 450 one-character substitutions each (the worst case for character refinement)', () => {
    const rand = mulberry32(11);
    const giants = [prose(rand, 99_000), prose(rand, 99_000), prose(rand, 99_000)];
    const perChapter = paragraphsPerChapter(380, 99_000);
    const base = book(3, 380, perChapter, giants, [1, 5, 9]);
    const edited = book(
      3,
      380,
      perChapter,
      giants.map((giant) => withEdits(giant, 450, true)),
      [1, 5, 9]
    );
    measure('H2b', assemble(base), assemble(edited));
  }, 600_000);
});
