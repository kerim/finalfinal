// Selection Toolbar - Shared floating format bar for both editors
// Appears near text selections with formatting buttons

import './selection-toolbar.css';

export interface SelectionRect {
  top: number;
  left: number;
  right: number;
  bottom: number;
  width: number;
}

export interface ActiveFormats {
  bold?: boolean;
  italic?: boolean;
  strikethrough?: boolean;
  highlight?: boolean;
  heading?: number; // 0 = paragraph, 1-6 = heading level
  bulletList?: boolean;
  numberList?: boolean;
  blockquote?: boolean;
  codeBlock?: boolean;
}

let toolbarEl: HTMLElement | null = null;
let headingMenuEl: HTMLElement | null = null;
let isVisible = false;
let hideTimeout: ReturnType<typeof setTimeout> | null = null;

function createToolbar(): HTMLElement {
  const toolbar = document.createElement('div');
  toolbar.className = 'selection-toolbar';
  toolbar.setAttribute('role', 'toolbar');
  toolbar.setAttribute('aria-label', 'Text formatting');

  // Inline formatting buttons
  const buttons = [
    { command: 'bold', label: 'B', title: 'Bold (⌘B)' },
    { command: 'italic', label: 'I', title: 'Italic (⌘I)' },
    { command: 'strikethrough', label: 'S', title: 'Strikethrough' },
    { command: 'highlight', label: '≡', title: 'Highlight (⌘⇧H)' },
  ];

  for (const btn of buttons) {
    const el = document.createElement('button');
    el.className = 'selection-toolbar-btn';
    el.dataset.command = btn.command;
    el.textContent = btn.label;
    el.title = btn.title;
    el.setAttribute('aria-label', btn.title);
    toolbar.appendChild(el);
  }

  // Link button (after inline formatting, before separator)
  const linkSep = document.createElement('div');
  linkSep.className = 'selection-toolbar-separator';
  toolbar.appendChild(linkSep);

  const linkBtn = document.createElement('button');
  linkBtn.className = 'selection-toolbar-btn';
  linkBtn.dataset.command = 'link';
  linkBtn.title = 'Link (⌘K)';
  linkBtn.setAttribute('aria-label', 'Link (⌘K)');

  // SVG chain-link icon (Feather Icons "link" path) — uses currentColor to match toolbar text
  const svgNS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(svgNS, 'svg');
  svg.setAttribute('width', '14');
  svg.setAttribute('height', '14');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  const path1 = document.createElementNS(svgNS, 'path');
  path1.setAttribute('d', 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71');
  const path2 = document.createElementNS(svgNS, 'path');
  path2.setAttribute('d', 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71');
  svg.appendChild(path1);
  svg.appendChild(path2);
  linkBtn.appendChild(svg);

  toolbar.appendChild(linkBtn);

  // Separator
  const sep1 = document.createElement('div');
  sep1.className = 'selection-toolbar-separator';
  toolbar.appendChild(sep1);

  // Heading dropdown wrapper
  const headingWrapper = document.createElement('div');
  headingWrapper.className = 'selection-toolbar-heading-wrapper';
  const headingBtn = document.createElement('button');
  headingBtn.className = 'selection-toolbar-btn';
  headingBtn.dataset.command = 'heading';
  headingBtn.textContent = 'H▾';
  headingBtn.title = 'Heading level';
  headingBtn.setAttribute('aria-label', 'Heading level');
  headingWrapper.appendChild(headingBtn);
  toolbar.appendChild(headingWrapper);

  // Block formatting buttons
  const blockButtons = [
    { command: 'bulletList', label: '•', title: 'Bullet list' },
    { command: 'numberList', label: '1.', title: 'Numbered list' },
    { command: 'blockquote', label: '❝', title: 'Blockquote' },
    { command: 'codeBlock', label: '</>', title: 'Code block' },
  ];

  for (const btn of blockButtons) {
    const el = document.createElement('button');
    el.className = 'selection-toolbar-btn';
    el.dataset.command = btn.command;
    el.textContent = btn.label;
    el.title = btn.title;
    el.setAttribute('aria-label', btn.title);
    toolbar.appendChild(el);
  }

  // Event handling - prevent selection loss on button clicks
  toolbar.addEventListener('mousedown', (e) => {
    e.preventDefault(); // Prevents selection from collapsing
    const button = (e.target as HTMLElement).closest('.selection-toolbar-btn') as HTMLElement | null;
    if (!button) return;

    const command = button.dataset.command;
    if (!command) return;

    if (command === 'heading') {
      toggleHeadingMenu(headingWrapper);
      return;
    }

    executeCommand(command);
  });

  document.body.appendChild(toolbar);
  return toolbar;
}

function createHeadingMenu(): HTMLElement {
  const menu = document.createElement('div');
  menu.className = 'selection-toolbar-heading-menu';

  const items = [
    { level: 1, label: 'Heading 1' },
    { level: 2, label: 'Heading 2' },
    { level: 3, label: 'Heading 3' },
    { level: 4, label: 'Heading 4' },
    { level: 5, label: 'Heading 5' },
    { level: 6, label: 'Heading 6' },
    { level: 0, label: 'Paragraph' },
  ];

  for (const item of items) {
    const el = document.createElement('div');
    el.className = 'selection-toolbar-heading-item';
    el.dataset.level = String(item.level);

    const check = document.createElement('span');
    check.className = 'check';
    el.appendChild(check);

    const label = document.createElement('span');
    label.textContent = item.label;
    el.appendChild(label);

    menu.appendChild(el);
  }

  menu.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const item = (e.target as HTMLElement).closest('.selection-toolbar-heading-item') as HTMLElement | null;
    if (!item) return;
    const level = parseInt(item.dataset.level || '0', 10);
    window.FinalFinal.setHeading(level);
    hideHeadingMenu();
  });

  return menu;
}

