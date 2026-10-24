// @vitest-environment jsdom
//
// t-4a8fd8af round 2b: pins for the CodeMirror redo carry (web/codemirror/src/redo-branch.ts).
//
// The carry reads and writes the editor's history ONLY through the public `historyField` JSON (`state.toJSON({history})`,
// `EditorState.fromJSON`) and relies on one behaviour of @codemirror/commands: a change that is not added to the history
// (`addToHistory: false`) maps BOTH history branches. These tests pin the library versions, the JSON shape and that behaviour, so
// an upgrade that changes any of them fails here, at build time, instead of silently losing the redo branch in the app.

import { history, historyField, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { ChangeSet, EditorState, Transaction } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { carryRedoBranch } from '../redo-branch';

const installedVersion = async (name: string): Promise<string> => {
  const { readFileSync } = await import('node:fs');
  const here = decodeURIComponent(import.meta.url.replace(/^file:\/\//, ''));
  const packageRoot = here.slice(0, here.indexOf('/src/__tests__/'));
  return JSON.parse(readFileSync([packageRoot, 'node_modules', name, 'package.json'].join('/'), 'utf8')).version;
};

function make(doc: string): EditorState {
  return EditorState.create({ doc, extensions: [history()] });
}

/** Types `text` at `pos` as a user keystroke would (a history step). */
function type(state: EditorState, pos: number, text: string): EditorState {
  return state.update({ changes: { from: pos, insert: text }, userEvent: 'input.type' }).state;
}
function undoOnce(state: EditorState): EditorState {
  let next = state;
  undo({ state, dispatch: (tr) => (next = tr.state) });
  return next;
}
function redoOnce(state: EditorState): EditorState {
  let next = state;
  redo({ state, dispatch: (tr) => (next = tr.state) });
  return next;
}

describe('the dependency versions and the history JSON shape the redo carry is built on', () => {
  it('the installed versions are the ones the carry was measured against', async () => {
    expect(await installedVersion('@codemirror/commands')).toBe('6.10.1');
    expect(await installedVersion('@codemirror/state')).toBe('6.5.4');
  });

  it('state.toJSON({history}) has { doc, selection, history: { done, undone } } with events { changes, selectionsAfter, ... }', () => {
    let state = make('hello world');
    state = type(state, 5, ' big');
    state = undoOnce(state);
    const json = state.toJSON({ history: historyField });
    expect(Object.keys(json).sort()).toEqual(['doc', 'history', 'selection']);
    expect(typeof json.doc).toBe('string');
    expect(Object.keys(json.history).sort()).toEqual(['done', 'undone']);
    expect(Array.isArray(json.history.done)).toBe(true);
    expect(Array.isArray(json.history.undone)).toBe(true);
    expect(json.history.undone).toHaveLength(1);
    const event = json.history.undone[json.history.undone.length - 1];
    expect(Array.isArray(event.changes)).toBe(true);
    expect(Array.isArray(event.selectionsAfter)).toBe(true);
    expect('startSelection' in event).toBe(true);
    // the changes JSON round-trips through the public ChangeSet API
    const set = ChangeSet.fromJSON(event.changes);
    expect(set.apply(state.doc).toString()).toBe('hello big world');
  });

  it('EditorState.fromJSON with the history field restores both branches (what the carry installs)', () => {
    let state = make('hello world');
    state = type(state, 5, ' big');
    state = type(state, 0, 'oh, ');
    state = undoOnce(state);
    expect(undoDepth(state)).toBe(1);
    expect(redoDepth(state)).toBe(1);
    const json = state.toJSON({ history: historyField });
    const back = EditorState.fromJSON(json, { extensions: [history()] }, { history: historyField });
    expect(back.doc.toString()).toBe(state.doc.toString());
    expect(undoDepth(back)).toBe(1);
    expect(redoDepth(back)).toBe(1);
    expect(redoOnce(back).doc.toString()).toBe('oh, hello big world');
  });

  it('a change that is not added to the history maps the redo branch (the behaviour the carry relies on)', () => {
    let state = make('0123456789');
    state = type(state, 5, 'X');
    state = undoOnce(state); // redo branch: insert X at 5
    state = state.update({
      changes: { from: 0, insert: 'abc' },
      annotations: Transaction.addToHistory.of(false),
    }).state;
    expect(redoDepth(state)).toBe(1);
    expect(redoOnce(state).doc.toString()).toBe('abc01234X56789'); // X still lands between 4 and 5, shifted by the 3 inserted characters
    // An undone INSERTION inside a removed range survives the mapping (it lands at the range's start): only a change that has nothing
    // left to act on maps away. Pinned because the carry inherits it (a known, rare limitation: redo after Delete + undo of the Delete).
    let other = make('0123456789');
    other = type(other, 5, 'X');
    other = undoOnce(other);
    other = other.update({ changes: { from: 3, to: 8 }, annotations: Transaction.addToHistory.of(false) }).state;
    expect(redoDepth(other)).toBe(1);
    expect(redoOnce(other).doc.toString()).toBe('012X89');
    // A typed insertion in the UNDO branch whose text is then removed maps away completely.
    let done = make('0123456789');
    done = type(done, 5, 'X');
    done = done.update({ changes: { from: 3, to: 8 }, annotations: Transaction.addToHistory.of(false) }).state;
    expect(undoDepth(done)).toBe(0);
  });
});

describe('carryRedoBranch', () => {
  const extensions = [history()];

  it('returns null when neither state has anything to redo', () => {
    const checkpoint = make('hello world');
    expect(carryRedoBranch(checkpoint, checkpoint, undefined, extensions)).toBeNull();
  });

  it('carries the live redo branch onto the checkpoint document (line diff, no stored change set)', () => {
    const checkpoint = make('first\n\nsecond\n\nthird\n');
    // live: the second paragraph removed (history-neutral), then typing in "third" and an undo of it
    let live = checkpoint.update({
      changes: { from: 7, to: 15 },
      annotations: Transaction.addToHistory.of(false),
    }).state;
    expect(live.doc.toString()).toBe('first\n\nthird\n');
    live = type(live, 12, '!');
    live = undoOnce(live);
    expect(redoDepth(live)).toBe(1);

    const carry = carryRedoBranch(live, checkpoint, undefined, extensions);
    expect(carry, JSON.stringify(carry)).toMatchObject({ carried: true, events: 1 });
    if (!carry?.carried) return;
    expect(carry.state.doc.toString()).toBe('first\n\nsecond\n\nthird\n');
    expect(redoDepth(carry.state)).toBe(1);
    // the "!" lands after "third", shifted by the restored paragraph
    expect(redoOnce(carry.state).doc.toString()).toBe('first\n\nsecond\n\nthird!\n');
  });

  it('carries with the stored change set', () => {
    const checkpoint = make('first\n\nsecond\n\nthird\n');
    const opChanges = ChangeSet.of([{ from: 7, to: 15 }], checkpoint.doc.length); // the command removed "second\n\n"
    let live = checkpoint.update({ changes: opChanges, annotations: Transaction.addToHistory.of(false) }).state;
    live = type(live, 12, '!');
    live = undoOnce(live);
    const carry = carryRedoBranch(live, checkpoint, opChanges, extensions);
    expect(carry, JSON.stringify(carry)).toMatchObject({ carried: true, events: 1 });
    if (!carry?.carried) return;
    expect(redoOnce(carry.state).doc.toString()).toBe('first\n\nsecond\n\nthird!\n');
  });

  it('reports a failure (here: a change set of the wrong length) instead of installing a wrong redo branch', () => {
    const checkpoint = make('first\n\nsecond\n\nthird\n');
    let live = checkpoint.update({
      changes: { from: 7, to: 15 },
      annotations: Transaction.addToHistory.of(false),
    }).state;
    live = type(live, 12, '!');
    live = undoOnce(live);
    const wrong = ChangeSet.of([{ from: 0, insert: 'x' }], 3);
    const carry = carryRedoBranch(live, checkpoint, wrong, extensions);
    expect(carry?.carried).toBe(false);
  });
});
