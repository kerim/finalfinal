// Property-based testing harness for block-id-plugin's id matching.
//
// This file is infrastructure only (PRNG, document/operation generator, a
// deterministic replayer, invariant checkers, and a shrinker) — the actual
// properties (P-A, P-B) and the 5 pinned regression cases live in
// block-id-property.test.ts. Everything here drives the REAL
// `assignBlockIds` (and its sibling exported functions: `alignTopLevelIds`,
// `replaceTopLevelIds`, `confirmBlockIds`, `applyPendingConfirmations`,
// `getAllBlockIds`, `resetBlockIdState`) against REAL ProseMirror `Transform`
// steps on a real (if minimal) schema — never a reimplementation of the
// plugin's matching logic.
//
// Design note on "block identity": the production schema has no concept of
// node identity beyond position + content: a block's *real* id is exactly
// what `assignBlockIds` decides it is. To ask "did block X keep its id?" at
// all, this harness needs an identity that is independent of the code under
// test — so every node gets a synthetic `tid` attribute, threaded through
// every operation by hand (mirroring what a human editor's mental model of
// "the same paragraph" would be — see `applyOpDescriptor`'s per-op comments).
// `tid` never exists in the production schema; it is a test-only oracle.
import { type Node, Schema } from '@milkdown/kit/prose/model';
import type { Mapping } from '@milkdown/kit/prose/transform';
import { canJoin, Transform } from '@milkdown/kit/prose/transform';
import {
  alignTopLevelIds,
  applyPendingConfirmations,
  assignBlockIds,
  confirmBlockIds,
  getAllBlockIds,
  getRecentlySplitEmptyIds,
  replaceTopLevelIds,
  resetBlockIdState,
} from '../block-id-plugin';

// ============================================================================
// PRNG — hand-rolled seeded generator (fast-check is not installed; see task).
// mulberry32: small, fast, decent statistical quality, and — the property
// that matters here — 100% deterministic for a given integer seed, forever,
// across Node/V8 versions (unlike Math.random()).
// ============================================================================
export function mulberry32(seed: number): () => number {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Integer in [0, n). */
function randInt(rnd: () => number, n: number): number {
  return Math.floor(rnd() * n);
}

// ============================================================================
// Schema — minimal, test-only. `tid` is the harness's synthetic identity
// oracle (see file header); it is never present on the production schema.
// ============================================================================
export const propSchema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: {
      group: 'block',
      content: 'inline*',
      attrs: { tid: { default: '' } },
      toDOM: () => ['p', 0],
    },
    heading: {
      group: 'block',
      content: 'inline*',
      attrs: { tid: { default: '' }, level: { default: 1 } },
      toDOM: () => ['h1', 0],
    },
    text: { group: 'inline' },
  },
});

function randomChar(rnd: () => number): string {
  // CJK ideograph range: single UTF-16 code unit per char, visually distinct,
  // never whitespace/punctuation that ProseMirror or the DOM might collapse
  // or normalize — same trick the planner's prototype used.
  return String.fromCharCode(0x4e00 + randInt(rnd, 0x1000));
}

function randomText(rnd: () => number, len: number): string {
  let s = '';
  for (let i = 0; i < len; i++) s += randomChar(rnd);
  return s;
}

function makeNode(type: 'paragraph' | 'heading', tid: string, text: string): Node {
  return propSchema.nodes[type].create({ tid }, text ? [propSchema.text(text)] : []);
}

// ============================================================================
// Document model: an ordered array of top-level block specs + a builder.
// ============================================================================
export interface BlockSpec {
  type: 'paragraph' | 'heading';
  text: string;
  tid: string;
}

export function buildDoc(specs: readonly BlockSpec[]): Node {
  return propSchema.nodes.doc.create(
    null,
    specs.map((s) => makeNode(s.type, s.tid, s.text))
  );
}

export interface GenerateInitialBlocksOptions {
  paragraphsOnly: boolean;
  minBlocks?: number;
  maxBlocks?: number;
  maxTextLen?: number;
}