function toggleHeadingMenu(wrapper: HTMLElement) {
  if (headingMenuEl?.parentElement) {
    hideHeadingMenu();
    return;
  }

  headingMenuEl = createHeadingMenu();
  updateHeadingMenuActiveState();
  wrapper.appendChild(headingMenuEl);
}

function hideHeadingMenu() {
  if (headingMenuEl?.parentElement) {
    headingMenuEl.parentElement.removeChild(headingMenuEl);
  }
  headingMenuEl = null;
}

function updateHeadingMenuActiveState() {
  if (!headingMenuEl) return;
  const items = headingMenuEl.querySelectorAll('.selection-toolbar-heading-item');
  const currentLevel = currentFormats.heading ?? 0;

  items.forEach((item) => {
    const el = item as HTMLElement;
    const level = parseInt(el.dataset.level || '0', 10);
    const isActive = level === currentLevel;
    el.classList.toggle('active', isActive);
    const check = el.querySelector('.check');
    if (check) {
      check.textContent = isActive ? '✓' : '';
    }
  });
}

function executeCommand(command: string) {
  const ff = window.FinalFinal;
  switch (command) {
    case 'bold':
      ff.toggleBold();
      break;
    case 'italic':
      ff.toggleItalic();
      break;
    case 'strikethrough':
      ff.toggleStrikethrough();
      break;
    case 'highlight':
      ff.toggleHighlight();
      break;
    case 'bulletList':
      ff.toggleBulletList();
      break;
    case 'numberList':
      ff.toggleNumberList();
      break;
    case 'blockquote':
      ff.toggleBlockquote();
      break;
    case 'codeBlock':
      ff.toggleCodeBlock();
      break;
    case 'link':
      ff.insertLink();
      break;
  }
}

let currentFormats: ActiveFormats = {};

function updateActiveStates(formats: ActiveFormats) {
  currentFormats = formats;
  if (!toolbarEl) return;

  const buttons = toolbarEl.querySelectorAll('.selection-toolbar-btn');
  buttons.forEach((btn) => {
    const el = btn as HTMLElement;
    const cmd = el.dataset.command;
    if (!cmd) return;

    let active = false;
    switch (cmd) {
      case 'bold':
        active = !!formats.bold;
        break;
      case 'italic':
        active = !!formats.italic;
        break;
      case 'strikethrough':
        active = !!formats.strikethrough;
        break;
      case 'highlight':
        active = !!formats.highlight;
        break;
      case 'heading':
        active = (formats.heading ?? 0) > 0;
        // Update button text to show current level
        el.textContent = active ? `H${formats.heading}` : 'H▾';
        break;
      case 'bulletList':
        active = !!formats.bulletList;
        break;
      case 'numberList':
        active = !!formats.numberList;
        break;
      case 'blockquote':
        active = !!formats.blockquote;
        break;
      case 'codeBlock':
        active = !!formats.codeBlock;
        break;
    }

    el.classList.toggle('active', active);
  });

  updateHeadingMenuActiveState();
}

export function showToolbar(rect: SelectionRect, formats: ActiveFormats) {
  if (!toolbarEl) {
    toolbarEl = createToolbar();
  }

  if (hideTimeout) {
    clearTimeout(hideTimeout);
    hideTimeout = null;
  }

  updateActiveStates(formats);

  // Position: above the selection, centered horizontally
  const toolbarWidth = toolbarEl.offsetWidth || 300;
  const toolbarHeight = toolbarEl.offsetHeight || 34;
  const margin = 8;

  let top = rect.top - toolbarHeight - margin;
  let isBelow = false;

  // If near top of viewport, show below instead
  if (top < margin) {
    top = rect.bottom + margin;
    isBelow = true;
  }

  // Center horizontally on selection
  let left = rect.left + rect.width / 2 - toolbarWidth / 2;

  // Clamp to viewport
  const maxLeft = window.innerWidth - toolbarWidth - margin;
  left = Math.max(margin, Math.min(left, maxLeft));

  // Calculate arrow position
  const selectionCenter = rect.left + rect.width / 2;
  const arrowLeft = selectionCenter - left;
  toolbarEl.style.setProperty('--arrow-left', `${arrowLeft}px`);

  toolbarEl.style.top = `${top}px`;
  toolbarEl.style.left = `${left}px`;
  toolbarEl.classList.toggle('below', isBelow);

  if (!isVisible) {
    // First show - animate in
    toolbarEl.classList.remove('hiding');
    // Force reflow to restart animation
    void toolbarEl.offsetHeight;
    toolbarEl.classList.add('visible');
    isVisible = true;
  } else {
    // Already visible - just reposition smoothly
    toolbarEl.classList.add('repositioning');
    requestAnimationFrame(() => {
      toolbarEl?.classList.remove('repositioning');
    });
  }
}

export function hideToolbar() {
  if (!toolbarEl || !isVisible) return;

  hideHeadingMenu();

  toolbarEl.classList.remove('visible');
  toolbarEl.classList.add('hiding');
  isVisible = false;

  hideTimeout = setTimeout(() => {
    if (toolbarEl) {
      toolbarEl.classList.remove('hiding');
    }
    hideTimeout = null;
  }, 100);
}

export function isToolbarVisible(): boolean {
  return isVisible;
}

export function destroyToolbar() {
  hideHeadingMenu();
  if (toolbarEl) {
    toolbarEl.remove();
    toolbarEl = null;
  }
  isVisible = false;
  if (hideTimeout) {
    clearTimeout(hideTimeout);
    hideTimeout = null;
  }
}
