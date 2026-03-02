// Sync diagnostic logger — shared helper for sidebar ↔ editor desync debugging.
// All messages go through the errorHandler bridge to appear in Xcode console.
// See docs/guides/webkit-debug-logging.md for the bridge pattern.

export function syncLog(tag: string, ...args: unknown[]): void {
  const msg = args
    .map((a) => {
      if (a instanceof Error) return `${a.message}\n${a.stack}`;
      if (typeof a === 'string') return a;
      try {
        return JSON.stringify(a);
      } catch {
        return String(a);
      }
    })
    .join(' ');
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'sync-diag',
    message: `[${tag}] ${msg}`,
  });
}