export function generateInitialBlocks(rnd: () => number, opts: GenerateInitialBlocksOptions): BlockSpec[] {
  const min = opts.minBlocks ?? 3;
  const max = opts.maxBlocks ?? 9;
  const n = min + randInt(rnd, Math.max(1, max - min));
  const specs: BlockSpec[] = [];
  for (let i = 0; i < n; i++) {
    const type = opts.paragraphsOnly || rnd() < 0.75 ? 'paragraph' : 'heading';
    const text = rnd() < 0.4 ? '' : randomText(rnd, 1 + randInt(rnd, opts.maxTextLen ?? 6));
    specs.push({ type, text, tid: `tid-${i}` });
  }
  return specs;
}

function topBlocks(doc: Node): Array<{ node: Node; offset: number }> {
  const arr: Array<{ node: Node; offset: number }> = [];
  doc.forEach((node, offset) => {
    arr.push({ node, offset });
  });
  return arr;
}

// ============================================================================
// Operation vocabulary. Every kind here corresponds to one item in the task's
// edit vocabulary: typeChar, typeRun, deleteChars, split, join, deleteBlocks,
// deleteAcross, insertBlock, setType, confirm.
//
// A descriptor is plain, JSON-serializable data — this is what makes a
// failing case pasteable (see `formatRepro`): the exact op sequence that
// produced a failure can be embedded as a literal and replayed with
// `replayCase`, with no PRNG involved.
// ============================================================================
export type OpKind =
  | 'typeChar'
  | 'typeRun'
  | 'deleteChars'
  | 'split'
  | 'join'
  | 'deleteBlocks'
  | 'deleteAcross'
  | 'insertBlock'
  | 'setType'
  | 'confirm';

export type OpDescriptor =
  | { kind: 'typeChar'; blockIndex: number; at: number; char: string }
  | { kind: 'typeRun'; blockIndex: number; at: number; text: string }
  | { kind: 'deleteChars'; blockIndex: number; from: number; to: number }
  | { kind: 'split'; blockIndex: number; at: number; newTid: string }
  | { kind: 'join'; blockIndex: number } // joins top-level block (blockIndex-1) <- blockIndex
  | { kind: 'deleteBlocks'; from: number; to: number } // inclusive top-level block index range
  | { kind: 'deleteAcross'; fromBlock: number; fromOffsetInBlock: number; toBlock: number; toOffsetInBlock: number }
  | { kind: 'insertBlock'; atIndex: number; blockType: 'paragraph' | 'heading'; text: string; tid: string }
  | { kind: 'setType'; blockIndex: number }
  | { kind: 'confirm'; mapping: Record<string, string> }; // temp id -> newly-assigned permanent id

export interface RecordedCase {
  seed: number;
  initialBlocks: BlockSpec[];
  ops: OpDescriptor[];
}

export interface GenOptions {
  rnd: () => number;
  allowedOps: readonly OpKind[];
  paragraphsOnly: boolean;
  nextTid: () => string;
  nextPermId: () => string;
  /** Soft cap: candidate ops that would obviously blow past this are skipped
   * at generation time (deleteBlocks additionally re-checked at apply time). */
  maxDocSize: number;
}

// Mirrors the plugin's own (private, unexported) TEMP_ID_PREFIX constant —
// see block-id-plugin.ts's `TEMP_ID_PREFIX`. Duplicated here only because it
// isn't exported; if that constant's value ever changes this must follow it.
const TEMP_ID_PREFIX = 'temp-';

/** Picks random, in-range parameters for one op, given the CURRENT doc. Returns
 * null when nothing valid exists for the chosen kind this attempt (e.g. `join`
 * picked doc position 0, or `confirm` picked with no pending temp ids) — the
 * caller treats null as "skip this step", not "stop". */
