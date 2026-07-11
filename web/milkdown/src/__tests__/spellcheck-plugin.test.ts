// @vitest-environment jsdom
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { reconcileResultsAfterEdit, type SpellcheckResult } from '../spellcheck-plugin';

// Minimal doc/schema — plain text only, mirrors smart-quotes-plugin.test.ts. Underline
// clearing only needs text positions, no marks.
const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'text*', toDOM: () => ['p', 0] },
    text: {},
  },
});

/** Position 1 is the start of the paragraph's text content (position 0 is the doc/paragraph
 *  open boundary). */
const TEXT_START = 1;

function stateForText(raw: string): EditorState {
  const doc = schema.node('doc', null, [schema.node('paragraph', null, raw ? [schema.text(raw)] : [])]);
  return EditorState.create({ doc });
}

function rangeOf(text: string, word: string): { from: number; to: number } {
  const idx = text.indexOf(word);
  if (idx < 0) throw new Error(`"${word}" not found in "${text}"`);
  return { from: TEXT_START + idx, to: TEXT_START + idx + word.length };
}

function resultFor(text: string, word: string, type: SpellcheckResult['type'] = 'spelling'): SpellcheckResult {
  const { from, to } = rangeOf(text, word);
  return { from, to, word, type, suggestions: [] };
}

describe('reconcileResultsAfterEdit (Milkdown/ProseMirror)', () => {
  it('drops a result when the edit replaces its entire range (accept-suggestion flow)', () => {
    const text = 'I seen the quikc brown fox';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    // Mirrors spellcheck-plugin.ts's onReplace handler exactly: replaceWith(from, to, text).
    const tr = state.tr.replaceWith(result.from, result.to, schema.text('quick'));

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result when text is edited strictly inside its range', () => {
    const text = 'a runing dog';
    const state = stateForText(text);
    const result = resultFor(text, 'runing');
    const midpoint = result.from + 3;
    const tr = state.tr.insertText('X', midpoint);

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result on a zero-width insertion exactly at its trailing boundary', () => {
    const text = 'a runnin dog';
    const state = stateForText(text);
    const result = resultFor(text, 'runnin');
    // Type the missing "g" right after the flagged word ("runnin" -> "running").
    const tr = state.tr.insertText('g', result.to);

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(0);
  });

  it('drops a result on a zero-width insertion exactly at its leading boundary', () => {
    const text = 'a nother dog';
    const state = stateForText(text);
    const result = resultFor(text, 'nother');
    // Type the missing "a" right before the flagged word ("nother" -> "another").
    const tr = state.tr.insertText('a', result.from);

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(0);
  });

  it('keeps and remaps a result when the edit is elsewhere in the document', () => {
    const text = 'a quikc fox and a lazy dog';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    // Insert well after the flagged word, at the very end of the text.
    const tr = state.tr.insertText('!!!', state.doc.content.size - 1);

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].from).toBe(result.from);
    expect(survivors[0].to).toBe(result.to);
  });

  it('keeps and remaps a result when an unrelated edit happens before it in the document', () => {
    const text = 'hello quikc fox';
    const state = stateForText(text);
    const result = resultFor(text, 'quikc');
    const tr = state.tr.insertText('XX', TEXT_START);

    const survivors = reconcileResultsAfterEdit([result], tr);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].from).toBe(result.from + 2);
    expect(survivors[0].to).toBe(result.to + 2);
  });

  it('handles a multi-step transaction: drops the touched result, remaps the untouched one', () => {
    const text = 'quikc fox jumps over the lasy dog';
    const state = stateForText(text);
    const first = resultFor(text, 'quikc');
    const second = resultFor(text, 'lasy');

    // Step 1 fixes "quikc" -> "quick," (one character longer, touches `first`).
    // Step 2 inserts at the very end of the doc as it stands after step 1 — far from
    // `second`, so this exercises multi-step backward-mapping without touching it.
    let tr = state.tr.replaceWith(first.from, first.to, schema.text('quick,'));
    const endOfDocAfterStep1 = tr.mapping.map(state.doc.content.size - 1);
    tr = tr.insertText('!', endOfDocAfterStep1);

    const survivors = reconcileResultsAfterEdit([first, second], tr);

    expect(survivors).toHaveLength(1);
    expect(survivors[0].word).toBe('lasy');
    // "quick," is one character longer than "quikc", so `second`'s position shifts by +1.
    expect(survivors[0].from).toBe(second.from + 1);
    expect(survivors[0].to).toBe(second.to + 1);
  });
});
