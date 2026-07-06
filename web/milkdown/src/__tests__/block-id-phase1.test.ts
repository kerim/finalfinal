import { describe, expect, it } from 'vitest';
import { meaningfulTextOverlap, phase1CanClaim } from '../block-id-plugin';

// Regression suite for the Phase-1 claim decision in `assignBlockIds`. The bug
// this guards against: a figure block at a shifted offset silently claimed a
// paragraph's old ID (from when that offset held a paragraph), producing
// catastrophic churn in BlockSyncService (observed signature: u=15 i=85 d=85
// per keystroke, DB growing from 135 → 184 blocks on a single character).
//
// The fix allows cross-type claims at the exact same offset EXCEPT when
// either side is in ATOMIC_BLOCK_TYPES (currently `{'figure', 'math_display'}`).
//
// A second regression suite (further below) guards a related bug: when a
// heading+body pair is deleted, the next heading (or its body) can slide into
// the deleted heading's old offset and — being type-compatible — steal its
// block ID, misattributing the DB delete. The fix adds a content-relatedness
// check (`meaningfulTextOverlap`), gated by `structureChanged`, so a same-type
// or convertible claim during structural churn must also look like an
// in-place edit of the SAME content, not an unrelated node landing on the
// same offset.
//
// All calls below pass 3 new trailing args: structureChanged, oldText, newText.
// Existing scenarios pass `structureChanged: false` (today's exact behavior/
// contract is unaffected by the content check, which only engages when
// structureChanged is true) with placeholder old/new text that is never read.

const NO_CLAIMED: ReadonlySet<string> = new Set();

// Placeholder text for structureChanged:false cases — never read by
// phase1CanClaim, since the content check is gated on structureChanged.
const IRRELEVANT_OLD = 'irrelevant-old-text';
const IRRELEVANT_NEW = 'irrelevant-new-text';

describe('phase1CanClaim — same-type claims', () => {
  it('paragraph at paragraph offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('figure at figure offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('figure', 'figure', 'id-f', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(true);
  });

  it('heading at heading offset with unclaimed ID → true', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-h', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(true);
  });
});

describe('phase1CanClaim — legitimate in-place input-rule conversions', () => {
  it('heading at paragraph offset (# input rule) → true', () => {
    expect(phase1CanClaim('heading', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('paragraph at heading offset (delete # prefix) → true', () => {
    expect(phase1CanClaim('paragraph', 'heading', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('bullet_list at paragraph offset (- input rule) → true', () => {
    expect(phase1CanClaim('bullet_list', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('ordered_list at paragraph offset (1. input rule) → true', () => {
    expect(phase1CanClaim('ordered_list', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('blockquote at paragraph offset (> input rule) → true', () => {
    expect(phase1CanClaim('blockquote', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('code_block at paragraph offset (``` input rule) → true', () => {
    expect(phase1CanClaim('code_block', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      true
    );
  });

  it('table at paragraph offset (|a|b| GFM input rule) → true', () => {
    expect(phase1CanClaim('table', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(true);
  });

  it('paragraph at table offset (table deletion) → true', () => {
    expect(phase1CanClaim('paragraph', 'table', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(true);
  });

  it('horizontal_rule at paragraph offset (--- input rule) → true', () => {
    expect(
      phase1CanClaim('horizontal_rule', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)
    ).toBe(true);
  });

  it('byte-identical text passes even when structureChanged is true', () => {
    // Proves the content check doesn't punish legitimate in-place conversions
    // that happen to coincide with structural churn elsewhere in the doc.
    expect(phase1CanClaim('paragraph', 'heading', 'id-a', NO_CLAIMED, true, 'Same Text', 'Same Text')).toBe(true);
  });
});

describe('phase1CanClaim — atomic theft (the observed bug signature)', () => {
  it('figure at paragraph offset → false (the exact observed bug)', () => {
    expect(phase1CanClaim('figure', 'paragraph', 'id-p', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      false
    );
  });

  it('figure at heading offset → false', () => {
    expect(phase1CanClaim('figure', 'heading', 'id-h', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(false);
  });

  it('paragraph at figure offset → false (reverse theft)', () => {
    expect(phase1CanClaim('paragraph', 'figure', 'id-f', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      false
    );
  });

  it('heading at figure offset → false', () => {
    expect(phase1CanClaim('heading', 'figure', 'id-f', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(false);
  });
});

describe('phase1CanClaim — guard conditions', () => {
  it('no existing ID at offset → false', () => {
    expect(phase1CanClaim('paragraph', 'paragraph', undefined, NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      false
    );
  });

  it('no existing type at offset → false (even if id is present)', () => {
    // Defensive: if types are out-of-sync with ids, treat as unsafe and defer.
    expect(phase1CanClaim('paragraph', undefined, 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      false
    );
  });

  it('id already claimed earlier in this pass → false', () => {
    const claimed = new Set(['id-a']);
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', claimed, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(
      false
    );
  });

  it('same-type but id claimed → false (claim check takes precedence)', () => {
    const claimed = new Set(['id-f']);
    expect(phase1CanClaim('figure', 'figure', 'id-f', claimed, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(false);
  });
});

// ============================================================
// Content-relatedness under structural churn (header-delete-merge fix)
// ============================================================

describe('phase1CanClaim — same-type structural churn (header-delete-merge)', () => {
  it('unrelated heading sliding into a deleted heading slot → false', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-intro', NO_CLAIMED, true, 'Introduction', 'Conclusion')).toBe(
      false
    );
  });

  it('prefix continuation during unrelated churn elsewhere → true', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-a', NO_CLAIMED, true, 'Introductio', 'Introduction')).toBe(true);
  });

  it('byte-identical text during churn → true', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-a', NO_CLAIMED, true, 'Same Title', 'Same Title')).toBe(true);
  });
});

describe('phase1CanClaim — edge cases under structural churn', () => {
  it('both old and new text empty → true', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-a', NO_CLAIMED, true, '', '')).toBe(true);
  });

  it('old text empty, new text non-empty → false', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-a', NO_CLAIMED, true, '', 'Conclusion')).toBe(false);
  });

  it('old text non-empty, new text empty → false', () => {
    expect(phase1CanClaim('heading', 'heading', 'id-a', NO_CLAIMED, true, 'Introduction', '')).toBe(false);
  });
});

describe('phase1CanClaim — atomic exemption still holds under churn', () => {
  it('same-type figure claim allowed regardless of unrelated alt text', () => {
    expect(
      phase1CanClaim('figure', 'figure', 'id-f', NO_CLAIMED, true, 'unrelated-alt-text', 'totally-different-alt-text')
    ).toBe(true);
  });
});

describe('meaningfulTextOverlap', () => {
  it('exact match → true', () => {
    expect(meaningfulTextOverlap('Introduction', 'Introduction')).toBe(true);
  });

  it('prefix relationship → true', () => {
    expect(meaningfulTextOverlap('Intro', 'Introduction')).toBe(true);
  });

  it('suffix relationship → true', () => {
    expect(meaningfulTextOverlap('duction', 'Introduction')).toBe(true);
  });

  it('unrelated text → false', () => {
    expect(meaningfulTextOverlap('Introduction', 'Conclusion')).toBe(false);
  });

  it('undefined old text → false', () => {
    expect(meaningfulTextOverlap(undefined, 'Introduction')).toBe(false);
  });
});
