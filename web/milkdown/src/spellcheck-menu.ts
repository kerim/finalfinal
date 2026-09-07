/**
 * Spellcheck context menu for Milkdown editor
 * Shows suggestions, learn, and ignore options for flagged words
 */

export interface SpellcheckMenuOptions {
  x: number;
  y: number;
  word: string;
  type: 'spelling' | 'grammar';
  suggestions: string[];
  message?: string | null;
  onReplace: (replacement: string) => void;
  onLearn: (word: string) => void;
  onIgnore: (word: string) => void;
}

let activeMenu: HTMLElement | null = null;

export function dismissMenu() {
  if (activeMenu) {
    activeMenu.remove();
    activeMenu = null;
  }
  document.removeEventListener('click', handleOutsideClick);
  document.removeEventListener('keydown', handleEscape);
  document.removeEventListener('scroll', dismissMenu, true);
}

function handleOutsideClick(e: MouseEvent) {
  if (activeMenu && !activeMenu.contains(e.target as Node)) {
    dismissMenu();
  }
}

function handleEscape(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    dismissMenu();
  }
}

export function showSpellcheckMenu(options: SpellcheckMenuOptions): void {
  dismissMenu();

  const menu = document.createElement('div');
  menu.className = 'spellcheck-menu';
  menu.style.left = `${options.x}px`;
  menu.style.top = `${options.y}px`;

  // Grammar: show explanation message
  if (options.type === 'grammar' && options.message) {
    const msgEl = document.createElement('div');
    msgEl.className = 'spellcheck-menu-message';
    msgEl.textContent = options.message;
    menu.appendChild(msgEl);
  }

  // Suggestions (up to 5)
  const suggestions = options.suggestions.slice(0, 5);
  if (suggestions.length > 0) {
    suggestions.forEach((suggestion, i) => {
      const item = document.createElement('div');
      item.className = 'spellcheck-menu-item spellcheck-menu-suggestion';
      if (i === 0) item.classList.add('spellcheck-menu-primary');
      item.textContent = suggestion;
      item.addEventListener('click', (e) => {
        e.stopPropagation();
        options.onReplace(suggestion);
        dismissMenu();
      });
      // Also handle ctrl+click (macOS right-click), which fires contextmenu instead of click
      item.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        options.onReplace(suggestion);
        dismissMenu();
      });
      item.addEventListener('mousedown', (e) => {
        // mousedown fires for both regular and ctrl+clicks
        if (e.button === 0) {
          e.stopPropagation();
        }
      });
      menu.appendChild(item);
    });

    // Separator
    const sep = document.createElement('div');
    sep.className = 'spellcheck-menu-separator';
    menu.appendChild(sep);
  }

  // Learn Spelling (spelling errors only)
  if (options.type === 'spelling') {
    const learnItem = document.createElement('div');
    learnItem.className = 'spellcheck-menu-item';
    learnItem.textContent = 'Learn Spelling';
    learnItem.addEventListener('click', (e) => {
      e.stopPropagation();
      options.onLearn(options.word);
      dismissMenu();
    });
    learnItem.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      e.stopPropagation();
      options.onLearn(options.word);
      dismissMenu();
    });
    menu.appendChild(learnItem);
  }

  // Ignore
  const ignoreItem = document.createElement('div');
  ignoreItem.className = 'spellcheck-menu-item';
  ignoreItem.textContent = 'Ignore';
  ignoreItem.addEventListener('click', (e) => {
    e.stopPropagation();
    options.onIgnore(options.word);
    dismissMenu();
  });
  ignoreItem.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    e.stopPropagation();
    options.onIgnore(options.word);
    dismissMenu();
  });
  menu.appendChild(ignoreItem);

  document.body.appendChild(menu);
  activeMenu = menu;

  // Ensure menu is within viewport
  const rect = menu.getBoundingClientRect();
  if (rect.right > window.innerWidth) {
    menu.style.left = `${window.innerWidth - rect.width - 8}px`;
  }
  if (rect.bottom > window.innerHeight) {
    menu.style.top = `${options.y - rect.height}px`;
  }

  // Dismiss handlers — 150ms delay ensures all events from the ctrl+click
  // release (mouseup, click) have fired before we start listening for outside clicks.
  // requestAnimationFrame (~16ms) was too short and the release click would dismiss the menu.
  setTimeout(() => {
    document.addEventListener('click', handleOutsideClick);
    document.addEventListener('keydown', handleEscape);
    document.addEventListener('scroll', dismissMenu, true);
  }, 150);
}