export function randomOpDescriptor(doc: Node, ids: Map<number, string>, opts: GenOptions): OpDescriptor | null {
  const top = topBlocks(doc);
  if (top.length === 0) return null;
  const kind = opts.allowedOps[randInt(opts.rnd, opts.allowedOps.length)];

  switch (kind) {
    case 'typeChar': {
      const i = randInt(opts.rnd, top.length);
      const at = randInt(opts.rnd, top[i].node.content.size + 1);
      return { kind, blockIndex: i, at, char: randomChar(opts.rnd) };
    }
    case 'typeRun': {
      const i = randInt(opts.rnd, top.length);
      const at = randInt(opts.rnd, top[i].node.content.size + 1);
      return { kind, blockIndex: i, at, text: randomText(opts.rnd, 2 + randInt(opts.rnd, 4)) };
    }
    case 'deleteChars': {
      const i = randInt(opts.rnd, top.length);
      const size = top[i].node.content.size;
      if (size === 0) return null;
      const from = randInt(opts.rnd, size);
      const to = from + 1 + randInt(opts.rnd, size - from);
      return { kind, blockIndex: i, from, to };
    }
    case 'split': {
      const i = randInt(opts.rnd, top.length);
      const at = randInt(opts.rnd, top[i].node.content.size + 1);
      return { kind, blockIndex: i, at, newTid: opts.nextTid() };
    }
    case 'join': {
      if (top.length < 2) return null;
      const i = 1 + randInt(opts.rnd, top.length - 1);
      if (!canJoin(doc, top[i].offset)) return null;
      return { kind, blockIndex: i };
    }
    case 'deleteBlocks': {
      if (top.length < 2) return null; // doc requires at least one surviving block
      const i = randInt(opts.rnd, top.length);
      const j = Math.min(top.length - 1, i + randInt(opts.rnd, 3));
      if (j - i + 1 >= top.length) return null; // never delete every block
      return { kind, from: i, to: j };
    }
    case 'deleteAcross': {
      if (top.length < 2) return null;
      const i = randInt(opts.rnd, top.length - 1);
      const j = i + 1 + randInt(opts.rnd, Math.min(2, top.length - 1 - i));
      const fromOffsetInBlock = randInt(opts.rnd, top[i].node.content.size + 1);
      const toOffsetInBlock = randInt(opts.rnd, top[j].node.content.size + 1);
      return { kind, fromBlock: i, fromOffsetInBlock, toBlock: j, toOffsetInBlock };
    }
    case 'insertBlock': {
      const atIndex = randInt(opts.rnd, top.length + 1);
      const blockType = opts.paragraphsOnly || opts.rnd() < 0.7 ? 'paragraph' : 'heading';
      const text = opts.rnd() < 0.5 ? '' : randomText(opts.rnd, 1 + randInt(opts.rnd, 3));
      return { kind, atIndex, blockType, text, tid: opts.nextTid() };
    }
    case 'setType': {
      if (opts.paragraphsOnly) return null; // P-B never converts types
      const i = randInt(opts.rnd, top.length);
      return { kind, blockIndex: i };
    }
    case 'confirm': {
      const temps = new Set<string>();
      for (const id of ids.values()) if (id.startsWith(TEMP_ID_PREFIX)) temps.add(id);
      if (temps.size === 0) return null;
      const mapping: Record<string, string> = {};
      for (const t of temps) if (opts.rnd() < 0.5) mapping[t] = opts.nextPermId();
      if (Object.keys(mapping).length === 0) return null;
      return { kind, mapping };
    }
  }
}

export interface AppliedOp {
  tr: Transform;
}

/**
 * Deterministically turns one descriptor + the CURRENT doc into a real
 * ProseMirror `Transform` (or null if the descriptor is stale against this
 * doc — only possible when a shrinker has mutated a case; never happens
 * during straight-line generation or replay of an unmodified case).
 *
 * This is the ONE place op semantics live, shared by random generation and
 * exact replay, so both paths are bit-identical by construction.
 */
