import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import {
  addColumnAfter,
  addColumnBefore,
  addRowAfter,
  addRowBefore,
  deleteColumn,
  deleteRow,
  isInTable,
  selectedRect,
} from 'prosemirror-tables';

const tableToolbarKey = new PluginKey('table-toolbar');

interface TableInfo {
  colCount: number;
  dataRowCount: number;
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
    const colIndex = rect.left;
    const headerCellOffset = map.map[colIndex];
    const cellPos = rect.tableStart + headerCellOffset;
    const cellNode = state.doc.nodeAt(cellPos);
    const currentAlign = (cellNode?.attrs?.align as string | null) ?? null;
    const tableStartPos = rect.tableStart - 1;
    const coords = view.coordsAtPos(tableStartPos + 1);
    return { colCount, dataRowCount, currentAlign, top: coords.top, left: coords.left };
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
    view.dispatch(
      state.tr.setNodeMarkup(cellPos, undefined, { ...cellNode.attrs, align })
    );
  } catch {
    // not in table
  }
}

function createToolbar(): HTMLElement {
  const toolbar = document.createElement('div');
  toolbar.className = 'table-toolbar';
  toolbar.setAttribute('data-show', 'false');

  const mkBtn = (ariaLabel: string, text: string): HTMLButtonElement => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'table-toolbar-btn';
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

  document.body.appendChild(toolbar);
  return toolbar;
}

export const tableToolsPlugin = $prose(() => {
  let toolbar: HTMLElement | null = null;
  let currentView: EditorView | null = null;

  const btn = (label: string): HTMLButtonElement =>
    toolbar!.querySelector(`[aria-label="${label}"]`) as HTMLButtonElement;

  return new Plugin({
    key: tableToolbarKey,
    view(editorView) {
      toolbar = createToolbar();
      currentView = editorView;

      toolbar.addEventListener('mousedown', (e) => e.preventDefault());

      btn('Add row above').addEventListener('click', () => {
        if (!currentView) return;
        addRowBefore(currentView.state, currentView.dispatch);
        currentView.focus();
      });
      btn('Add row below').addEventListener('click', () => {
        if (!currentView) return;
        addRowAfter(currentView.state, currentView.dispatch);
        currentView.focus();
      });
      btn('Add column left').addEventListener('click', () => {
        if (!currentView) return;
        addColumnBefore(currentView.state, currentView.dispatch);
        currentView.focus();
      });
      btn('Add column right').addEventListener('click', () => {
        if (!currentView) return;
        addColumnAfter(currentView.state, currentView.dispatch);
        currentView.focus();
      });
      btn('Delete row').addEventListener('click', () => {
        if (!currentView) return;
        deleteRow(currentView.state, currentView.dispatch);
        currentView.focus();
      });
      btn('Delete column').addEventListener('click', () => {
        if (!currentView) return;
        deleteColumn(currentView.state, currentView.dispatch);
        currentView.focus();
      });

      const alignSel = toolbar!.querySelector('.table-toolbar-align') as HTMLSelectElement;
      alignSel.addEventListener('change', () => {
        if (!currentView) return;
        setColumnAlign(currentView, alignSel.value || null);
        currentView.focus();
      });

      return {
        update(view: EditorView) {
          currentView = view;
          const info = getTableInfo(view);
          if (!info) {
            toolbar!.setAttribute('data-show', 'false');
            return;
          }
          (btn('Delete row') as HTMLButtonElement).disabled = info.dataRowCount <= 1;
          (btn('Delete column') as HTMLButtonElement).disabled = info.colCount <= 1;
          const alignSel = toolbar!.querySelector('.table-toolbar-align') as HTMLSelectElement;
          alignSel.value = info.currentAlign ?? '';
          toolbar!.style.left = `${info.left}px`;
          toolbar!.style.top = `${Math.max(0, info.top - 44)}px`;
          toolbar!.setAttribute('data-show', 'true');
        },
        destroy() {
          toolbar?.remove();
          toolbar = null;
        },
      };
    },
  });
});
