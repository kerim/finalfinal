// Typing-latency trace (Phase 4b part 2, slice 0 -- measurement only; t-94369a83).
//
// Two facts the app's own clock cannot see from Swift alone, posted to Swift ONLY while Swift has switched the flag on
// (`window.FinalFinal.setTraceTyping(true)`, sent when the editor loads with Diagnostics logging on, and again whenever the
// Diagnostics toggle changes). The flag defaults to false, and while it is false every function here returns before it reads
// or posts anything, so a normal session pays one boolean check per real user edit and nothing else.
//
//  - `typingEcho` {n}: from a task right after the first requestAnimationFrame that follows a REAL USER EDIT transaction (the
//    same notion the undo coordinator uses, `isRealUserEditTransaction`: the document changed, history was not switched off,
//    and it is not a `derivedCorrection`). The frame callback runs before that frame's layout and paint, so the message is
//    posted from a task AFTER the callback, which is after the frame's rendering work has run. The figure Swift derives
//    from it (its own clock on receipt, minus the key's own timestamp) is still a LOWER BOUND on "keystroke on screen": the
//    compositor and the scan-out are not visible from JavaScript. `n` is how many real user edits this one echo covers
//    (edits made before the same frame share it), so an analyser can pair each key with the first echo at or after it.
//  - `efRemovalPainted` {opId}: from a task right after the first animation frame that follows `deleteSectionEditorFirst`'s removal
//    (api-section-delete.ts). Swift's own clock on receipt, minus the timestamp of the right-click that started the delete, is the
//    delete latency of plan section 6 (R4/A11). Same lower-bound caveat as `typingEcho`.
//  - `typingTrace` / `rebuild-replaced-pending`: a Notes, bibliography or footnote rebuild push replaced a block that had a
//    pending (typed, not yet saved) edit in the block-sync queue, and the rebuild dropped that queued edit. This is the
//    unexplained "text lost 2.7 s after a delete" suspect (scout brief section E, path 3).
//
// Leaf module (no imports): block-sync-plugin.ts and undo-coordinator.ts both call into it, so it must not import either.

let traceTyping = false;
let echoFrameScheduled = false;
let echoEditCount = 0;

/** Swift switches the trace on (editor load, Diagnostics logging on) or off. Default off. */
export function setTraceTyping(on: boolean): void {
  traceTyping = on === true;
  if (!traceTyping) {
    echoFrameScheduled = false;
    echoEditCount = 0;
  }
}

/** Whether the trace is on. Callers that would do extra work to build a trace message check this first. */
export function isTraceTypingOn(): boolean {
  return traceTyping;
}

function post(handler: 'typingEcho' | 'typingTrace' | 'efRemovalPainted', body: Record<string, unknown>): void {
  (window as any).webkit?.messageHandlers?.[handler]?.postMessage(body);
}

/**
 * Called once per REAL USER EDIT transaction (undo-coordinator.ts `noteUserTransaction`, which has already decided that the
 * transaction is a real user edit). Posts `typingEcho` from a task after the next animation frame.
 */
export function noteRealUserEditForEcho(): void {
  if (!traceTyping) return;
  echoEditCount += 1;
  if (echoFrameScheduled) return;
  echoFrameScheduled = true;
  requestAnimationFrame(() => {
    // Edits from here on belong to the next echo; this one covers the edits counted so far.
    const edits = echoEditCount;
    echoEditCount = 0;
    echoFrameScheduled = false;
    if (edits === 0) return; // an earlier frame callback already covered these edits (the flag was toggled in between)
    setTimeout(() => {
      if (traceTyping) post('typingEcho', { n: edits });
    }, 0);
  });
}

/**
 * `deleteSectionEditorFirst` has just dispatched its removal for `opId`. Posts `efRemovalPainted` from a task after the next
 * animation frame, so Swift can time the delete up to the first paint without the section.
 */
export function noteRemovalForPaint(opId: string): void {
  if (!traceTyping) return;
  requestAnimationFrame(() => {
    setTimeout(() => {
      if (traceTyping) post('efRemovalPainted', { opId });
    }, 0);
  });
}

/**
 * A managed-rebuild push dropped the pending edit queued for `blockId`. `kind` is what Swift said the rebuild was
 * ('notes', 'bibliography' or 'footnote'); 'unknown' if the push did not say.
 */
export function noteRebuildReplacedPending(kind: string | undefined, blockId: string): void {
  if (!traceTyping) return;
  post('typingTrace', { event: 'rebuild-replaced-pending', kind: kind ?? 'unknown', block: blockId });
}
