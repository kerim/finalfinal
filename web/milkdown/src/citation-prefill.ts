// Ahead-of-time citation fill: works out the display text of a document's citations BEFORE the document is loaded into this page, so
// the real load finds each one in the citation engine's memo instead of formatting it then (citeproc-engine.ts, "Formatted-citation
// memo"). Used by the app on the spare Rich Text page, which sits unseen in the background while the user is in Markdown.
//
// Two calls, both on `window.FinalFinal`, both driven from Swift (a page timer cannot be trusted in a hidden page):
//   - `prefillCitationsBegin(markdown)`: parses the document with this page's own parser, lists its citation groups and queues the
//     distinct ones that are not remembered yet. It changes nothing in the editor.
//   - `prefillCitationsStep(budgetMs)`: formats queued groups into the memo for about `budgetMs` and says how far it got.
//
// Why a half-finished or abandoned fill is harmless: each remembered entry is the citation processor's own answer to exactly the
// request the real load will make (the request is built by `citationFormatRequest`, the same function the node view uses), under the
// style and library the engine holds when it is formatted. A group not remembered is simply formatted during the load, as it always was.
// If the style or the library changes meanwhile the engine empties the memo itself; the rest of the queue is then formatted under the
// new style or library, which is also exactly what a load would ask for.
//
// What this never does: dispatch a transaction, touch the document or the selection, call `setContentHasBeenSet`, ask the app to
// resolve a key (`requestCitationResolution`), or post a message. The parse builds a document object and discards it.

import { parserCtx } from '@milkdown/kit/core';
import type { Node } from '@milkdown/kit/prose/model';
import { CITATION_NODE_NAME } from './citation-delete';
import { citationFormatRequest } from './citation-plugin';
import type { CitationAttrs } from './citation-types';
import { type CitationOptions, citationMemoKey, getCiteprocEngine } from './citeproc-engine';
import { getEditorInstance } from './editor-state';

export interface PrefillBeginResult {
  /** `ok`: parsed and queued. `notReady`: the editor does not exist yet (nothing queued). `parseFailed`: the parser threw or returned nothing (nothing queued). */
  status: 'ok' | 'notReady' | 'parseFailed';
  /** Citation groups in the document, every one of them. */
  groups: number;
  /** Distinct requests among the groups the node view would format (every key in the library). */
  distinct: number;
  /** Distinct requests queued: `distinct` minus those the memo already holds. 0 when the memo is switched off. */
  pending: number;
  /** Groups the node view would not format: a key the library lacks, no key, or unreadable locators. */
  unresolved: number;
  /** Milliseconds the parser took. */
  parseMs: number;
}

export interface PrefillStepResult {
  /** True when nothing is left to format (also when nothing was ever queued). */
  done: boolean;
  /** Requests formatted by this call. */
  formatted: number;
  /** Requests still queued after this call. */
  remaining: number;
  /** Milliseconds this call took. */
  ms: number;
}

interface QueuedRequest {
  citekeys: string[];
  options: CitationOptions;
}

// The queue of the last `prefillCitationsBegin`. `next` is the index of the first request not yet formatted.
let queue: QueuedRequest[] = [];
let next = 0;

function round(value: number): number {
  return Math.round(value * 100) / 100;
}

function failedBegin(status: 'notReady' | 'parseFailed', parseMs: number): PrefillBeginResult {
  return { status, groups: 0, distinct: 0, pending: 0, unresolved: 0, parseMs };
}

export function prefillCitationsBegin(markdown: string): PrefillBeginResult {
  // A new document replaces whatever an earlier call queued, whatever this call finds.
  queue = [];
  next = 0;

  const instance = getEditorInstance();
  if (!instance) return failedBegin('notReady', 0);

  // The page's own parser, the same no-dispatch call setCalibrationParser uses (api-content.ts): text in, document object out.
  const parseStart = performance.now();
  let doc: Node | undefined;
  try {
    doc = instance.action((ctx) => ctx.get(parserCtx)(markdown)) ?? undefined;
  } catch {
    doc = undefined;
  }
  const parseMs = round(performance.now() - parseStart);
  if (!doc) return failedBegin('parseFailed', parseMs);

  const engine = getCiteprocEngine();
  const memoEnabled = engine.getMemoStats().enabled;
  const seen = new Set<string>();
  const pending: QueuedRequest[] = [];
  let groups = 0;
  let unresolved = 0;

  doc.descendants((node) => {
    if (node.type.name !== CITATION_NODE_NAME) return true;
    groups++;

    // Exactly the groups the node view formats: every key in the library. Anything else it shows as a short form, without
    // asking the engine for text.
    let request: QueuedRequest;
    try {
      request = citationFormatRequest(node.attrs as CitationAttrs);
    } catch {
      unresolved++;
      return false;
    }
    if (request.citekeys.length === 0 || request.citekeys.some((key) => !engine.hasItem(key))) {
      unresolved++;
      return false;
    }

    const key = citationMemoKey(request.citekeys, request.options);
    if (seen.has(key)) return false;
    seen.add(key);
    if (memoEnabled && !engine.isMemoized(request.citekeys, request.options)) pending.push(request);
    return false;
  });

  queue = pending;
  return { status: 'ok', groups, distinct: seen.size, pending: pending.length, unresolved, parseMs };
}

export function prefillCitationsStep(budgetMs: number): PrefillStepResult {
  const start = performance.now();
  if (next >= queue.length) {
    queue = [];
    next = 0;
    return { done: true, formatted: 0, remaining: 0, ms: 0 };
  }

  const engine = getCiteprocEngine();
  const budget = Number.isFinite(budgetMs) && budgetMs > 0 ? budgetMs : 0;
  let formatted = 0;
  // At least one request per call, so repeated calls always make progress, whatever the budget.
  while (next < queue.length) {
    const request = queue[next++];
    // Skip what became remembered since `begin` (the real load can run in this page once it is claimed).
    if (!engine.isMemoized(request.citekeys, request.options)) {
      engine.formatCitation(request.citekeys, request.options);
      formatted++;
    }
    if (performance.now() - start >= budget) break;
  }

  const remaining = queue.length - next;
  if (remaining === 0) {
    queue = [];
    next = 0;
  }
  return { done: remaining === 0, formatted, remaining, ms: round(performance.now() - start) };
}
