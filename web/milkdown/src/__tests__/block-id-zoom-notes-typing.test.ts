// @vitest-environment jsdom
//
// Typing in a zoomed chapter that has a mini-Notes tail keeps every block's own id.
//
// The fault this guards against: the mini-Notes tail (the `zoom_notes_marker` node and everything after it) is left without block ids
// on purpose, but `assignBlockIds` counted those id-less blocks when it compared the block count with the number of known ids. So in
// such a zoom every keystroke looked like a structural change, and the structural route accepts a claim only when text was added at
// the very start or end of a block. The second key typed at the start of the zoomed heading ("p" then "5" makes "p5Chapter Two") and
// any key typed in the middle of a paragraph were refused: the block lost its id and block-sync sent a DELETE plus an INSERT, and an
// insert with no anchor lands at the end of the whole document in Swift. Notes: docs/architecture/write-queue-plan/phase5/a9-notes.md,
// "Zoomed block ids fix".

import { describe, expect, it } from 'vitest';
import { getBlockChangesApi, setContentWithBlockIds } from '../api-content';
import { zoomNotesMarkerPlugin } from '../zoom-notes-marker-plugin';
import {
  heading,
  idsInOrder,
  makeEditor,
  markdownOf,
  para,
  type Spec,
  sleep,
  waitForRAF,
} from './editor-first-harness';

const zoomedChapter: Spec[] = [
  heading('h2', 1, 'Chapter Two'),
  para('p2', 'Second paragraph[^1] with a note.'),
  { name: 'zn', md: '<!-- ::zoom-notes:: -->' },
  { name: 'nh', md: '# Notes' },
  { name: 'nd', md: '[^1]: A note.' },
];

/** Loads the zoomed chapter the way Swift does: ids for the chapter's own blocks only, the mini-Notes get none. */
async function loadZoomedWithNotes(): Promise<void> {
  setContentWithBlockIds(markdownOf(zoomedChapter), ['h2', 'p2'], { zoomMode: true });
  await waitForRAF();
  getBlockChangesApi();
  expect(idsInOrder()).toEqual(['h2', 'p2']);
}

/** Start position of the text inside the first top-level block whose text starts with `startsWith`. */
function textStart(
  view: { state: { doc: { forEach: (f: (node: any, offset: number) => void) => void } } },
  startsWith: string
) {
  let at = -1;
  view.state.doc.forEach((node, offset) => {
    if (at === -1 && node.textContent.startsWith(startsWith)) at = offset + 1;
  });
  expect(at, `block starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  return at;
}

describe('typing in a zoomed chapter with a mini-Notes tail', () => {
  it('"p" then "5" at the start of the zoomed heading is one update of the heading, no insert, no delete', async () => {
    const { view } = await makeEditor([zoomNotesMarkerPlugin]);
    await loadZoomedWithNotes();
    const start = textStart(view, 'Chapter Two');
    view.dispatch(view.state.tr.insertText('p', start));
    view.dispatch(view.state.tr.insertText('5', start + 1));
    expect(view.state.doc.firstChild?.textContent).toBe('p5Chapter Two');
    await sleep(150);
    const changes = getBlockChangesApi();
    expect(changes.deletes).toEqual([]);
    expect(changes.inserts).toEqual([]);
    expect(changes.updates.map((update) => update.id)).toEqual(['h2']);
    expect(changes.updates[0].markdownFragment).toContain('p5Chapter Two');
    expect(idsInOrder()).toEqual(['h2', 'p2']);
  });

  it('a key typed in the middle of a paragraph is one update of the paragraph, no insert, no delete', async () => {
    const { view } = await makeEditor([zoomNotesMarkerPlugin]);
    await loadZoomedWithNotes();
    const middle = textStart(view, 'Second paragraph') + 'Second'.length;
    view.dispatch(view.state.tr.insertText('x', middle));
    await sleep(150);
    const changes = getBlockChangesApi();
    expect(changes.deletes).toEqual([]);
    expect(changes.inserts).toEqual([]);
    expect(changes.updates.map((update) => update.id)).toEqual(['p2']);
    expect(changes.updates[0].markdownFragment).toContain('Secondx paragraph');
    expect(idsInOrder()).toEqual(['h2', 'p2']);
  });
});
