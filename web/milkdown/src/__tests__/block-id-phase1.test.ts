import { describe, expect, it } from 'vitest';
import { phase1CanClaim } from '../block-id-plugin';

// Regression suite for the Phase-1 claim decision in `assignBlockIds`. The bug
// this guards against: a figure block at a shifted offset silently claimed a
// paragraph's old ID (from when that offset held a paragraph), producing
// catastrophic churn in BlockSyncService (observed signature: u=15 i=85 d=85
// per keystroke, DB growing from 135 → 184 blocks on a single character).
//
// The fix allows cross-type claims at the exact same offset EXCEPT when
// either side is in ATOMIC_BLOCK_TYPES (currently `{'figure'}`).

const NO_CLAIMED: ReadonlySet<string> = new Set();

describe('phase1CanClaim — same-type claims', () => {
  it('paragraph at paragraph offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('figure at figure offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('figure', 'figure', 'id-f', NO_CLAIMED)).toBe(true);
  });

  it('heading at heading offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-h', NO_CLAIMED)).toBe(true);
  });
});

describe('phase1CanClaim — legitimate in-place input-rule conversions', () => {
  it('heading at paragraph offset (# input rule) → true', () => {
    expect(phase1CanClaim('heading', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('paragraph at heading offset (delete # prefix) → true', () => {
    expect(phase1CanClaim('paragraph', 'heading', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('bullet_list at paragraph offset (- input rule) → true', () => {
    expect(phase1CanClaim('bullet_list', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('ordered_list at paragraph offset (1. input rule) → true', () => {
    expect(phase1CanClaim('ordered_list', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('blockquote at paragraph offset (> input rule) → true', () => {
    expect(phase1CanClaim('blockquote', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('code_block at paragraph offset (``` input rule) → true', () => {
    expect(phase1CanClaim('code_block', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('table at paragraph offset (|a|b| GFM input rule) → true', () => {
    expect(phase1CanClaim('table', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('paragraph at table offset (table deletion) → true', () => {
    expect(phase1CanClaim('paragraph', 'table', 'id-a', NO_CLAIMED)).toBe(true);
  });

  it('horizontal_rule at paragraph offset (--- input rule) → true', () => {
    expect(phase1CanClaim('horizontal_rule', 'paragraph', 'id-a', NO_CLAIMED)).toBe(true);
  });
});

describe('phase1CanClaim — atomic theft (the observed bug signature)', () => {
  it('figure at paragraph offset → false (the exact observed bug)', () => {
    expect(phase1CanClaim('figure', 'paragraph', 'id-p', NO_CLAIMED)).toBe(false);
  });

  it('figure at heading offset → false', () => {
    expect(phase1CanClaim('figure', 'heading', 'id-h', NO_CLAIMED)).toBe(false);
  });

  it('paragraph at figure offset → false (reverse theft)', () => {
    expect(phase1CanClaim('paragraph', 'figure', 'id-f', NO_CLAIMED)).toBe(false);
  });

  it('heading at figure offset → false', () => {
    expect(phase1CanClaim('heading', 'figure', 'id-f', NO_CLAIMED)).toBe(false);
  });
});

describe('phase1CanClaim — guard conditions', () => {
  it('no existing ID at offset → false', () => {
    expect(phase1CanClaim('paragraph', 'paragraph', undefined, NO_CLAIMED)).toBe(false);
  });

  it('no existing type at offset → false (even if id is present)', () => {
    // Defensive: if types are out-of-sync with ids, treat as unsafe and defer.
    expect(phase1CanClaim('paragraph', undefined, 'id-a', NO_CLAIMED)).toBe(false);
  });

  it('id already claimed earlier in this pass → false', () => {
    const claimed = new Set(['id-a']);
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', claimed)).toBe(false);
  });

  it('same-type but id claimed → false (claim check takes precedence)', () => {
    const claimed = new Set(['id-f']);
    expect(phase1CanClaim('figure', 'figure', 'id-f', claimed)).toBe(false);
  });
});
