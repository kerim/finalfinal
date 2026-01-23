// Milkdown WYSIWYG Editor - Stub for Phase 1.1

console.log('[Milkdown] Editor stub loaded');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
    };
  }
}

let currentContent = '';

window.FinalFinal = {
  setContent(markdown: string) {
    currentContent = markdown;
    console.log('[Milkdown] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[Milkdown] setFocusMode:', enabled);
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[Milkdown] scrollToOffset:', offset);
  }
};

console.log('[Milkdown] window.FinalFinal API registered');
