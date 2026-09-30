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

  it('hr at paragraph offset (--- input rule) → true', () => {
    expect(phase1CanClaim('hr', 'paragraph', 'id-a', NO_CLAIMED, false, IRRELEVANT_OLD, IRRELEVANT_NEW)).toBe(true);
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

// ============================================================
// replacedOccupant (F4 replace variant, t-65a6a268): the 11th param,
// scoped to the CROSS-TYPE branch only. A flagged raw-fallback claim
// (t-452ca407's `flagged`, passed through as this parameter at the single
// Phase 1 call site) that crosses type AND has both old and new text empty
// is refused outright -- there is no textual evidence of relatedness left
// once both sides are empty, and the type change is itself evidence AGAINST
// relatedness. The same-type branch never looks at this parameter at all.
// ============================================================

describe('phase1CanClaim — replacedOccupant (F4 replace variant)', () => {
  it('cross-type + flagged=true + both empty texts → false', () => {
    expect(
      phase1CanClaim('paragraph', 'heading', 'id-h', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true)
    ).toBe(false);
  });

  it('same call with flagged=false → true (the refusal never engages without the flag)', () => {
    expect(
      phase1CanClaim('paragraph', 'heading', 'id-h', NO_CLAIMED, true, '', '', undefined, undefined, undefined, false)
    ).toBe(true);
  });

  it('same-type + flagged=true + both empty → true (same-type branch is untouched by this parameter)', () => {
    expect(
      phase1CanClaim('heading', 'heading', 'id-h', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true)
    ).toBe(true);
  });

  it('cross-type + flagged=true + matching non-empty texts → true (a text-related claim is untouched)', () => {
    expect(
      phase1CanClaim(
        'paragraph',
        'heading',
        'id-h',
        NO_CLAIMED,
        true,
        'Same Text',
        'Same Text',
        undefined,
        undefined,
        undefined,
        true
      )
    ).toBe(true);
  });

  // newSideLeaf (discovered via a real regression in
  // repro-list-paste.test.ts, not anticipated by this refusal's original
  // design): Milkdown's own "---" input rule converts an empty paragraph to
  // `hr` via the exact same same-offset, cross-type, wholly-replaced
  // replaceWith shape as the illegitimate replace-variant theft -- verified
  // empirically indistinguishable at the tr.mapping level. `hr` is a
  // schema-level leaf type (no content expression at all), so its
  // `textContent` is ALWAYS '' regardless of relatedness -- this parameter
  // keeps the refusal from firing on that unavoidable emptiness. Checks ONLY
  // the NEW side (the claim's destination type), deliberately -- see the
  // next describe block for why exempting the OLD side too would reopen a
  // real theft in the reverse direction.
  it('cross-type + flagged=true + both empty texts + newSideLeaf=true → true (a leaf-type conversion, e.g. paragraph -> hr, is untouched)', () => {
    expect(
      phase1CanClaim('hr', 'paragraph', 'id-p', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true, true)
    ).toBe(true);
  });

  it('same call with newSideLeaf=false → false (the exemption only applies when the NEW side really is leaf)', () => {
    expect(
      phase1CanClaim('hr', 'paragraph', 'id-p', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true, false)
    ).toBe(false);
  });
});

// ============================================================
// newSideLeaf checks ONLY the new side, never the old occupant (review
// finding, confirmed by the judge): an earlier version of this exemption
// also excused a leaf OLD occupant, which reopens a real theft in the
// REVERSE direction -- an hr (or section_break) deleted as part of a LARGER
// selection reports `deletedAcross`, not the single-span `deletedAfter`-only
// shape `deletedOldPositions` already refuses on its own (see that
// computation's own comment above), so the hr's old position never lands in
// `deletedOldPositions` -- with the old side exempted too, an unrelated
// empty paragraph/heading landing on that hr's old offset would inherit the
// hr's id outright: the theft this whole refusal exists to close, just with
// the hr as the victim instead of the thief. `newSideLeaf` is computed from
// `node.type.isLeaf` alone (the call site never even looks at the OLD node's
// leaf-ness any more), so passing `newSideLeaf` computed for a paragraph/
// heading destination (never leaf) always leaves the refusal engaged
// regardless of what the OLD occupant was.
// ============================================================

describe('phase1CanClaim — newSideLeaf does not exempt a leaf OLD occupant (reverse-direction regression)', () => {
  it('cross-type + flagged=true + both empty texts, OLD side leaf (hr) but NEW side is not → still false', () => {
    // Models: an hr, deleted as part of a larger selection, whose old slot
    // is then occupied by a brand-new empty paragraph -- newType='paragraph'
    // is never leaf, so newSideLeaf must be false here regardless of the OLD
    // occupant having been `hr`.
    expect(
      phase1CanClaim('paragraph', 'hr', 'id-hr', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true, false)
    ).toBe(false);
  });

  it('same shape with a heading landing on the old hr slot → still false', () => {
    expect(
      phase1CanClaim('heading', 'hr', 'id-hr', NO_CLAIMED, true, '', '', undefined, undefined, undefined, true, false)
    ).toBe(false);
  });

  it('same shape with section_break as the old occupant → still false', () => {
    expect(
      phase1CanClaim(
        'paragraph',
        'section_break',
        'id-sb',
        NO_CLAIMED,
        true,
        '',
        '',
        undefined,
        undefined,
        undefined,
        true,
        false
      )
    ).toBe(false);
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
