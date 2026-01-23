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
      setTheme: (cssVariables: string) => void;
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
  },
  setTheme(cssVariables: string) {
    const root = document.documentElement;
    const pairs = cssVariables.split(';').filter(s => s.trim());
    pairs.forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[CodeMirror] Theme applied with', pairs.length, 'variables');
  }
};

console.log('[CodeMirror] window.FinalFinal API registered');
