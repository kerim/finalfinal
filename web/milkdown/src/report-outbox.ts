// report-outbox.ts -- Phase 5 job B2 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, section 2).
//
// The Rich Text editor reports each settled batch of block changes to Swift itself, on the `blockReport` message handler, numbered
// by an editor sequence `es` (one counter per page, from 1). In B2 the reports are SHADOW reports: Swift only records them and
// compares them with what the 2-second poll fetches; nothing is applied from them. So a report must never take anything out of the
// pending maps the poll drains (block-sync-plugin.ts `pendingUpdates` / `pendingInserts` / `pendingDeletes`): the plugin feeds the
// same detected operations into a second, SHADOW set of maps kept here, and a report takes (and clears) only the shadow.
//
// Three kinds of report, so Swift can fold the reports exactly as the real maps were built:
//   - `changes`: a settled batch (the 100 ms debounce settled), at most one per R ms (`intervalMs`; a timer posts the rest at R).
//   - `drain`:   posted by every drain of the real maps (block-sync-plugin.ts `getBlockChanges`: the poll, the editor-first routes, the
//                transitions), BEFORE the drain clears them, carrying the unposted shadow. It ends a window: the reports of the window
//                up to and including it fold to exactly what the drain took. The poll's reply names it (`reportThrough`).
//   - `rebase`:  posted when the real maps are changed other than by detection (a content reset, a paused push's re-baseline, a
//                managed rebuild's reconcile). It carries the real maps as they are now; Swift's fold restarts from them.
// Nothing is posted while sync is paused or while the typing is held back (a latched Cmd-Z, a transition hold): the timer tries again
// R ms later, so a held stretch leaves as one report when the hold ends. A drain or a rebase posts at once, held or not (it ends a
// window the poll or a route is ending right now).
//
// Test-only switches (Swift `TestMode`, passed in by a document-start user script as `window.__FF_REPORTS__`):
// `FF_UI_TESTING_LEGACY_POLL=1` turns reporting off (`enabled: false`); `FF_UI_TESTING_REPORT_INTERVAL_MS=<n>` sets R.

import type { BlockChanges, BlockInsert, BlockUpdate } from './block-sync-plugin';

/** R, the least time between two `changes` reports. docs/architecture/write-queue-plan/phase5/measurements.md, "B2: report interval"
 * (run-1793970750-67887): 100, 250 and 500 were not distinguishable from the poll build in the VM's noise; 250 stays until B3 measures
 * the cost of a write per report. */
export const DEFAULT_REPORT_INTERVAL_MS = 250;
/** B2 has no consumer of the outbox (nothing is acknowledged), so only the last reports are kept, for debugging. */
const OUTBOX_LIMIT = 50;

export type ReportKind = 'changes' | 'drain' | 'rebase';

export interface Report {
  es: number;
  session: string;
  kind: ReportKind;
  changes: BlockChanges;
  /** When the oldest change this report carries was detected (ms since the epoch). */
  detectedAt: number;
  postedAt: number;
}

/** One detected operation, in the order `detectChanges` found it. Applied to the real maps and to the shadow by the same rules. */
export type BlockOp =
  | { kind: 'delete'; id: string }
  | { kind: 'update'; id: string; update: BlockUpdate }
  | { kind: 'insert'; insert: BlockInsert };

export interface PendingMaps {
  pendingUpdates: Map<string, BlockUpdate>;
  pendingInserts: Map<string, BlockInsert>;
  pendingDeletes: Set<string>;
}

interface ReportConfig {
  enabled: boolean;
  intervalMs: number;
}

declare global {
  interface Window {
    __FF_REPORTS__?: { enabled?: boolean; intervalMs?: number };
  }
}

function readConfig(): ReportConfig {
  const raw = typeof window !== 'undefined' ? window.__FF_REPORTS__ : undefined;
  const interval = raw?.intervalMs;
  return {
    enabled: raw?.enabled !== false,
    intervalMs: typeof interval === 'number' && interval >= 0 ? interval : DEFAULT_REPORT_INTERVAL_MS,
  };
}

let config: ReportConfig | null = null;
function cfg(): ReportConfig {
  if (!config) config = readConfig();
  return config;
}

