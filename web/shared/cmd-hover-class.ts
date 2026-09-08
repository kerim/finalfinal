// Tracks whether the ⌘ (Meta) key is currently held and reflects it as a class on
// `document.body` so CSS can show a ⌘-hover hint (UX contract §2, D2: "headings carry
// a visible hint that ⌘-click is available"). Milkdown-only consumer today — see
// heading-zoom-click-handler.ts's own doc comment for why Cmd-click-to-zoom itself
// currently exists only in that editor; this module has no editor-specific knowledge
// of its own and could be reused elsewhere later.

export const CMD_HELD_CLASS = 'ff-cmd-held';

/**
 * Installs document/window-level listeners that keep `document.body` tagged with
 * `CMD_HELD_CLASS` while ⌘ is held. Returns an uninstall function that removes the
 * listeners and clears the class.
 *
 * Reads `event.metaKey` on both `keydown` and `mousemove` (not just `key === 'Meta'`
 * on keydown) so a ⌘ already held when the pointer enters the webview is picked up
 * immediately, rather than waiting for the next keydown -- a keydown that may never
 * come if the key was pressed before the pointer moved over this document at all.
 * `mousemove` also self-heals a missed keyup (e.g. a ⌘-triggered app switch that
 * steals the keyup): the next mouse movement re-reads the true state directly from
 * the browser rather than trusting the last keyboard event.
 */
export function installCmdHeldTracking(doc: Document = document): () => void {
  // Review-fix round, must-fix 5: `doc.defaultView` (falling back to the global `window` only
  // when the injected doc has none, e.g. a detached document in a test) rather than the bare
  // `window` -- this module's own doc comment above promises multi-document support via the
  // `doc` parameter, but `blur` fires on a document's OWN view, not necessarily the global
  // `window`, so the bare reference silently broke that promise for any `doc` belonging to a
  // different window (an iframe, or another top-level document).
  const view = doc.defaultView ?? window;

  // Review-fix round, must-fix 6: state is derived from the DOM (`doc.body`'s own class list)
  // on every call, rather than trusted from a closure-local `held` variable. A closure-local
  // flag desyncs across a second concurrent install: the first install's `uninstall()` calls
  // `set(false)`, which strips the class from `doc.body` -- but the second install's own
  // `held` closure variable is still `true`, so ITS next `set(true)` sees `next === held` and
  // early-returns without ever re-adding the class, permanently. Reading `doc.body`'s actual
  // class list instead means each installation's `set()` reflects true DOM state regardless of
  // what any other installation last did.
  const set = (next: boolean) => {
    const current = doc.body.classList.contains(CMD_HELD_CLASS);
    if (next === current) return;
    doc.body.classList.toggle(CMD_HELD_CLASS, next);
  };
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.metaKey) set(true);
  };
  const onKeyUp = (e: KeyboardEvent) => {
    if (!e.metaKey) set(false);
  };
  const onMouseMove = (e: MouseEvent) => {
    set(e.metaKey);
  };
  const onBlur = () => set(false);
  const onVisibilityChange = () => {
    if (doc.hidden) set(false);
  };

  doc.addEventListener('keydown', onKeyDown);
  doc.addEventListener('keyup', onKeyUp);
  doc.addEventListener('mousemove', onMouseMove);
  view.addEventListener('blur', onBlur);
  doc.addEventListener('visibilitychange', onVisibilityChange);

  return () => {
    doc.removeEventListener('keydown', onKeyDown);
    doc.removeEventListener('keyup', onKeyUp);
    doc.removeEventListener('mousemove', onMouseMove);
    view.removeEventListener('blur', onBlur);
    doc.removeEventListener('visibilitychange', onVisibilityChange);
    set(false);
  };
}