export function applyOpDescriptor(doc: Node, desc: OpDescriptor): AppliedOp | null {
  const top = topBlocks(doc);
  switch (desc.kind) {
    case 'typeChar':
    case 'typeRun': {
      const b = top[desc.blockIndex];
      if (!b) return null;
      const text = desc.kind === 'typeChar' ? desc.char : desc.text;
      const at = Math.min(desc.at, b.node.content.size);
      return { tr: new Transform(doc).insert(b.offset + 1 + at, propSchema.text(text)) };
    }
    case 'deleteChars': {
      const b = top[desc.blockIndex];
      if (!b) return null;
      const size = b.node.content.size;
      const from = Math.min(desc.from, size);
      const to = Math.min(Math.max(desc.to, from), size);
      if (from === to) return null;
      return { tr: new Transform(doc).delete(b.offset + 1 + from, b.offset + 1 + to) };
    }
    case 'split': {
      const b = top[desc.blockIndex];
      if (!b) return null;
      const len = b.node.content.size;
      const at = Math.min(desc.at, len);
      const tr = new Transform(doc);
      if (at === 0 && len > 0) {
        // Splitting at the very start of the content ("Enter" pressed with the
        // cursor before any text): ProseMirror's split necessarily puts the
        // ORIGINAL content in the tail part, so give the tail the ORIGINAL tid
        // (via typesAfter) and mint a fresh tid for the new, leading, empty
        // node — matching what a user would expect ("a blank line appears
        // above; what I was editing is unchanged, just pushed down").
        tr.split(b.offset + 1, 1, [{ type: b.node.type, attrs: { ...b.node.attrs } }]);
        tr.setNodeAttribute(b.offset, 'tid', desc.newTid);
      } else {
        // Splitting mid/end-content ("Enter" with the cursor in the middle or
        // at the end): the part BEFORE the cursor keeps the original tid (the
        // user is still "in" that paragraph); the part AFTER the cursor is a
        // new block.
        tr.split(b.offset + 1 + at, 1, [{ type: b.node.type, attrs: { ...b.node.attrs, tid: desc.newTid } }]);
      }
      return { tr };
    }
    case 'join': {
      const b = top[desc.blockIndex];
      if (!b || desc.blockIndex < 1) return null;
      if (!canJoin(doc, b.offset)) return null;
      // Deliberately NO manual tid transfer here (unlike the planner's
      // prototype): ProseMirror's own `join` keeps the EARLIER node's
      // identity/attrs by default, and P-B's checker (see
      // block-id-property.test.ts) only asserts identity for a block whose
      // "before" snapshot was already content-bearing — so the one case where
      // "which side survives" is genuinely ambiguous (an EMPTY earlier node
      // absorbing a non-empty later one) is never asserted on at all, rather
      // than guessed at here. See that file's `checkIdentity` for the exact
      // reasoning.
      return { tr: new Transform(doc).join(b.offset) };
    }
    case 'deleteBlocks': {
      const from = top[desc.from];
      const to = top[desc.to];
      if (!from || !to) return null;
      return { tr: new Transform(doc).delete(from.offset, to.offset + to.node.nodeSize) };
    }
    case 'deleteAcross': {
      const fb = top[desc.fromBlock];
      const tb = top[desc.toBlock];
      if (!fb || !tb) return null;
      const from = fb.offset + 1 + Math.min(desc.fromOffsetInBlock, fb.node.content.size);
      const to = tb.offset + 1 + Math.min(desc.toOffsetInBlock, tb.node.content.size);
      if (from >= to) return null;
      return { tr: new Transform(doc).delete(from, to) };
    }
    case 'insertBlock': {
      const pos = desc.atIndex >= top.length ? doc.content.size : top[desc.atIndex].offset;
      const nodeType = propSchema.nodes[desc.blockType];
      const content = desc.text ? [propSchema.text(desc.text)] : [];
      return { tr: new Transform(doc).insert(pos, nodeType.create({ tid: desc.tid }, content)) };
    }
    case 'setType': {
      const b = top[desc.blockIndex];
      if (!b) return null;
      const newType = b.node.type.name === 'paragraph' ? propSchema.nodes.heading : propSchema.nodes.paragraph;
      return { tr: new Transform(doc).setNodeMarkup(b.offset, newType, { ...b.node.attrs }) };
    }
    case 'confirm':
      // Handled separately by the engine (no Transform involved) — see runEngine.
      return null;
  }
}

// ============================================================================
// Per-tid snapshots, used by identity checks (P-B). Cheap no-op for
// properties (P-A) that never look at them.
// ============================================================================
export interface TidSnapshot {
  tid: string;
  id: string;
  text: string;
  type: string;
  offset: number;
}

export function snapshotByTid(doc: Node, ids: Map<number, string>): TidSnapshot[] {
  const out: TidSnapshot[] = [];
  doc.forEach((node, offset) => {
    const tid = node.attrs.tid;
    if (!tid) return;
    out.push({ tid, id: ids.get(offset) ?? '', text: node.textContent, type: node.type.name, offset });
  });
  return out;
}

