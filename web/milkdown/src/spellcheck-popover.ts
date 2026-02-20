/**
 * Proofing popover for grammar/style errors in Milkdown editor.
 * Shows rule info, suggestions, ignore, and disable rule options.
 * Triggered on click (not right-click) of grammar/style decorations.
 */

export interface PopoverOptions {
  x: number;
  y: number;
  word: string;
  type: string;
  message: string;
  shortMessage: string;
  ruleId: string;
  isPicky: boolean;
  suggestions: string[];
  onReplace: (suggestion: string) => void;
  onIgnore: () => void;
  onDisableRule: (ruleId: string) => void;
}

let activePopover: HTMLElement | null = null;

export function showProofingPopover(options: PopoverOptions): void {
  dismissPopover();

  const popover = document.createElement('div');
  popover.className = 'proofing-popover';

  // Header: rule name + disable button
  const header = document.createElement('div');
  header.className = 'proofing-popover-header';

  const ruleName = document.createElement('span');
  ruleName.className = 'proofing-popover-rule';
  const title = options.shortMessage || (options.message ? options.message.split('.')[0] : options.type);
  ruleName.textContent = title;
  header.appendChild(ruleName);

  if (options.ruleId) {
    const disableBtn = document.createElement('button');
    disableBtn.className = 'proofing-popover-disable';
    disableBtn.title = 'Disable this rule';
    disableBtn.textContent = '\u2298'; // ⊘ character
    disableBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      options.onDisableRule(options.ruleId);
      dismissPopover();
    });
    header.appendChild(disableBtn);
  }
  popover.appendChild(header);

  // Message (only show if it differs from the title)
  if (options.message && options.message !== title) {
    const msg = document.createElement('div');
    msg.className = 'proofing-popover-message';
    msg.textContent = options.message;
    popover.appendChild(msg);
  }

  // Suggestions + Ignore row
  const actions = document.createElement('div');
  actions.className = 'proofing-popover-actions';

  for (const suggestion of options.suggestions.slice(0, 3)) {
    const btn = document.createElement('button');
    btn.className = 'proofing-popover-suggestion';
    btn.textContent = suggestion;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      options.onReplace(suggestion);
      dismissPopover();
    });
    actions.appendChild(btn);
  }

  const ignoreBtn = document.createElement('button');
  ignoreBtn.className = 'proofing-popover-ignore';
  ignoreBtn.textContent = 'Ignore';
  ignoreBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    options.onIgnore();
    dismissPopover();
  });
  actions.appendChild(ignoreBtn);

  popover.appendChild(actions);

  // Picky label
  if (options.isPicky) {
    const footer = document.createElement('div');
    footer.className = 'proofing-popover-footer';
    const pickyLabel = document.createElement('span');
    pickyLabel.className = 'proofing-popover-picky';
    pickyLabel.textContent = 'Picky Suggestion';
    footer.appendChild(pickyLabel);
    popover.appendChild(footer);
  }

  // Position and show
  popover.style.left = `${options.x}px`;
  popover.style.top = `${options.y}px`;
  document.body.appendChild(popover);
  activePopover = popover;

  // Ensure popover is within viewport
  const rect = popover.getBoundingClientRect();
  if (rect.right > window.innerWidth) {
    popover.style.left = `${window.innerWidth - rect.width - 8}px`;
  }
  if (rect.bottom > window.innerHeight) {
    popover.style.top = `${options.y - rect.height}px`;
  }

  // Dismiss on click outside (delayed to avoid immediate dismiss)
  setTimeout(() => {
    document.addEventListener('click', handleOutsideClick);
    document.addEventListener('keydown', handleEscape);
  }, 150);
}

export function dismissPopover(): void {
  if (activePopover) {
    activePopover.remove();
    activePopover = null;
    document.removeEventListener('click', handleOutsideClick);
    document.removeEventListener('keydown', handleEscape);
  }
}

function handleOutsideClick(e: MouseEvent): void {
  if (activePopover && !activePopover.contains(e.target as Node)) {
    dismissPopover();
  }
}

function handleEscape(e: KeyboardEvent): void {
  if (e.key === 'Escape') {
    dismissPopover();
  }
}
