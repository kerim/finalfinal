// report-outbox.ts -- Phase 5 job B3 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, sections 3.2 to 3.6; notes in
// b3-notes.md). Job B2 built this file as a SHADOW of the poll; in B3 the reports ARE the Rich Text editor's input to Swift's writer.
//
// The editor reports each settled batch of block changes itself, on the `blockReport` message handler, numbered by an editor sequence
// `es` (one counter per page session, from 1), and keeps every report in its OUTBOX until Swift acknowledges it (`ackReports`).
// A report takes (and clears) the plugin's pending maps (block-sync-plugin.ts `pendingUpdates` / `pendingInserts` / `pendingDeletes`):
// there is no second copy any more, and nothing else drains those maps except the page calls Swift makes for a section command or a
// zoom / switch (the "routes"), which drain them under a COVER (below).
//
// When a report leaves:
//   - `changes`: the 100 ms debounce settled, at most one per R ms (`intervalMs`; a timer posts the rest at R). Not while sync is
//     paused, the typing is held back (a latched Cmd-Z, a transition hold) or the lifecycle save holds the reports (`holdReportsForSave`):
//     the timer tries again R ms later, so a held stretch leaves as one report when the hold ends.
//   - `flush`: `flushReports()` (Swift's `flushAndAck`) posts what is pending at once, ignoring R (still not while held).
//   - `drain`: a route's drain under a cover posts what it drained as one numbered report, so Swift can drop it as covered.
//
// The cover (design 3.3, the model's `ReplyCoversReports`). Swift reserves writer ticket N for a route and THEN sends the route's page
// call; a report the page posted just before is still on its way to Swift and would get a later ticket while holding older text. So
// Swift notes, in the same synchronous stretch as reserving N, the highest report number it has taken in (`since`) and wraps the route
// call in `beginReportCover(session, since)` / `endReportCover()`. The route's drain then returns the fold of every outbox entry
// after `since` plus what it drained itself, posts its own part as report `through`, and Swift drops every report up to `through`.
//
// Sessions (design 3.2, the model's `ReportSessionBound`): every report carries the page session, a token the page makes at load and
// makes anew at a project switch (`startNewReportSession`, called by `resetForProjectSwitch`). Swift refuses a report of a session it
// has revoked (the old project's), at receipt and again at the writer's turn.
//
// The re-post (Phase 5 job B4, design 4.2: the replacement of the 2-second poll's net). A report Swift has not acknowledged
// `REPOST_AFTER_MS` after it was last sent is sent again, unchanged (same number, same session, flagged `repost`). A page timer runs
// only while the outbox is not empty and stops when the last entry is acknowledged (or the session is renewed); it does not run while
// the lifecycle save holds the reports (the save covers them). Swift drops a re-post of a number it already has as a duplicate (and
// acknowledges again, in case the acknowledgement was what got lost); a report lost on the way is taken in from its re-post, or
// sooner by Swift's gap fetch when a later report shows the gap.
//
// The document-start user script (Swift `ReportIntake.configUserScript`, `window.__FF_REPORTS__`) turns reporting on and passes the
// test-only switches: `FF_UI_TESTING_REPORT_INTERVAL_MS=<n>` sets R; `FF_UI_TESTING_PUSH_REPOST_OFF=1` turns the re-post off.

import type { BlockChanges, BlockInsert, BlockUpdate } from './block-sync-plugin';

/** R, the least time between two `changes` reports. docs/architecture/write-queue-plan/phase5/measurements.md, "B2: report interval"
 * (run-1793970750-67887): 100, 250 and 500 were not distinguishable from the poll build in the VM's noise; 250 stays. */
export const DEFAULT_REPORT_INTERVAL_MS = 250;
/** How long an unacknowledged report waits before it is sent again (the 2-second poll's period, which the re-post replaces). */
export const REPOST_AFTER_MS = 2000;
/** An outbox this long means Swift has stopped acknowledging; entries are never dropped unacknowledged, this only logs once. */
const OUTBOX_WARN = 500;

export type ReportKind = 'changes' | 'flush' | 'drain';