// ============================================================================
// Checker contract. A checker returns null (property holds) or a message
// starting with a short UPPERCASE category token (MISSING, DUPLICATE,
// LOST_IDENTITY, ...) — the shrinker treats that leading token as the
// "failure class" it must preserve while minimizing.
// ============================================================================
export interface StepInfo {
  doc: Node;
  ids: Map<number, string>;
  before: TidSnapshot[];
  after: TidSnapshot[];
  op: OpDescriptor;
  /** Snapshot of `getRecentlySplitEmptyIds()` taken immediately BEFORE this
   * step's `assignBlockIds` call — i.e. which ids were "fresh, still-empty,
   * just split" going into this step. A checker that wants to recognize "this
   * claim was resolved via the split-then-fill bypass" (canClaimViaRecent
   * SplitBypass) needs the id's status from BEFORE the call, because
   * `assignBlockIds` itself prunes a marker the instant its id stops being
   * empty — which is exactly the case a content-bearing claimant creates. */
  recentlySplitEmptyIdsBefore: ReadonlySet<string>;
}
export type StepChecker = (info: StepInfo) => string | null;

// ============================================================================
// The engine: applies a sequence of ops (random or fixed) against real
// `assignBlockIds`, calling `check` after every successfully-applied step
// (confirm included — a confirm cannot move the doc but CAN rename ids, and a
// broken rename should be just as catchable as a broken structural claim).
// ============================================================================
export interface EngineResult {
  ok: boolean;
  ops: OpDescriptor[];
  stepIndex: number; // index into `ops` of the failing step (meaningless if ok)
  message: string; // '' if ok
}

function runEngine(
  initialBlocks: BlockSpec[],
  opSource: (doc: Node, ids: Map<number, string>, step: number) => OpDescriptor | null,
  check: StepChecker,
  maxSteps: number,
  maxDocSize: number
): EngineResult {
  resetBlockIdState();
  let doc = buildDoc(initialBlocks);
  const seeded = alignTopLevelIds(
    initialBlocks.map((_, i) => `seed-id-${i}`),
    doc
  );
  let ids = seeded.blockIds;
  let types = seeded.blockTypes;
  const recorded: OpDescriptor[] = [];

  for (let step = 0; step < maxSteps; step++) {
    const desc = opSource(doc, ids, step);
    if (!desc) continue;

    if (desc.kind === 'confirm') {
      if (Object.keys(desc.mapping).length === 0) continue;
      // Route through the REAL production functions exactly as
      // BlockSyncService/api-content.ts do on a Swift confirmation round-trip:
      // sync module state from our local `ids` (replaceTopLevelIds), record
      // the confirmations, apply them immediately, then resync locally.
      const ordered: string[] = [];
      doc.forEach((_n, off) => {
        ordered.push(ids.get(off)!);
      });
      replaceTopLevelIds(ordered, doc);
      confirmBlockIds(desc.mapping);
      applyPendingConfirmations();
      ids = getAllBlockIds();
      recorded.push(desc);
      const snap = snapshotByTid(doc, ids);
      // Confirm never touches the doc, so recentlySplitEmptyIds is unchanged
      // by this step; still read it fresh rather than assuming, since a
      // checker should never have to guess.
      const msg = check({
        doc,
        ids,
        before: snap,
        after: snap,
        op: desc,
        recentlySplitEmptyIdsBefore: getRecentlySplitEmptyIds(),
      });
      if (msg) return { ok: false, ops: recorded, stepIndex: recorded.length - 1, message: msg };
      continue;
    }

    const applied = applyOpDescriptor(doc, desc);
    if (!applied) continue;
    if (applied.tr.doc.content.size > maxDocSize) continue;

    const before = snapshotByTid(doc, ids);
    const recentlySplitEmptyIdsBefore = getRecentlySplitEmptyIds();
    const oldDoc = doc;
    doc = applied.tr.doc;
    const mapping: Mapping = applied.tr.mapping;
    [ids, types] = assignBlockIds(doc, ids, types, oldDoc, mapping);
    const after = snapshotByTid(doc, ids);

    recorded.push(desc);
    const msg = check({ doc, ids, before, after, op: desc, recentlySplitEmptyIdsBefore });
    if (msg) return { ok: false, ops: recorded, stepIndex: recorded.length - 1, message: msg };
  }
  return { ok: true, ops: recorded, stepIndex: -1, message: '' };
}

