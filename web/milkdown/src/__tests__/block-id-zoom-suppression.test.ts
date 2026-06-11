import { type Node, Schema } from '@milkdown/kit/prose/model';
import { describe, expect, it } from 'vitest';
import { suppressTempIdInZoom, zoomNotesBoundary } from '../block-id-plugin';

// Regression suite for the zoom-mode temp-ID suppression boundary.
//
// The bug this guards against: while zoomed, `assignBlockIds` skipped temp-ID
// assignment for ALL unmatched nodes, so any paragraph created during zoom had
// no block ID, was invisible to block-sync, and never reached the database
// (word count frozen, text unsaved) until zoom-out. The suppression exists
// only to keep the appended mini-Notes tail (zoom_notes_marker + everything
// after it) out of the sync — so it must apply only at/after the marker.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    heading: {
      group: 'block',
      content: 'inline*',
      attrs: { level: { default: 1 } },
      toDOM: (node) => [`h${node.attrs.level}`, 0],
    },
    zoom_notes_marker: {
      group: 'block',
      atom: true,
      selectable: false,
      toDOM: () => ['div', { class: 'zoom-notes-marker' }],
    },
    text: { group: 'inline' },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

function heading(text: string, level = 1): Node {
  return schema.nodes.heading.create({ level }, [schema.text(text)]);
}

function marker(): Node {
  return schema.nodes.zoom_notes_marker.create();
}

describe('zoomNotesBoundary', () => {
  it('returns Infinity when no marker present (typical zoom without footnotes)', () => {
    const doc = schema.nodes.doc.create(null, [heading('Beta'), para('four five six.')]);
    expect(zoomNotesBoundary(doc)).toBe(Infinity);
  });

  it('returns the marker offset when present', () => {
    const h = heading('Beta');
    const p = para('four five six.');
    const doc = schema.nodes.doc.create(null, [h, p, marker(), heading('Notes'), para('[^1]: def')]);
    expect(zoomNotesBoundary(doc)).toBe(h.nodeSize + p.nodeSize);
  });

  it('returns 0 when the marker is the first node', () => {
    const doc = schema.nodes.doc.create(null, [marker(), heading('Notes')]);
    expect(zoomNotesBoundary(doc)).toBe(0);
  });
});

describe('suppressTempIdInZoom', () => {
  it('never suppresses outside zoom mode', () => {
    expect(suppressTempIdInZoom(false, 0, 0)).toBe(false);
    expect(suppressTempIdInZoom(false, 100, Infinity)).toBe(false);
  });

  it('in zoom mode without mini-Notes (boundary=Infinity), new blocks get temp IDs', () => {
    expect(suppressTempIdInZoom(true, 0, Infinity)).toBe(false);
    expect(suppressTempIdInZoom(true, 9999, Infinity)).toBe(false);
  });

  it('in zoom mode, blocks before the marker get temp IDs', () => {
    expect(suppressTempIdInZoom(true, 10, 50)).toBe(false);
    expect(suppressTempIdInZoom(true, 49, 50)).toBe(false);
  });

  it('in zoom mode, the marker and everything after it stay suppressed', () => {
    expect(suppressTempIdInZoom(true, 50, 50)).toBe(true);
    expect(suppressTempIdInZoom(true, 200, 50)).toBe(true);
  });
});
