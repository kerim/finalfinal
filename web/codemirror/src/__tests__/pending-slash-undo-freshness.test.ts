// N3 (major, Phase B remediation plan): CodeMirror's capture-phase unified-undo interceptor
// already ran BEFORE its own slash-undo keymap check (main.ts's `Mod-z` binding fires only
// after the document-level capture listener has declined to route the keystroke structurally)
// -- the correct, canonical "structural-first" order per the plan. Milkdown had this backwards
// (fixed in web/milkdown/src/slash-commands.ts, see its own N3 tests) and needed reordering.
// What CodeMirror was ALSO missing, same as Milkdown: an explicit freshness bound on
// `pendingSlashUndo` -- nothing reset it except an actual editing keystroke, so a slash
// command followed by clicking elsewhere and waiting left it silently armed to hijack an
// unrelated later Cmd-Z indefinitely. These tests exercise the actual new behavior
// (`isPendingSlashUndoFresh`) directly, since main.ts's `Mod-z` keymap binding itself is
// defined inline (not exported) and isn't unit-testable in isolation without a larger main.ts
// refactor out of scope for this pass.

import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  getPendingSlashUndo,
  isPendingSlashUndoFresh,
  PENDING_SLASH_UNDO_FRESHNESS_MS,
  setPendingSlashUndo,
} from '../editor-state';

describe('isPendingSlashUndoFresh (N3)', () => {
  afterEach(() => {
    setPendingSlashUndo(false);
    vi.useRealTimers();
  });

  it('is false when nothing is pending', () => {
    expect(isPendingSlashUndoFresh()).toBe(false);
  });

  it('is true immediately after being set', () => {
    setPendingSlashUndo(true);
    expect(isPendingSlashUndoFresh()).toBe(true);
    expect(getPendingSlashUndo()).toBe(true); // sanity: the underlying flag is genuinely set
  });

  it('stays true just before the freshness window elapses', () => {
    vi.useFakeTimers();
    setPendingSlashUndo(true);
    vi.advanceTimersByTime(PENDING_SLASH_UNDO_FRESHNESS_MS - 1);

    expect(isPendingSlashUndoFresh()).toBe(true);
  });

  it('becomes false once the freshness window elapses -- the actual N3 bug fix, since nothing else ever resets this flag except an editing keystroke', () => {
    vi.useFakeTimers();
    setPendingSlashUndo(true);
    vi.advanceTimersByTime(PENDING_SLASH_UNDO_FRESHNESS_MS + 1);

    expect(isPendingSlashUndoFresh()).toBe(false);
    // The underlying flag itself is untouched by the freshness check (only the derived
    // "should we act on it" answer changes) -- matches production: main.ts's Mod-z binding
    // reads isPendingSlashUndoFresh(), never mutates pendingSlashUndo based on staleness.
    expect(getPendingSlashUndo()).toBe(true);
  });

  it('setting the flag again resets the freshness clock', () => {
    vi.useFakeTimers();
    setPendingSlashUndo(true);
    vi.advanceTimersByTime(PENDING_SLASH_UNDO_FRESHNESS_MS + 1);
    expect(isPendingSlashUndoFresh()).toBe(false);

    setPendingSlashUndo(true); // a second slash command runs
    expect(isPendingSlashUndoFresh()).toBe(true);
  });
});
