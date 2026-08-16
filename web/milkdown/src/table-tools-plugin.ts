import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import {
  addColumnAfter,
  addColumnBefore,
  addRowAfter,
  addRowBefore,
  CellSelection,
  deleteColumn,
  deleteRow,
  deleteTable,
  isInTable,
  selectedRect,
} from 'prosemirror-tables';

const tableToolbarKey = new PluginKey('table-toolbar');

interface TableInfo {
  colCount: number;
  dataRowCount: number;
  inHeaderRow: boolean;
  currentAlign: string | null;
  top: number;
  left: number;
}

function getTableInfo(view: EditorView): TableInfo | null {
  const { state } = view;
  if (!isInTable(state)) return null;
  try {
    const rect = selectedRect(state);
    if (!rect) return null;
    const { map } = rect;
    const colCount = map.width;
    const dataRowCount = map.height - 1;
    const inHeaderRow = rect.top === 0;
    const colIndex = rect.left;
    const headerCellOffset = map.map[colIndex];
    const cellPos = rect.tableStart + headerCellOffset;
    const cellNode = state.doc.nodeAt(cellPos);
    const currentAlign = (cellNode?.attrs?.align as string | null) ?? null;
    const tableStartPos = rect.tableStart - 1;
    const coords = view.coordsAtPos(tableStartPos + 1);
    return { colCount, dataRowCount, inHeaderRow, currentAlign, top: coords.top, left: coords.left };
  } catch {
    return null;
  }
}

function setColumnAlign(view: EditorView, align: string | null): void {
  const { state } = view;
  try {
    const rect = selectedRect(state);
    if (!rect) return;
    const cellOffset = rect.map.map[rect.left];
    const cellPos = rect.tableStart + cellOffset;
    const cellNode = state.doc.nodeAt(cellPos);
    if (!cellNode) return;
    view.dispatch(state.tr.setNodeMarkup(cellPos, undefined, { ...cellNode.attrs, align }));
  } catch {
    // not in table
  }
}

function createToolbar(): HTMLElement {
  const toolbar = document.createElement('div');
  toolbar.className = 'table-toolbar';
  toolbar.setAttribute('data-show', 'false');

  const mkBtn = (ariaLabel: string, text: string, extraClass?: string): HTMLButtonElement => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = extraClass ? `table-toolbar-btn ${extraClass}` : 'table-toolbar-btn';
    btn.setAttribute('aria-label', ariaLabel);
    btn.title = ariaLabel;
    btn.textContent = text;
    return btn;
  };

  toolbar.appendChild(mkBtn('Add row above', '↑+'));
  toolbar.appendChild(mkBtn('Add row below', '↓+'));
  toolbar.appendChild(mkBtn('Add column left', '+←'));
  toolbar.appendChild(mkBtn('Add column right', '+→'));
  toolbar.appendChild(mkBtn('Delete row', '×row'));
  toolbar.appendChild(mkBtn('Delete column', '×col'));

  const sep = document.createElement('div');
  sep.className = 'table-toolbar-sep';
  toolbar.appendChild(sep);

  const sel = document.createElement('select');
  sel.className = 'table-toolbar-align';
  sel.setAttribute('aria-label', 'Column alignment');
  sel.title = 'Column alignment';
  for (const [value, label] of [
    ['', 'No alignment'],
    ['left', 'Align left'],
    ['center', 'Align center'],
    ['right', 'Align right'],
  ] as [string, string][]) {
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = label;
    sel.appendChild(opt);
  }
  toolbar.appendChild(sel);

  // Divider + delete-table button go LAST, after the alignment dropdown —
  // deliberately far from ×row/×col so an accidental click near those
  // frequently-used buttons can't nuke the whole table.
  const deleteSep = document.createElement('div');
  deleteSep.className = 'table-toolbar-sep';
  toolbar.appendChild(deleteSep);
  toolbar.appendChild(mkBtn('Delete table', '×table', 'is-danger'));

  document.body.appendChild(toolbar);
  return toolbar;
}

// Collapses a multi-cell CellSelection to a single cell at sel.head before any
// toolbar command fires. Toolbar buttons act on "the cell under the cursor" —
// not on whatever stray selection the user happened to leave active.
// Skips if the selection is already a TextSelection (no multi-cell span possible).
function narrowToHeadCell(view: EditorView): void {
  const sel = view.state.selection;
  // Only CellSelections can span multiple cells. TextSelections are always
  // contained within one cell, so no narrowing is needed.
  if (!(sel instanceof CellSelection)) return;
  // Already a single-cell selection — anchor and head are the same cell.
  if (sel.$anchorCell.pos === sel.$headCell.pos) return;
  // Walk up from sel.head to find the enclosing table_cell or table_header node.
  const $head = view.state.doc.resolve(sel.head);
  let cellPos: number | null = null;
  for (let d = $head.depth; d > 0; d--) {
    const nodeName = $head.node(d).type.name;
    if (nodeName === 'table_cell' || nodeName === 'table_header') {
      cellPos = $head.before(d);
      break;
    }
  }
  if (cellPos === null) return;
  try {
    const $cell = view.state.doc.resolve(cellPos);
    const cellSel = CellSelection.create(view.state.doc, $cell.pos);
    const tr = view.state.tr.setSelection(cellSel);
    tr.setMeta('addToHistory', false);
    view.dispatch(tr);
  } catch {
    // Degenerate table state — leave selection as-is.
  }
}

