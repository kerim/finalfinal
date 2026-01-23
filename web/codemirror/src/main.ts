// CodeMirror 6 Source Editor - Stub for Phase 1.1

console.log('[CodeMirror] Editor stub loaded');

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
    console.log('[CodeMirror] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[CodeMirror] scrollToOffset:', offset);
  }
};

console.log('[CodeMirror] window.FinalFinal API registered');