const session = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
let lastEs = 0;
const shadow: PendingMaps = { pendingUpdates: new Map(), pendingInserts: new Map(), pendingDeletes: new Set() };
/** When the oldest change in the shadow was detected; null while the shadow is empty. */
let shadowDetectedAt: number | null = null;
let lastPostAt = Number.NEGATIVE_INFINITY;
let postTimer: ReturnType<typeof setTimeout> | null = null;
const outbox: Report[] = [];
let holdProbe: () => boolean = () => false;
/** Sends one report; returns false when it could not be delivered (no `blockReport` handler on the page yet). */
type Poster = (body: Record<string, unknown>) => boolean;
let poster: Poster = (body) => {
  const handler = (
    window as unknown as { webkit?: { messageHandlers?: { blockReport?: { postMessage(b: unknown): void } } } }
  ).webkit?.messageHandlers?.blockReport;
  if (!handler) return false;
  handler.postMessage(body);
  return true;
};
/** True after a report could not be delivered: the next post is preceded by a `rebase` carrying the real maps, so Swift's fold
 * restarts from a report it received (a prepared or preloaded page posts before Swift has registered `blockReport` on it). */
let undelivered = false;
/** The real pending maps (block-sync-plugin.ts registers it), for that rebase. */
let realMapsProbe: () => PendingMaps | null = () => null;

/** Set by block-sync-plugin.ts: the real pending maps the poll drains. */
export function setRealMapsProbe(probe: () => PendingMaps | null): void {
  realMapsProbe = probe;
}

export function reportsEnabled(): boolean {
  return cfg().enabled;
}

export function reportSession(): string {
  return session;
}

/** The highest `es` posted so far (0 before the first). */
export function lastPostedEs(): number {
  return lastEs;
}

/** Called with what makes a post wait (sync paused, typing held back). Set by api-content.ts, which can see both. */
export function setReportHoldProbe(probe: () => boolean): void {
  holdProbe = probe;
}

/** The reports still kept (newest last). */
export function outboxEntries(): readonly Report[] {
  return outbox;
}

/** Applies `ops` to `maps` with the plugin's own merge rules (`detectChanges`): a delete removes a pending update and adds a
 * delete; an update of an id pending as an insert merges into the insert, otherwise it replaces the update; an insert sets the
 * insert. `onMergedIntoInsert` is the plugin's log hook (the real maps only). */
export function applyOps(maps: PendingMaps, ops: readonly BlockOp[], onMergedIntoInsert?: (id: string) => void): void {
  for (const op of ops) {
    if (op.kind === 'delete') {
      maps.pendingDeletes.add(op.id);
      maps.pendingUpdates.delete(op.id);
    } else if (op.kind === 'update') {
      const existing = maps.pendingInserts.get(op.id);
      if (existing) {
        maps.pendingInserts.set(op.id, {
          ...existing,
          blockType: op.update.blockType,
          textContent: op.update.textContent,
          markdownFragment: op.update.markdownFragment,
          headingLevel: op.update.headingLevel,
        });
        onMergedIntoInsert?.(op.id);
      } else {
        maps.pendingUpdates.set(op.id, op.update);
      }
    } else {
      maps.pendingInserts.set(op.insert.tempId, op.insert);
    }
  }
}

function snapshotOf(maps: PendingMaps): BlockChanges {
  return {
    updates: Array.from(maps.pendingUpdates.values()),
    inserts: Array.from(maps.pendingInserts.values()),
    deletes: Array.from(maps.pendingDeletes),
  };
}

function shadowIsEmpty(): boolean {
  return shadow.pendingUpdates.size === 0 && shadow.pendingInserts.size === 0 && shadow.pendingDeletes.size === 0;
}

function clearShadow(): void {
  shadow.pendingUpdates.clear();
  shadow.pendingInserts.clear();
  shadow.pendingDeletes.clear();
  shadowDetectedAt = null;
}

function cancelTimer(): void {
  if (postTimer !== null) {
    clearTimeout(postTimer);
    postTimer = null;
  }
}