// Routes through the errorHandler bridge so logs appear in Xcode/xclog under
// the .editor DebugLog category (type='debug'). Falls back to console.log when
// the bridge isn't present (e.g., outside WKWebView).
const log = (...args: unknown[]) => {
  const msg =
    '[table-tools] ' +
    args
      .map((a) => {
        if (typeof a === 'string') return a;
        try {
          return JSON.stringify(a);
        } catch {
          return String(a);
        }
      })
      .join(' ');
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.errorHandler;
  if (handler?.postMessage) handler.postMessage({ type: 'debug', message: msg });
  else console.log(msg);
};

export const tableToolsPlugin = $prose(() => {
  let toolbar: HTMLElement | null = null;
  let currentView: EditorView | null = null;

  const btn = (label: string): HTMLButtonElement =>
    toolbar!.querySelector(`[aria-label="${label}"]`) as HTMLButtonElement;

  const wireBtn = (
    label: string,
    cmd: (
      state: EditorView['state'],
      dispatch: (tr: ReturnType<EditorView['state']['tr']['setMeta']> extends infer T ? T : never) => void
    ) => boolean
  ) => {
    const button = btn(label);
    log('wireBtn: binding', label, 'button found?', !!button);
    button.addEventListener('mousedown', (e) => {
      log(`mousedown on button: ${label}`);
      e.preventDefault();
    });
    button.addEventListener('click', () => {
      log(`click: ${label}`);
      if (!currentView) {
        log('  no currentView — abort');
        return;
      }
      const sel = currentView.state.selection;
      const isIn = isInTable(currentView.state);
      log('  selection', { from: sel.from, to: sel.to, empty: sel.empty });
      log('  isInTable', isIn);
      if (isIn) narrowToHeadCell(currentView);
      let dispatched = false;
      try {
        const result = (cmd as unknown as (s: typeof currentView.state, d: (tr: unknown) => void) => boolean)(
          currentView.state,
          (tr) => {
            dispatched = true;
            const t = tr as { steps: unknown[]; docChanged: boolean };
            log(`  dispatch called: tr.steps.length=${t.steps.length} docChanged=${t.docChanged}`);
            currentView!.dispatch(tr as Parameters<EditorView['dispatch']>[0]);
          }
        );
        log(`  cmd returned ${result}, dispatched=${dispatched}`);
      } catch (e) {
        const err = e as Error;
        log(`  cmd THREW: ${err?.name}: ${err?.message}`);
        log(`  stack: ${err?.stack?.split('\n').slice(0, 5).join(' | ')}`);
      }
      currentView.focus();
    });
  };

  return new Plugin({
    key: tableToolbarKey,
    view(editorView) {
      toolbar = createToolbar();
      currentView = editorView;
      log('view() called, toolbar created, in document.body?', toolbar.parentElement === document.body);

      toolbar.addEventListener('mousedown', (e) => {
        const t = e.target as HTMLElement;
        log('toolbar mousedown', { tag: t?.tagName, ariaLabel: t?.getAttribute?.('aria-label') });
        e.preventDefault();
      });

      wireBtn('Add row above', addRowBefore as never);
      wireBtn('Add row below', addRowAfter as never);
      wireBtn('Add column left', addColumnBefore as never);
      wireBtn('Add column right', addColumnAfter as never);
      wireBtn('Delete row', deleteRow as never);
      wireBtn('Delete column', deleteColumn as never);
      wireBtn('Delete table', deleteTable as never);

      const alignSel = toolbar!.querySelector('.table-toolbar-align') as HTMLSelectElement;
      alignSel.addEventListener('mousedown', (e) => {
        log('align mousedown');
        e.stopPropagation(); // don't let toolbar's preventDefault swallow the dropdown
      });
      alignSel.addEventListener('change', () => {
        log('align change:', alignSel.value);
        if (!currentView) return;
        setColumnAlign(currentView, alignSel.value || null);
        currentView.focus();
      });

      return {
        update(view: EditorView) {
          currentView = view;
          const info = getTableInfo(view);
          if (!info) {
            if (toolbar!.getAttribute('data-show') === 'true') log('update: hiding (no info)');
            toolbar!.setAttribute('data-show', 'false');
            return;
          }
          (btn('Add row above') as HTMLButtonElement).disabled = info.inHeaderRow;
          (btn('Delete row') as HTMLButtonElement).disabled = info.dataRowCount <= 1 || info.inHeaderRow;
          (btn('Delete column') as HTMLButtonElement).disabled = info.colCount <= 1;
          const alignSel = toolbar!.querySelector('.table-toolbar-align') as HTMLSelectElement;
          alignSel.value = info.currentAlign ?? '';
          const wasShown = toolbar!.getAttribute('data-show') === 'true';
          // Flip data-show BEFORE measuring offsetWidth: the toolbar is
          // display:none until this attribute is "true" (see styles.css),
          // and a hidden element always reports 0 for offsetWidth — clamping
          // against that would pin the toolbar to the left margin every time.
          toolbar!.setAttribute('data-show', 'true');
          // Clamp horizontally so the toolbar (and the far-right "Delete
          // table" button in particular) can't overflow past either edge of
          // the viewport — e.g. a table near the right edge with the
          // Annotations panel open narrowing the WebView.
          const margin = 8;
          const maxLeft = Math.max(margin, document.documentElement.clientWidth - toolbar!.offsetWidth - margin);
          const clampedLeft = Math.min(Math.max(margin, info.left), maxLeft);
          toolbar!.style.left = `${clampedLeft}px`;
          toolbar!.style.top = `${Math.max(0, info.top - 44)}px`;
          if (!wasShown) {
            log('update: showing', `cols=${info.colCount} rows=${info.dataRowCount} align=${info.currentAlign}`);
          }
        },
        destroy() {
          toolbar?.remove();
          toolbar = null;
        },
      };
    },
  });
});
