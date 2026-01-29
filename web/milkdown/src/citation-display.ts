// Citation Display NodeView for Milkdown
// Renders formatted citations with click-to-edit functionality
// Uses citeproc for formatting when available

import { Ctx } from '@milkdown/kit/ctx';
import { $view } from '@milkdown/kit/utils';
import { citationNode, CitationAttrs, serializeCitation } from './citation-plugin';
import { getCiteprocEngine, CSLItem } from './citeproc-engine';

// Re-export for external use
export type { CSLItem };

// Citation NodeView with formatted display and click-to-edit
export const citationNodeView = $view(citationNode, () => (ctx: Ctx) => {
  return (node, view, getPos) => {
    const attrs = node.attrs as CitationAttrs;
    const citekeys = attrs.citekeys.split(',').filter(k => k.trim());

    // State
    let isEditMode = false;

    // Create DOM structure
    const dom = document.createElement('span');
    dom.className = 'ff-citation';

    // Update display content
    const updateDisplay = () => {
      if (isEditMode) {
        return; // Don't update while editing
      }

      const engine = getCiteprocEngine();
      let displayText = '';
      let isResolved = true;
      let tooltipText = '';

      if (citekeys.length === 0) {
        displayText = '[?]';
        isResolved = false;
        tooltipText = 'No citation key';
      } else {
        // Check resolution status
        const unresolvedKeys = citekeys.filter(k => !engine.hasItem(k));
        isResolved = unresolvedKeys.length === 0;

        if (isResolved) {
          // Get formatted citation from citeproc
          try {
            displayText = engine.formatCitation(citekeys, {
              suppressAuthor: attrs.suppressAuthor,
              locator: attrs.locators ? JSON.parse(attrs.locators)[0] : undefined,
              prefix: attrs.prefix,
              suffix: attrs.suffix,
            });

            // Build tooltip with full citation info
            const items = citekeys.map(k => engine.getItem(k)).filter(Boolean) as CSLItem[];
            tooltipText = items.map(item => {
              const author = item.author?.[0];
              const authorName = author?.family || author?.literal || '';
              const year = item.issued?.['date-parts']?.[0]?.[0] || 'n.d.';
              const title = item.title || '';
              return `${authorName} (${year}). ${title}`;
            }).join('\n');
          } catch (e) {
            // Fallback to short citation
            displayText = `(${citekeys.map(k => engine.getShortCitation(k)).join('; ')})`;
            tooltipText = displayText;
          }
        } else {
          // Show unresolved with ? suffix
          displayText = `(${citekeys.map(k => {
            if (engine.hasItem(k)) {
              return engine.getShortCitation(k);
            }
            return `${k}?`;
          }).join('; ')})`;
          tooltipText = `Unresolved: ${unresolvedKeys.join(', ')}`;
        }
      }

      // Update DOM
      dom.textContent = displayText;
      dom.title = tooltipText;
      dom.className = `ff-citation ${isResolved ? 'ff-citation-resolved' : 'ff-citation-unresolved'}`;
      dom.dataset.citekeys = attrs.citekeys;
      dom.dataset.rawsyntax = attrs.rawSyntax;
    };

    // Enter edit mode
    const enterEditMode = () => {
      if (isEditMode) return;
      isEditMode = true;

      // Show raw syntax
      const rawSyntax = attrs.rawSyntax || serializeCitation(attrs);
      dom.textContent = rawSyntax;
      dom.className = 'ff-citation ff-citation-editing';
      dom.contentEditable = 'true';
      dom.focus();

      // Select all text
      const range = document.createRange();
      range.selectNodeContents(dom);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
    };

    // Exit edit mode and parse changes
    const exitEditMode = () => {
      if (!isEditMode) return;
      isEditMode = false;
      dom.contentEditable = 'false';

      const newText = dom.textContent || '';

      // Parse the edited text
      const parsed = parseEditedCitation(newText);
      if (parsed && parsed.citekeys.length > 0) {
        // Update node with new attributes
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos !== null && pos !== undefined) {
          const tr = view.state.tr.setNodeMarkup(pos, undefined, {
            citekeys: parsed.citekeys.join(','),
            locators: JSON.stringify(parsed.locators),
            prefix: parsed.prefix,
            suffix: parsed.suffix,
            suppressAuthor: parsed.suppressAuthor,
            rawSyntax: newText.trim(),
          });
          view.dispatch(tr);
        }
      }

      updateDisplay();
    };

    // Click handler
    dom.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();

      if (!isEditMode) {
        enterEditMode();
      }
    });

    // Blur handler
    dom.addEventListener('blur', () => {
      exitEditMode();
    });

    // Keyboard handler
    dom.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        dom.blur();
      }
    });

    // Initial render
    updateDisplay();

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'citation') return false;

        // Update attrs from node
        const newAttrs = updatedNode.attrs as CitationAttrs;
        Object.assign(attrs, newAttrs);

        // Refresh display
        updateDisplay();
        return true;
      },
      destroy: () => {
        // Cleanup if needed
      },
      // Prevent ProseMirror from handling selection inside
      stopEvent: (event: Event) => {
        if (isEditMode) {
          return true; // Let us handle events in edit mode
        }
        return false;
      },
      // Ignore selection changes while editing
      ignoreMutation: (mutation: MutationRecord) => {
        return isEditMode;
      },
    };
  };
});

// Parse edited citation text back to structured data
function parseEditedCitation(text: string): {
  citekeys: string[];
  locators: string[];
  prefix: string;
  suffix: string;
  suppressAuthor: boolean;
} | null {
  const trimmed = text.trim();

  // Must be bracketed
  if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
    return null;
  }

  const inner = trimmed.slice(1, -1);
  if (!inner.includes('@')) {
    return null;
  }

  const citekeys: string[] = [];
  const locators: string[] = [];
  let prefix = '';
  let suffix = '';
  let suppressAuthor = false;

  // Split by semicolon for multiple citations
  const parts = inner.split(';').map(p => p.trim());

  for (const part of parts) {
    // Check for prefix before @
    const atIndex = part.indexOf('@');
    if (atIndex > 0) {
      const beforeAt = part.slice(0, atIndex).trim();
      if (beforeAt !== '-') {
        if (citekeys.length === 0) {
          prefix = beforeAt;
        }
      }
    }

    // Extract citekey and locator
    const match = part.match(/(-?)@([\w:.-]+)(?:,\s*(.+))?/);
    if (match) {
      const [, suppress, citekey, locator] = match;
      if (suppress === '-') {
        suppressAuthor = true;
      }
      citekeys.push(citekey);
      locators.push(locator?.trim() || '');
    }
  }

  if (citekeys.length === 0) {
    return null;
  }

  return { citekeys, locators, prefix, suffix, suppressAuthor };
}

// Export plugin array
export const citationDisplayPlugin = [citationNodeView].flat();