function post(kind: ReportKind, changes: BlockChanges, detectedAt: number): number {
  if (undelivered && kind !== 'rebase') {
    const real = realMapsProbe();
    if (real) {
      // The rebase carries the real maps, which already hold what `changes` carries: the report below then merges the same
      // entries again, which leaves the fold unchanged.
      post('rebase', snapshotOf(real), Date.now());
    }
  }
  lastEs += 1;
  const now = Date.now();
  const report: Report = { es: lastEs, session, kind, changes, detectedAt, postedAt: now };
  outbox.push(report);
  if (outbox.length > OUTBOX_LIMIT) outbox.splice(0, outbox.length - OUTBOX_LIMIT);
  lastPostAt = now;
  try {
    const delivered = poster({
      es: report.es,
      session,
      kind,
      json: JSON.stringify(changes),
      detectedAt,
      postedAt: now,
    });
    if (!delivered) undelivered = true;
    else if (kind === 'rebase') undelivered = false;
  } catch (e) {
    undelivered = true;
    // A failed post must never break the drain or the detection that called it: the poll is still the only writer input in B2.
    console.error('[report-outbox] post failed', e);
  }
  return report.es;
}

/** The plugin detected `ops` and applied them to the real maps: mirror them into the shadow. */
export function shadowApplyOps(ops: readonly BlockOp[]): void {
  if (!cfg().enabled || ops.length === 0) return;
  applyOps(shadow, ops);
  if (shadowDetectedAt === null) shadowDetectedAt = Date.now();
}

/** The plugin re-keyed its maps after an id confirmation (`updateSnapshotIds`): the same re-key on the shadow. */
export function shadowRekey(mapping: ReadonlyMap<string, string>): void {
  if (!cfg().enabled) return;
  for (const [oldId, newId] of mapping) {
    const update = shadow.pendingUpdates.get(oldId);
    if (update) {
      shadow.pendingUpdates.delete(oldId);
      shadow.pendingUpdates.set(newId, { ...update, id: newId });
    }
    shadow.pendingInserts.delete(oldId);
    if (shadow.pendingDeletes.has(oldId)) {
      shadow.pendingDeletes.delete(oldId);
      shadow.pendingDeletes.add(newId);
    }
  }
}

/** A settled detection (the debounce, or a forced flush): post now, or at R after the last post, or (held) R later. */
export function noteSettled(): void {
  if (!cfg().enabled) return;
  schedulePost();
}

function schedulePost(): void {
  if (shadowIsEmpty() || postTimer !== null) return;
  const wait = lastPostAt + cfg().intervalMs - Date.now();
  if (wait <= 0 && !holdProbe()) {
    postShadow();
    return;
  }
  postTimer = setTimeout(
    () => {
      postTimer = null;
      schedulePost();
    },
    Math.max(wait, holdProbe() ? cfg().intervalMs : 0)
  );
}

function postShadow(): void {
  if (shadowIsEmpty()) return;
  const detectedAt = shadowDetectedAt ?? Date.now();
  const changes = snapshotOf(shadow);
  clearShadow();
  post('changes', changes, detectedAt);
}

/** Every drain of the real maps calls this first: posts the unposted shadow as the window's last report. Returns its `es`. */
export function postDrain(): number | null {
  if (!cfg().enabled) return null;
  cancelTimer();
  const detectedAt = shadowDetectedAt ?? Date.now();
  const changes = snapshotOf(shadow);
  clearShadow();
  return post('drain', changes, detectedAt);
}

/** The real maps were changed other than by detection; `real` is what they hold now. Swift's fold restarts from it. */
export function postRebase(real: PendingMaps): number | null {
  if (!cfg().enabled) return null;
  cancelTimer();
  clearShadow();
  return post('rebase', snapshotOf(real), Date.now());
}

/** Test-only: reset everything and (optionally) capture posts instead of sending them to WebKit. */
export function __resetReportOutboxForTest(options?: {
  poster?: Poster;
  enabled?: boolean;
  intervalMs?: number;
}): void {
  cancelTimer();
  clearShadow();
  undelivered = false;
  lastEs = 0;
  lastPostAt = Number.NEGATIVE_INFINITY;
  outbox.length = 0;
  holdProbe = () => false;
  config = {
    enabled: options?.enabled ?? true,
    intervalMs: options?.intervalMs ?? DEFAULT_REPORT_INTERVAL_MS,
  };
  if (options?.poster) poster = options.poster;
}

/** Test-only: the shadow as it is now. */
export function __shadowForTest(): BlockChanges {
  return snapshotOf(shadow);
}