export interface RunRandomCaseParams {
  seed: number;
  steps: number;
  allowedOps: readonly OpKind[];
  paragraphsOnly: boolean;
  maxDocSize: number;
  check: StepChecker;
}

export type RunResult = { ok: true; case: RecordedCase } | { ok: false; case: RecordedCase; message: string };

export function runRandomCase(params: RunRandomCaseParams): RunResult {
  const rnd = mulberry32(params.seed);
  let tidN = 0;
  const nextTid = () => `ntid-${tidN++}`; // 'n' prefix: never collides with initial 'tid-N' names
  let permN = 0;
  const nextPermId = () => `perm-${permN++}`;

  const initialBlocks = generateInitialBlocks(rnd, { paragraphsOnly: params.paragraphsOnly });
  const result = runEngine(
    initialBlocks,
    (doc, ids) =>
      randomOpDescriptor(doc, ids, {
        rnd,
        allowedOps: params.allowedOps,
        paragraphsOnly: params.paragraphsOnly,
        nextTid,
        nextPermId,
        maxDocSize: params.maxDocSize,
      }),
    params.check,
    params.steps,
    params.maxDocSize
  );

  const recordedCase: RecordedCase = { seed: params.seed, initialBlocks, ops: result.ops };
  if (!result.ok) return { ok: false, case: recordedCase, message: result.message };
  return { ok: true, case: recordedCase };
}

/** Pure, deterministic replay of an EXACT recorded case — no PRNG. Used by the
 * shrinker and by anyone pasting a printed repro into a new test. */
export function replayCase(rc: RecordedCase, check: StepChecker): EngineResult {
  let i = 0;
  return runEngine(
    rc.initialBlocks,
    () => (i < rc.ops.length ? rc.ops[i++] : null),
    check,
    rc.ops.length,
    Number.POSITIVE_INFINITY // a recorded case already passed through generation-time caps once
  );
}

function failureClass(message: string): string {
  return message.split(/[\s:]/)[0];
}

/**
 * Minimal delta-debugging shrinker: given a case that's already known to fail
 * `check` with `originalMessage`, tries to find a smaller case that fails the
 * SAME class of check (same leading token — see `failureClass`). Strategy:
 * (1) drop every op after the first failure (always valid), (2) repeatedly
 * try removing shrinking chunks of ops (ddmin-style), (3) trim now-unused
 * trailing initial blocks. Does not shrink individual op parameters (e.g.
 * text length, delete span) — a reasonable stopping point given this harness's
 * time budget; the op-count reduction alone gets most of the value.
 */
export function shrinkCase(rc: RecordedCase, check: StepChecker, originalMessage: string): RecordedCase {
  const wantClass = failureClass(originalMessage);
  const stillFails = (candidate: RecordedCase): boolean => {
    if (candidate.ops.length === 0) return false;
    const r = replayCase(candidate, check);
    return !r.ok && failureClass(r.message) === wantClass;
  };

  let current = rc;
  const first = replayCase(current, check);
  if (!first.ok) current = { ...current, ops: current.ops.slice(0, first.stepIndex + 1) };

  let chunk = Math.max(1, Math.floor(current.ops.length / 2));
  while (chunk >= 1) {
    let i = 0;
    let progressed = false;
    while (i < current.ops.length) {
      const candidate: RecordedCase = {
        ...current,
        ops: [...current.ops.slice(0, i), ...current.ops.slice(i + chunk)],
      };
      if (stillFails(candidate)) {
        current = candidate;
        progressed = true;
        // stay at i — try the same position again with the shrunken array
      } else {
        i += chunk;
      }
    }
    chunk = progressed ? chunk : Math.floor(chunk / 2);
  }

  while (current.initialBlocks.length > 1) {
    const smaller: RecordedCase = { ...current, initialBlocks: current.initialBlocks.slice(0, -1) };
    if (stillFails(smaller)) current = smaller;
    else break;
  }

  return current;
}

/** Pretty JSON literal of a case — pasteable straight into a new test as a
 * `RecordedCase`, then run through `replayCase(case, checkSafety | checkIdentity)`. */
export function formatRepro(rc: RecordedCase): string {
  return JSON.stringify(rc, null, 2);
}
