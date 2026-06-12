// Shared by both editors: open the Swift-side equation dialog.
// Swift shows the NSAlert form, then calls window.FinalFinal.insertEquation(latex, isDisplay)
// back into whichever editor is active.

export function insertEquationDialog(): void {
  if (typeof (window as any).webkit?.messageHandlers?.openEquationDialog?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.openEquationDialog.postMessage(null);
  }
}
