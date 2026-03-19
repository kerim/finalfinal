// Formatting API methods for CodeMirror source editor
// Provides callable formatting methods exposed via window.FinalFinal

import { insertLink, wrapSelection } from './api';
import { getEditorView } from './editor-state';

/**
 * Toggle inline markdown wrapper (e.g. ** for bold, * for italic, ~~ for strikethrough).
 * Follows the pattern from toggleHighlight() in api.ts:
 * 1. Check if chars before/after selection === wrapper → unwrap
 * 2. Check if selection starts/ends with wrapper → unwrap (strip them)
 * 3. Otherwise → wrap
 *
 * For single-char wrappers (italic `*`), guards against unwrapping part of a
 * multi-char wrapper (e.g. `**` for bold).
 */
function toggleInlineWrap(wrapper: string): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from, to } = view.state.selection.main;
  const wLen = wrapper.length;

  // Require a selection for toggle behavior
  if (from === to) {
    wrapSelection(wrapper);
    return true;
  }

  const selectedText = view.state.sliceDoc(from, to);
  const docLen = view.state.doc.length;

  // Case 1: Surrounding chars match wrapper → unwrap by removing them
  const before = from >= wLen ? view.state.sliceDoc(from - wLen, from) : '';
  const after = to + wLen <= docLen ? view.state.sliceDoc(to, to + wLen) : '';

  if (before === wrapper && after === wrapper) {
    // For single-char wrappers, ensure we're not inside a longer marker (e.g. ** for bold)
    if (wLen === 1) {
      const outerBefore = from >= wLen + 1 ? view.state.sliceDoc(from - wLen - 1, from - wLen) : '';
      const outerAfter = to + wLen + 1 <= docLen ? view.state.sliceDoc(to + wLen, to + wLen + 1) : '';
      if (outerBefore === wrapper || outerAfter === wrapper) {
        // Part of a longer marker — don't unwrap, just wrap instead
        wrapSelection(wrapper);
        return true;
      }
    }

    view.dispatch({
      changes: [
        { from: from - wLen, to: from, insert: '' },
        { from: to, to: to + wLen, insert: '' },
      ],
      selection: { anchor: from - wLen, head: to - wLen },
    });
    return true;
  }

  // Case 2: Selection itself starts/ends with wrapper → strip them
  if (selectedText.startsWith(wrapper) && selectedText.endsWith(wrapper) && selectedText.length > wLen * 2) {
    const innerText = selectedText.slice(wLen, -wLen);
    view.dispatch({
      changes: { from, to, insert: innerText },
      selection: { anchor: from, head: from + innerText.length },
    });
    return true;
  }

  // Case 3: Not wrapped → wrap
  wrapSelection(wrapper);
  return true;
}

export function toggleBold(): boolean {
  return toggleInlineWrap('**');
}

export function toggleItalic(): boolean {
  return toggleInlineWrap('*');
}

export function toggleStrikethrough(): boolean {
  return toggleInlineWrap('~~');
}

export function setHeading(level: number): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from } = view.state.selection.main;
  const line = view.state.doc.lineAt(from);
  const lineText = line.text;

  // Remove existing heading markers
  const cleanText = lineText.replace(/^#+\s*/, '');

  // Level 0 = paragraph (just remove heading markers)
  const prefix = level > 0 ? `${'#'.repeat(level)} ` : '';
  const newLine = prefix + cleanText;

  view.dispatch({
    changes: { from: line.from, to: line.to, insert: newLine },
  });
  return true;
}

export function toggleBulletList(): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from } = view.state.selection.main;
  const line = view.state.doc.lineAt(from);
  const lineText = line.text;

  // Toggle: if line starts with "- ", remove it; otherwise add it
  if (/^\s*- /.test(lineText)) {
    const newLine = lineText.replace(/^(\s*)- /, '$1');
    view.dispatch({ changes: { from: line.from, to: line.to, insert: newLine } });
  } else {
    // Remove numbered list prefix if present, then add bullet
    const cleanText = lineText.replace(/^(\s*)\d+\.\s+/, '$1');
    const match = cleanText.match(/^(\s*)/);
    const indent = match ? match[1] : '';
    const content = cleanText.trimStart();
    view.dispatch({ changes: { from: line.from, to: line.to, insert: `${indent}- ${content}` } });
  }
  return true;
}

export function toggleNumberList(): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from } = view.state.selection.main;
  const line = view.state.doc.lineAt(from);
  const lineText = line.text;

  // Toggle: if line starts with "N. ", remove it; otherwise add it
  if (/^\s*\d+\.\s+/.test(lineText)) {
    const newLine = lineText.replace(/^(\s*)\d+\.\s+/, '$1');
    view.dispatch({ changes: { from: line.from, to: line.to, insert: newLine } });
  } else {
    // Remove bullet prefix if present, then add number
    const cleanText = lineText.replace(/^(\s*)- /, '$1');
    const match = cleanText.match(/^(\s*)/);
    const indent = match ? match[1] : '';
    const content = cleanText.trimStart();
    view.dispatch({ changes: { from: line.from, to: line.to, insert: `${indent}1. ${content}` } });
  }
  return true;
}

export function toggleBlockquote(): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from } = view.state.selection.main;
  const line = view.state.doc.lineAt(from);
  const lineText = line.text;

  // Toggle: if line starts with "> ", remove it; otherwise add it
  if (/^>\s?/.test(lineText)) {
    const newLine = lineText.replace(/^>\s?/, '');
    view.dispatch({ changes: { from: line.from, to: line.to, insert: newLine } });
  } else {
    view.dispatch({ changes: { from: line.from, to: line.to, insert: `> ${lineText}` } });
  }
  return true;
}

export function toggleCodeBlock(): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from, to } = view.state.selection.main;
  const fromLine = view.state.doc.lineAt(from);
  const toLine = view.state.doc.lineAt(to);

  // Check if we're already inside a code fence
  const prevLineNum = fromLine.number > 1 ? fromLine.number - 1 : 0;
  const nextLineNum = toLine.number < view.state.doc.lines ? toLine.number + 1 : 0;

  if (prevLineNum > 0 && nextLineNum > 0) {
    const prevLine = view.state.doc.line(prevLineNum);
    const nextLine = view.state.doc.line(nextLineNum);

    if (/^```/.test(prevLine.text) && /^```$/.test(nextLine.text)) {
      // Remove fences
      view.dispatch({
        changes: [
          { from: prevLine.from, to: prevLine.to + 1, insert: '' },
          { from: nextLine.from - 1, to: nextLine.to, insert: '' },
        ],
      });
      return true;
    }
  }

  // Add code fence around selection
  const selectedText = view.state.sliceDoc(fromLine.from, toLine.to);
  const replacement = `\`\`\`\n${selectedText}\n\`\`\``;
  view.dispatch({
    changes: { from: fromLine.from, to: toLine.to, insert: replacement },
  });
  return true;
}

export function insertLinkAtCursor(): boolean {
  const view = getEditorView();
  if (!view) return false;
  insertLink();
  return true;
}
