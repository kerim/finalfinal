// DOM-level click handler for Cmd+click to open links in system browser
// Uses capture phase to fire before ProseMirror's plugin system

document.addEventListener(
  'click',
  (event) => {
    if (!(event.metaKey || event.ctrlKey)) return;

    // Walk up from click target to find <a> element
    let target = event.target as HTMLElement;
    while (target && target.tagName !== 'A') {
      target = target.parentElement as HTMLElement;
    }
    if (!target || target.tagName !== 'A') return;

    const href = target.getAttribute('href');
    if (!href) return;

    event.preventDefault();
    event.stopPropagation();
    window.webkit?.messageHandlers?.openURL?.postMessage(href);
  },
  true
);