export interface Report {
  es: number;
  session: string;
  kind: ReportKind;
  changes: BlockChanges;
  /** When the oldest change this report carries was detected (ms since the epoch). */
  detectedAt: number;
  postedAt: number;
  /** When it was last sent (its first post, or its latest re-post). */
  sentAt: number;
}

/** One detected operation, in the order `detectChanges` found it. */
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
  /** Re-post unacknowledged reports (off only with `FF_UI_TESTING_PUSH_REPOST_OFF=1`). */
  repost: boolean;
  repostAfterMs: number;
}

declare global {
  interface Window {
    __FF_REPORTS__?: { enabled?: boolean; intervalMs?: number; repost?: boolean };
  }
}

function readConfig(): ReportConfig {
  const raw = typeof window !== 'undefined' ? window.__FF_REPORTS__ : undefined;
  const interval = raw?.intervalMs;
  // B3: on only when Swift's document-start script says so (MilkdownEditor.swift and EditorPreloader.swift always add it). A page
  // without it (the vitest harnesses) keeps the pre-B2 behaviour: its maps wait for Swift's drain.
  return {
    enabled: raw?.enabled === true,
    intervalMs: typeof interval === 'number' && interval >= 0 ? interval : DEFAULT_REPORT_INTERVAL_MS,
    repost: raw?.repost !== false,
    repostAfterMs: REPOST_AFTER_MS,
  };
}

let config: ReportConfig | null = null;
function cfg(): ReportConfig {
  if (!config) config = readConfig();
  return config;
}

