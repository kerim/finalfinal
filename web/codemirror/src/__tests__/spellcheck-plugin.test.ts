import { EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { reconcileResultsAfterEdit, type SpellcheckResult } from '../spellcheck-plugin';

function stateForText(doc: string): EditorState {
  return EditorState.create({ doc });
}

function rangeOf(text: string, word: string): { from: number; to: number } {
  const idx = text.indexOf(word);
  if (idx < 0) throw new Error(`"${word}" not found in "${text}"`);
  return { from: idx, to: idx + word.length };
}

function resultFor(text: string, word: string, type: SpellcheckResult['type'] = 'spelling'): SpellcheckResult {
  const { from, to } = rangeOf(text, word);
  return { from, to, word, type, suggestions: [] };
}

describe('reconcileResultsAfterEdit (CodeMirror)', () => {
  it('drops a result when the edit replaces its entire range (accept-suggestion flow)', () => {
    const text = 'I seen the quikc brown fox';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    const tr = state.update({ changes: { from: result.from, to: result.to, insert: 'quick' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result when text is edited strictly inside its range', () => {
    const text = 'a runing dog';
    const state = stateForText(text);
    const result = resultFor(text, 'runing');
    const midpoint = result.from + 3;
    const tr = state.update({ changes: { from: midpoint, to: midpoint, insert: 'X' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result on a zero-width insertion exactly at its trailing boundary', () => {
    const text = 'a runnin dog';
    const state = stateForText(text);
    const result = resultFor(text, 'runnin');
    // Type the missing "g" right after the flagged word ("runnin" -> "running").
    const tr = state.update({ changes: { from: result.to, to: result.to, insert: 'g' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result on a zero-width insertion exactly at its leading boundary', () => {
    const text = 'a nother dog';
    const state = stateForText(text);
    const result = resultFor(text, 'nother');
    // Type the missing "a" right before the flagged word ("nother" -> "another").
    const tr = state.update({ changes: { from: result.from, to: result.from, insert: 'a' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(0);
  });

  it('keeps and remaps a result when the edit is elsewhere in the document', () => {
    const text = 'a quikc fox and a lazy dog';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    const tr = state.update({ changes: { from: text.length, to: text.length, insert: '!!!' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].from).toBe(result.from);
    expect(survivors[0].to).toBe(result.to);
  });

  it('keeps and remaps a result when an unrelated edit happens before it in the document', () => {
    const text = 'hello quikc fox';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    const tr = state.update({ changes: { from: 0, to: 0, insert: 'XX' } });

    const survivors = reconcileResultsAfterEdit([result], tr.changes);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].from).toBe(result.from + 2);
    expect(survivors[0].to).toBe(result.to + 2);
  });

  it('handles a transaction with two separate changes: drops the touched result, remaps the untouched one', () => {
    const text = 'quikc fox jumps over the lasy dog';
    const state = stateForText(text);
    const first = resultFor(text, 'quikc');
    const second = resultFor(text, 'lasy');

    // Change 1 fixes "quikc" -> "quick," (one character longer, touches `first`).
    // Change 2 inserts at the very end of the (original) doc — far from `second`, so this
    // exercises a multi-range changeset without touching it. Both changes' positions are
    // given in the original document's coordinates: CM6 combines simultaneous, non-overlapping
    // change specs passed to one `update()` call rather than sequencing them.
    const tr = state.update(
      { changes: { from: first.from, to: first.to, insert: 'quick,' } },
      { changes: { from: text.length, to: text.length, insert: '!' } }
    );

    const survivors = reconcileResultsAfterEdit([first, second], tr.changes);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].word).toBe('lasy');
    // "quick," is one character longer than "quikc", so `second`'s position shifts by +1.
    expect(survivors[0].from).toBe(second.from + 1);
    expect(survivors[0].to).toBe(second.to + 1);
  });
});