function newSessionToken(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

let session = newSessionToken();
let lastEs = 0;
/** When the oldest change now in the plugin's maps was detected; null while they are empty (or nothing was detected yet). */
let pendingDetectedAt: number | null = null;
let lastPostAt = Number.NEGATIVE_INFINITY;
let postTimer: ReturnType<typeof setTimeout> | null = null;
let repostTimer: ReturnType<typeof setTimeout> | null = null;
const outbox: Report[] = [];
let warnedLongOutbox = false;
let holdProbe: () => boolean = () => false;
/** The lifecycle save's read holds every report until the page is reset or Swift releases it (design 3.6). */
let saveHold = false;
/** Sends one report; returns false when it could not be delivered (no `blockReport` handler on the page yet). An undelivered report
 * stays in the outbox: Swift fetches it (`outboxSince`) when the next report shows a gap, or takes in its re-post. */
type Poster = (body: Record<string, unknown>) => boolean;
let poster: Poster = (body) => {
  const handler = (
    window as unknown as { webkit?: { messageHandlers?: { blockReport?: { postMessage(b: unknown): void } } } }
  ).webkit?.messageHandlers?.blockReport;
  if (!handler) return false;
  handler.postMessage(body);
  return true;
};
/** The plugin's pending maps (block-sync-plugin.ts registers it). */
let realMapsProbe: () => PendingMaps | null = () => null;

interface CoverState {
  since: number;
  used: boolean;
}
let cover: CoverState | null = null;

/** Set by block-sync-plugin.ts: its pending maps. */
export function setRealMapsProbe(probe: () => PendingMaps | null): void {
  realMapsProbe = probe;
}

export function reportsEnabled(): boolean {
  return cfg().enabled;
}

export function reportSession(): string {
  return session;
}

/** The highest `es` posted so far in this session (0 before the first). */
export function lastPostedEs(): number {
  return lastEs;
}

/** Called with what makes a post wait (sync paused, typing held back). Set by api-content.ts, which can see both. */
export function setReportHoldProbe(probe: () => boolean): void {
  holdProbe = probe;
}

/** The reports not yet acknowledged (oldest first). */
export function outboxEntries(): readonly Report[] {
  return outbox;
}

/** Applies `ops` to `maps` with the plugin's own merge rules (`detectChanges`): a delete of an id still pending as an insert cancels
 * that insert (t-80274c66: the insert was never sent, so the row it would make must never exist; the insert and any pending update
 * of it go, the delete is not added, and every other pending insert anchored on it is re-anchored to the cancelled insert's own
 * anchor, the document start included); any other delete removes a pending update and adds a delete; an update of an id pending as
 * an insert merges into the insert, otherwise it replaces the update; an insert sets the insert. `onMergedIntoInsert` and
 * `onInsertCancelled` are the plugin's log hooks.
 *
 * "Pending as an insert" means exactly "not sent": the plugin's maps are cleared on every post and a fold holds only reports Swift
 * has not taken in, so an insert already sent is in the outbox, not in `maps`, and its delete is kept (and goes out by its temp id,
 * or by the permanent id once the insert is confirmed). */
export function applyOps(
  maps: PendingMaps,
  ops: readonly BlockOp[],
  onMergedIntoInsert?: (id: string) => void,
  onInsertCancelled?: (id: string) => void
): void {
  for (const op of ops) {
    if (op.kind === 'delete') {
      const cancelled = maps.pendingInserts.get(op.id);
      if (cancelled) {
        maps.pendingInserts.delete(op.id);
        maps.pendingUpdates.delete(op.id);
        reanchorInsertsAfter(maps, cancelled);
        onInsertCancelled?.(op.id);
        continue;
      }
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

/** Every pending insert anchored on `cancelled` is placed where `cancelled` was to go: after the same block, or at the document start.
 * A chain cancelled one by one resolves itself, because each cancel copies an anchor that is already resolved. The map's order does
 * not change, so Swift (which places a batch's inserts in order and resolves a temp-id anchor from the ids it has just made) still
 * has the new anchor before it is needed. */
function reanchorInsertsAfter(maps: PendingMaps, cancelled: BlockInsert): void {
  for (const [tempId, insert] of maps.pendingInserts) {
    if (insert.afterBlockId !== cancelled.tempId) continue;
    maps.pendingInserts.set(tempId, {
      ...insert,
      afterBlockId: cancelled.afterBlockId,
      atDocumentStart: cancelled.atDocumentStart,
    });
  }
}

/** A batch as ops: its deletes, then its updates, then its inserts. `computeChangeOps` found them in a slightly different order (the
 * deletes and updates interleaved in the old snapshot's order, then the inserts); that is harmless here because no id is in two of a
 * batch's three lists. Folding batches oldest first with `applyOps` applies the cancel rule across them: a delete in a later batch
 * cancels an insert still pending from an earlier one (a batch never holds both for one id, so only a later batch's delete cancels). */
function opsOf(changes: BlockChanges): BlockOp[] {
  return [
    ...changes.deletes.map((id): BlockOp => ({ kind: 'delete', id })),
    ...changes.updates.map((update): BlockOp => ({ kind: 'update', id: update.id, update })),
    ...changes.inserts.map((insert): BlockOp => ({ kind: 'insert', insert })),
  ];
}

/** The fold of several batches, oldest first, with the merge rules. */
export function foldBatches(batches: readonly BlockChanges[]): BlockChanges {
  const maps: PendingMaps = { pendingUpdates: new Map(), pendingInserts: new Map(), pendingDeletes: new Set() };
  for (const batch of batches) applyOps(maps, opsOf(batch));
  return snapshotOf(maps);
}

function snapshotOf(maps: PendingMaps): BlockChanges {
  return {
    updates: Array.from(maps.pendingUpdates.values()),
    inserts: Array.from(maps.pendingInserts.values()),
    deletes: Array.from(maps.pendingDeletes),
  };
}

function isEmpty(changes: BlockChanges): boolean {
  return changes.updates.length === 0 && changes.inserts.length === 0 && changes.deletes.length === 0;
}

function mapsAreEmpty(maps: PendingMaps | null): boolean {
  return !maps || (maps.pendingUpdates.size === 0 && maps.pendingInserts.size === 0 && maps.pendingDeletes.size === 0);
}

function clearMaps(maps: PendingMaps): void {
  maps.pendingUpdates.clear();
  maps.pendingInserts.clear();
  maps.pendingDeletes.clear();
}

function cancelTimer(): void {
  if (postTimer !== null) {
    clearTimeout(postTimer);
    postTimer = null;
  }
}

function isHeld(): boolean {
  return saveHold || holdProbe();
}

function post(kind: ReportKind, changes: BlockChanges, detectedAt: number): number {
  lastEs += 1;
  const now = Date.now();
  const report: Report = { es: lastEs, session, kind, changes, detectedAt, postedAt: now, sentAt: now };
  outbox.push(report);
  if (outbox.length > OUTBOX_WARN && !warnedLongOutbox) {
    warnedLongOutbox = true;
    console.warn(`[report-outbox] ${outbox.length} reports not acknowledged`);
  }
  lastPostAt = now;
  try {
    poster({ es: report.es, session, kind, json: JSON.stringify(changes), detectedAt, postedAt: now });
  } catch (e) {
    // The report stays in the outbox: Swift's gap fetch or its re-post takes it from there.
    console.error('[report-outbox] post failed', e);
  }
  scheduleRepost();
  return report.es;
}

function cancelRepostTimer(): void {
  if (repostTimer !== null) {
    clearTimeout(repostTimer);
    repostTimer = null;
  }
}

/** Arms the re-post timer for the entry sent longest ago, if there is one and none is armed. Runs only while the outbox is not empty. */
function scheduleRepost(): void {
  const c = cfg();
  if (!c.enabled || !c.repost || repostTimer !== null || outbox.length === 0 || saveHold) return;
  const oldest = Math.min(...outbox.map((entry) => entry.sentAt));
  repostTimer = setTimeout(
    () => {
      repostTimer = null;
      repostDue();
    },
    Math.max(0, oldest + c.repostAfterMs - Date.now())
  );
}

/** Sends again, unchanged, every outbox entry not acknowledged `repostAfterMs` after it was last sent; then re-arms. */
function repostDue(): void {
  if (saveHold) return;
  const now = Date.now();
  for (const entry of outbox) {
    if (now - entry.sentAt < cfg().repostAfterMs) continue;
    entry.sentAt = now;
    try {
      poster({
        es: entry.es,
        session: entry.session,
        kind: entry.kind,
        json: JSON.stringify(entry.changes),
        detectedAt: entry.detectedAt,
        postedAt: entry.postedAt,
        repost: true,
      });
    } catch (e) {
      console.error('[report-outbox] re-post failed', e);
    }
  }
  scheduleRepost();
}

/** Takes the plugin's maps as one report. Returns its `es`, or null when there was nothing. */
function postPending(kind: ReportKind): number | null {
  const maps = realMapsProbe();
  if (!maps || mapsAreEmpty(maps)) {
    pendingDetectedAt = null;
    return null;
  }
  const detectedAt = pendingDetectedAt ?? Date.now();
  const changes = snapshotOf(maps);
  clearMaps(maps);
  pendingDetectedAt = null;
  return post(kind, changes, detectedAt);
}

/** The plugin detected changes into its maps (records when the oldest unreported one was detected). */
export function noteDetected(): void {
  if (!cfg().enabled) return;
  // A detection that left the maps empty (an insert cancelled by its own delete, t-80274c66) left nothing unreported: forget the
  // cancelled change's time, or the next report's `detectedAt` would be older than its own oldest change.
  if (mapsAreEmpty(realMapsProbe())) {
    pendingDetectedAt = null;
    return;
  }
  if (pendingDetectedAt === null) pendingDetectedAt = Date.now();
}

/** A settled detection (the debounce, or a forced flush): post now, or at R after the last post, or (held) R later. */
export function noteSettled(): void {
  if (!cfg().enabled) return;
  schedulePost();
}

function schedulePost(): void {
  if (postTimer !== null || mapsAreEmpty(realMapsProbe())) return;
  const wait = lastPostAt + cfg().intervalMs - Date.now();
  if (wait <= 0 && !isHeld()) {
    postPending('changes');
    return;
  }
  postTimer = setTimeout(
    () => {
      postTimer = null;
      schedulePost();
    },
    Math.max(wait, isHeld() ? cfg().intervalMs : 0)
  );
}

/**
 * `flushAndAck`'s page half (design 3.4 step 1): the caller has just run the pending debounce; this posts what is pending at once
 * (ignoring R; not while held) and answers the highest number posted, in the same page turn.
 */
export function flushReportsNow(): { session: string; through: number; held: boolean } {
  if (!cfg().enabled) return { session, through: 0, held: false };
  const held = isHeld();
  if (!held) {
    cancelTimer();
    postPending('flush');
  }
  return { session, through: lastEs, held };
}

/**
 * A route's drain (block-sync-plugin.ts `getBlockChanges`). With reporting off, or outside a cover, returns null and the plugin
 * returns its maps as before. Inside a cover, at the cover's first drain: returns the fold of every outbox entry after the cover's
 * `since` and the maps, and posts the maps' part as one `drain` report (so its number is covered too); the plugin then clears its maps.
 */
export function drainUnderCover(maps: PendingMaps): BlockChanges | null {
  if (!cfg().enabled || !cover || cover.used) return null;
  cover.used = true;
  cancelTimer();
  const since = cover.since;
  const inFlight = outbox.filter((entry) => entry.es > since).map((entry) => entry.changes);
  const own = snapshotOf(maps);
  if (!isEmpty(own)) {
    post('drain', own, pendingDetectedAt ?? Date.now());
  }
  pendingDetectedAt = null;
  return foldBatches([...inFlight, own]);
}

/** Swift's cover wrapper, before the route call. `swiftSession` is the session Swift last took a report of (null: none). */
export function beginReportCover(swiftSession: string | null, since: number): void {
  if (!cfg().enabled) return;
  cover = { since: swiftSession === session ? Math.max(0, since) : 0, used: false };
}

/** Swift's cover wrapper, after the route call: what the route covered. `drained` false: the route did not drain (nothing covered). */
export function endReportCover(): { session: string; since: number; through: number; drained: boolean } | null {
  if (!cfg().enabled || !cover) return null;
  const result = { session, since: cover.since, through: lastEs, drained: cover.used };
  cover = null;
  return result;
}

/** Swift applied (or gave up on) every report up to `through` of `forSession`: they leave the outbox. */
export function pruneOutbox(forSession: string, through: number): number {
  if (forSession !== session) return 0;
  let removed = 0;
  while (outbox.length > 0 && outbox[0].es <= through) {
    outbox.shift();
    removed += 1;
  }
  if (outbox.length <= OUTBOX_WARN) warnedLongOutbox = false;
  if (outbox.length === 0) cancelRepostTimer();
  return removed;
}

/** The outbox entries after `since` (all of them when Swift names another session), for Swift's gap fetch and `flushAndAck`'s fetch. */
export function outboxSince(
  swiftSession: string | null,
  since: number
): {
  session: string;
  lastEs: number;
  entries: { es: number; kind: ReportKind; json: string; detectedAt: number }[];
} {
  const from = swiftSession === session ? since : 0;
  return {
    session,
    lastEs,
    entries: outbox
      .filter((entry) => entry.es > from)
      .map((entry) => ({
        es: entry.es,
        kind: entry.kind,
        json: JSON.stringify(entry.changes),
        detectedAt: entry.detectedAt,
      })),
  };
}

/** The lifecycle save's live read (design 3.6): from now on nothing is posted; answers the session and the highest number posted. */
export function holdReportsForSave(): { session: string; through: number } {
  saveHold = true;
  cancelTimer();
  cancelRepostTimer();
  return { session, through: lastEs };
}

/** Ends the save's hold (a cancelled close); anything pending leaves now or at R. */
export function releaseReportHold(): void {
  saveHold = false;
  if (cfg().enabled) {
    schedulePost();
    scheduleRepost();
  }
}

/** A project switch resets the page: a new session, numbers from 1, an empty outbox, no hold (Swift revoked the old session). */
export function startNewReportSession(): string {
  cancelTimer();
  cancelRepostTimer();
  session = newSessionToken();
  lastEs = 0;
  outbox.length = 0;
  cover = null;
  saveHold = false;
  pendingDetectedAt = null;
  lastPostAt = Number.NEGATIVE_INFINITY;
  return session;
}

/** Test-only: reset everything and (optionally) capture posts instead of sending them to WebKit. */
export function __resetReportOutboxForTest(options?: {
  poster?: Poster;
  enabled?: boolean;
  intervalMs?: number;
  repost?: boolean;
  repostAfterMs?: number;
}): void {
  startNewReportSession();
  warnedLongOutbox = false;
  holdProbe = () => false;
  config = {
    enabled: options?.enabled ?? true,
    intervalMs: options?.intervalMs ?? DEFAULT_REPORT_INTERVAL_MS,
    repost: options?.repost ?? true,
    repostAfterMs: options?.repostAfterMs ?? REPOST_AFTER_MS,
  };
  if (options?.poster) poster = options.poster;
}
