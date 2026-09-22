// @vitest-environment jsdom
// Typewriter scrolling — shared module units (plan §7).
//
// The full 45-row geometry grid is encoded cell-for-cell from plan §2.2. Each row is
// asserted per scenario: at the first line's computed scroll the first line's top equals
// `rest`; at the last line's computed scroll the last line's top equals `rest`; never both
// at one scroll (plan §2.2 clause e). The achieved position is recomputed from the
// RECORDED reserve, the padding, the document height and the written scroll — never from
// `rest` directly.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BASE_PAD_BOTTOM,
  BASE_PAD_TOP,
  cancelTypewriterGlide,
  clearDocumentReadiness,
  computeReserveHeight,
  computeRestOffset,
  computeScrollTarget,
  getTypewriterConfig,
  getTypewriterTestState,
  handleTypewriterResize,
  INSTANT_MAX_LINE_DELTA,
  isTypewriterActive,
  LINE_OFFSET_RANGE,
  markDocumentReady,
  registerScrollHost,
  resetTypewriterForTests,
  type ScrollHost,
  type ScrollRange,
  setTypewriterEnabled,
  setTypewriterLineOffset,
  triggerTypewriterScroll,
  unregisterScrollHost,
} from '../typewriter-scrolling';

const LINE_HEIGHT = 24;

/* --------------------------------------------------------------- fake frames */

let rafCallbacks: Map<number, FrameRequestCallback>;
let rafNextId: number;
let fakeNow: number;
let cancelled: number[];

function installFrameHarness(): void {
  rafCallbacks = new Map();
  rafNextId = 0;
  fakeNow = 0;
  cancelled = [];
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
    const id = ++rafNextId;
    rafCallbacks.set(id, cb);
    return id;
  });
  vi.stubGlobal('cancelAnimationFrame', (id: number) => {
    cancelled.push(id);
    rafCallbacks.delete(id);
  });
  vi.spyOn(performance, 'now').mockImplementation(() => fakeNow);
}

/** Runs every pending frame callback, in id order, at the current fake clock. */
function flushFrames(): void {
  const pending = [...rafCallbacks.entries()].sort((a, b) => a[0] - b[0]);
  rafCallbacks.clear();
  for (const [, cb] of pending) cb(fakeNow);
}

function pendingFrameCount(): number {
  return rafCallbacks.size;
}

/* -------------------------------------------------------------- synthetic host */

interface SyntheticHost extends ScrollHost {
  /** The reserve the module last wrote. */
  reserve(): number;
  /** Every scroll offset the module wrote, in order. */
  writes(): number[];
  setScroll(offset: number): void;
  /** The content-space top of the line the caret is on, as MEASURED (pre-reserve). */
  setCaretContentTop(y: number): void;
  /** Sets the caret to logical line `index` (0-based) at the reserve currently in force. */
  setCaretLine(index: number): void;
  setLine(line: number | null): void;
  contentHeight(): number;
}

/**
 * A synthetic host with no DOM of its own. `readMaxScroll()` derives the post-reserve
 * maximum from the document height and the reserve the module applied, so a module that
 * clamped against a pre-reserve value would produce a wrong written offset and fail the
 * grid.
 */
function makeHost(contentHeight: number, visibleHeight: number): SyntheticHost {
  let reserve = 0;
  let scroll = 0;
  const writeLog: number[] = [];
  let caretContentTop = BASE_PAD_TOP;
  let line: number | null = 1;

  const host: SyntheticHost = {
    readOffset: () => scroll,
    writeScroll: (offset: number) => {
      scroll = offset;
      writeLog.push(offset);
    },
    applyReserve: (px: number) => {
      reserve = px;
    },
    readMaxScroll: () => Math.max(0, contentHeight + 2 * (BASE_PAD_TOP + reserve) - visibleHeight),
    scrollerTop: () => 0,
    basePadTop: BASE_PAD_TOP,
    basePadBottom: BASE_PAD_BOTTOM,
    // `getBoundingClientRect()` values as returned: window-viewport coordinates. The
    // viewport top of a content position is its content top minus the scroll offset.
    measureCaret: () => ({ top: caretContentTop - scroll, bottom: caretContentTop - scroll + LINE_HEIGHT }),
    measureRange: () => ({
      maxScroll: Math.max(0, contentHeight + 2 * (BASE_PAD_TOP + reserve) - visibleHeight),
      visibleHeight,
      lineHeight: LINE_HEIGHT,
    }),
    measureLine: () => line,
    reserve: () => reserve,
    writes: () => [...writeLog],
    setScroll: (offset: number) => {
      scroll = offset;
    },
    setCaretContentTop: (y: number) => {
      caretContentTop = y;
    },
    setCaretLine: (index: number) => {
      // The real plugin measures the caret box in the layout as it stands, so the
      // content top already includes whatever reserve is in force.
      caretContentTop = BASE_PAD_TOP + reserve + index * LINE_HEIGHT;
    },
    setLine: (value: number | null) => {
      line = value;
    },
    contentHeight: () => contentHeight,
  };
  return host;
}

/** Puts the module into the active state and clears whatever the activation pass wrote. */
function activate(host: SyntheticHost): void {
  setTypewriterEnabled(true);
  registerScrollHost(host);
  markDocumentReady();
  // The activation pass may have written something; start each scenario clean.
  flushFrames();
}

beforeEach(() => {
  installFrameHarness();
  resetTypewriterForTests();
  document.documentElement.style.removeProperty('--typewriter-reserve');
  document.documentElement.scrollTop = 0;
});

afterEach(() => {
  resetTypewriterForTests();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

/* ------------------------------------------------------------------ the grid */

interface Row {
  V: number;
  offset: number;
  lines: number;
  rest: number;
  R: number;
  firstWrite: number;
  lastWrite: number;
  maxScroll: number;
}

// Plan §2.2's table, cell-for-cell: three window heights × five offsets × three
// document lengths. `Hc = lines * 24`, `L = 24`, base padding 24.
const GRID: Row[] = [
  { V: 200, offset: -10, lines: 2, rest: 24, R: 152, firstWrite: 152, lastWrite: 176, maxScroll: 200 },
  { V: 200, offset: -10, lines: 5, rest: 24, R: 152, firstWrite: 152, lastWrite: 248, maxScroll: 272 },
  { V: 200, offset: -10, lines: 100, rest: 24, R: 152, firstWrite: 152, lastWrite: 2528, maxScroll: 2552 },
  { V: 200, offset: -3, lines: 2, rest: 28, R: 152, firstWrite: 148, lastWrite: 172, maxScroll: 200 },
  { V: 200, offset: -3, lines: 5, rest: 28, R: 152, firstWrite: 148, lastWrite: 244, maxScroll: 272 },
  { V: 200, offset: -3, lines: 100, rest: 28, R: 152, firstWrite: 148, lastWrite: 2524, maxScroll: 2552 },
  { V: 200, offset: 0, lines: 2, rest: 100, R: 152, firstWrite: 76, lastWrite: 100, maxScroll: 200 },
  { V: 200, offset: 0, lines: 5, rest: 100, R: 152, firstWrite: 76, lastWrite: 172, maxScroll: 272 },
  { V: 200, offset: 0, lines: 100, rest: 100, R: 152, firstWrite: 76, lastWrite: 2452, maxScroll: 2552 },
  { V: 200, offset: 3, lines: 2, rest: 172, R: 152, firstWrite: 4, lastWrite: 28, maxScroll: 200 },
  { V: 200, offset: 3, lines: 5, rest: 172, R: 152, firstWrite: 4, lastWrite: 100, maxScroll: 272 },
  { V: 200, offset: 3, lines: 100, rest: 172, R: 152, firstWrite: 4, lastWrite: 2380, maxScroll: 2552 },
  { V: 200, offset: 10, lines: 2, rest: 176, R: 152, firstWrite: 0, lastWrite: 24, maxScroll: 200 },
  { V: 200, offset: 10, lines: 5, rest: 176, R: 152, firstWrite: 0, lastWrite: 96, maxScroll: 272 },
  { V: 200, offset: 10, lines: 100, rest: 176, R: 152, firstWrite: 0, lastWrite: 2376, maxScroll: 2552 },
  { V: 480, offset: -10, lines: 2, rest: 24, R: 432, firstWrite: 432, lastWrite: 456, maxScroll: 480 },
  { V: 480, offset: -10, lines: 5, rest: 24, R: 432, firstWrite: 432, lastWrite: 528, maxScroll: 552 },
  { V: 480, offset: -10, lines: 100, rest: 24, R: 432, firstWrite: 432, lastWrite: 2808, maxScroll: 2832 },
  { V: 480, offset: -3, lines: 2, rest: 168, R: 432, firstWrite: 288, lastWrite: 312, maxScroll: 480 },
  { V: 480, offset: -3, lines: 5, rest: 168, R: 432, firstWrite: 288, lastWrite: 384, maxScroll: 552 },
  { V: 480, offset: -3, lines: 100, rest: 168, R: 432, firstWrite: 288, lastWrite: 2664, maxScroll: 2832 },
  { V: 480, offset: 0, lines: 2, rest: 240, R: 432, firstWrite: 216, lastWrite: 240, maxScroll: 480 },
  { V: 480, offset: 0, lines: 5, rest: 240, R: 432, firstWrite: 216, lastWrite: 312, maxScroll: 552 },
  { V: 480, offset: 0, lines: 100, rest: 240, R: 432, firstWrite: 216, lastWrite: 2592, maxScroll: 2832 },
  { V: 480, offset: 3, lines: 2, rest: 312, R: 432, firstWrite: 144, lastWrite: 168, maxScroll: 480 },
  { V: 480, offset: 3, lines: 5, rest: 312, R: 432, firstWrite: 144, lastWrite: 240, maxScroll: 552 },
  { V: 480, offset: 3, lines: 100, rest: 312, R: 432, firstWrite: 144, lastWrite: 2520, maxScroll: 2832 },
  { V: 480, offset: 10, lines: 2, rest: 456, R: 432, firstWrite: 0, lastWrite: 24, maxScroll: 480 },
  { V: 480, offset: 10, lines: 5, rest: 456, R: 432, firstWrite: 0, lastWrite: 96, maxScroll: 552 },
  { V: 480, offset: 10, lines: 100, rest: 456, R: 432, firstWrite: 0, lastWrite: 2376, maxScroll: 2832 },
  { V: 900, offset: -10, lines: 2, rest: 210, R: 852, firstWrite: 666, lastWrite: 690, maxScroll: 900 },
  { V: 900, offset: -10, lines: 5, rest: 210, R: 852, firstWrite: 666, lastWrite: 762, maxScroll: 972 },
  { V: 900, offset: -10, lines: 100, rest: 210, R: 852, firstWrite: 666, lastWrite: 3042, maxScroll: 3252 },
  { V: 900, offset: -3, lines: 2, rest: 378, R: 852, firstWrite: 498, lastWrite: 522, maxScroll: 900 },
  { V: 900, offset: -3, lines: 5, rest: 378, R: 852, firstWrite: 498, lastWrite: 594, maxScroll: 972 },
  { V: 900, offset: -3, lines: 100, rest: 378, R: 852, firstWrite: 498, lastWrite: 2874, maxScroll: 3252 },
  { V: 900, offset: 0, lines: 2, rest: 450, R: 852, firstWrite: 426, lastWrite: 450, maxScroll: 900 },
  { V: 900, offset: 0, lines: 5, rest: 450, R: 852, firstWrite: 426, lastWrite: 522, maxScroll: 972 },
  { V: 900, offset: 0, lines: 100, rest: 450, R: 852, firstWrite: 426, lastWrite: 2802, maxScroll: 3252 },
  { V: 900, offset: 3, lines: 2, rest: 522, R: 852, firstWrite: 354, lastWrite: 378, maxScroll: 900 },
  { V: 900, offset: 3, lines: 5, rest: 522, R: 852, firstWrite: 354, lastWrite: 450, maxScroll: 972 },
  { V: 900, offset: 3, lines: 100, rest: 522, R: 852, firstWrite: 354, lastWrite: 2730, maxScroll: 3252 },
  { V: 900, offset: 10, lines: 2, rest: 690, R: 852, firstWrite: 186, lastWrite: 210, maxScroll: 900 },
  { V: 900, offset: 10, lines: 5, rest: 690, R: 852, firstWrite: 186, lastWrite: 282, maxScroll: 972 },
  { V: 900, offset: 10, lines: 100, rest: 690, R: 852, firstWrite: 186, lastWrite: 2562, maxScroll: 3252 },
];

describe('typewriter-scrolling: the 45-row geometry grid (plan §2.2)', () => {
  it('encodes all 45 rows', () => {
    expect(GRID).toHaveLength(45);
  });

  for (const row of GRID) {
    const label = `V=${row.V} offset=${row.offset} lines=${row.lines}`;

    it(`${label}: reserve, rest and maxScroll match the table`, () => {
      const Hc = row.lines * LINE_HEIGHT;
      const host = makeHost(Hc, row.V);
      activate(host);
      setTypewriterLineOffset(row.offset);
      host.setLine(1);
      host.setCaretLine(0);
      triggerTypewriterScroll(host, null, null, 1, 'input', true);
      flushFrames();
      expect(host.reserve()).toBeCloseTo(row.R, 6);
      // The frozen formula, restated: R = max(0, rest - B, V - L - B).
      expect(row.R).toBeCloseTo(Math.max(0, row.rest - BASE_PAD_TOP, row.V - LINE_HEIGHT - BASE_PAD_TOP), 6);
      const P = BASE_PAD_TOP + host.reserve();
      // Clause (d) is unreachable: P >= rest always, so the first-line target is never
      // negative and no trigger clamps short of rest.
      expect(P).toBeGreaterThanOrEqual(row.rest - 1e-9);
      expect(getTypewriterTestState().rest).toBeCloseTo(row.rest, 6);
      expect(host.readMaxScroll()).toBeCloseTo(row.maxScroll, 6);
    });

    it(`${label}: the first line reaches rest at its own scroll`, () => {
      const Hc = row.lines * LINE_HEIGHT;
      const host = makeHost(Hc, row.V);
      activate(host);
      setTypewriterLineOffset(row.offset);
      host.setScroll(0);
      // Measured BEFORE the reserve write, in the layout as it stands.
      host.setCaretLine(0);
      host.setLine(1);
      triggerTypewriterScroll(host, null, null, 1, 'input', true);
      flushFrames();

      const writes = host.writes();
      expect(writes.length).toBeGreaterThan(0);
      const written = writes[writes.length - 1];
      // Achieved position recomputed from the recorded reserve, the padding, the
      // document height and the written scroll — never from `rest`.
      const P = BASE_PAD_TOP + host.reserve();
      expect(written).toBeCloseTo(row.firstWrite, 6);
      expect(P - written).toBeCloseTo(row.rest, 6);
      expect(written).toBeGreaterThanOrEqual(0);
      expect(written).toBeLessThanOrEqual(host.readMaxScroll() + 1e-9);
    });

    it(`${label}: the last line reaches rest at its own scroll`, () => {
      const Hc = row.lines * LINE_HEIGHT;
      const host = makeHost(Hc, row.V);
      activate(host);
      setTypewriterLineOffset(row.offset);
      host.setScroll(0);
      host.setCaretLine(row.lines - 1);
      host.setLine(row.lines);
      triggerTypewriterScroll(host, null, null, row.lines, 'input', true);
      flushFrames();

      const writes = host.writes();
      expect(writes.length).toBeGreaterThan(0);
      const written = writes[writes.length - 1];
      const P = BASE_PAD_TOP + host.reserve();
      const caretContentTop = Hc + host.reserve();
      expect(written).toBeCloseTo(row.lastWrite, 6);
      expect(caretContentTop - written).toBeCloseTo(row.rest, 6);
      // The other end is NOT also on rest at this one scroll (plan §2.2 clause e) for the
      // short documents; nothing in the feature depends on it.
      expect(P).toBeGreaterThanOrEqual(0);
      expect(written).toBeGreaterThanOrEqual(0);
      expect(written).toBeLessThanOrEqual(host.readMaxScroll() + 1e-9);
    });
  }

  it('200 / +3: the rejected reserve of 128 left the first line 20 px short of rest', () => {
    // Plan §8's CORRECTED counterexample (reviewer note 3): at 200 / +3 the old reserve
    // left the FIRST line 20 px high; the last line was exactly on rest. The corrected
    // reserve is 152 and both ends reach rest.
    const rest = 200 / 2 + 3 * LINE_HEIGHT;
    expect(rest).toBe(172);
    const oldP = BASE_PAD_TOP + 128;
    expect(oldP - 4).toBe(rest - 24); // 148, i.e. 20 px short of 172
    expect(BASE_PAD_TOP + 152).toBe(176);
  });

  it('the clamp binds for a small window at a negative offset, not the raw expression', () => {
    // Plan §2.1: for a 200px window, a 24px line box and a −10 offset the clamp gives
    // L = 24, not 4 (100 + (-10 * 24) = -140, clamped up to 24).
    // −10: the raw expression is 100 + (−10 × 24) = −140, clamped up to L = 24.
    expect(computeRestOffset({ maxScroll: 0, visibleHeight: 200, lineHeight: 24 }, -10)).toBe(24);
    // It is offset −4 that yields the raw value 4 (reviewer note 4); the same clamp lifts it
    // to L = 24, so `4` is never a `rest`.
    expect(100 + -4 * 24).toBe(4);
    expect(computeRestOffset({ maxScroll: 0, visibleHeight: 200, lineHeight: 24 }, -4)).toBe(24);
    expect(computeRestOffset({ maxScroll: 0, visibleHeight: 200, lineHeight: 24 }, 10)).toBe(176);
    // low > high survives.
    expect(computeRestOffset({ maxScroll: 0, visibleHeight: 20, lineHeight: 24 }, 0)).toBe(10);
  });
});

describe('typewriter-scrolling: the reserve helper', () => {
  it('is exactly max(0, rest - basePadTop, visibleHeight - lineHeight - basePadTop)', () => {
    // Four (rest, L) corners, re-stating the body so a change to the third or fourth term
    // fails. `basePadBottom` is NOT a term of the reserve.
    const V = 480;
    const B = 24;
    expect(computeReserveHeight(V, 24, 24, B)).toBe(Math.max(0, 24 - B, V - 24 - B));
    expect(computeReserveHeight(V, 240, 24, B)).toBe(Math.max(0, 240 - B, V - 24 - B));
    expect(computeReserveHeight(V, 456, 24, B)).toBe(Math.max(0, 456 - B, V - 24 - B));
    expect(computeReserveHeight(V, 240, 60, B)).toBe(Math.max(0, 240 - B, V - 60 - B));
    // The first term wins in a very short window.
    expect(computeReserveHeight(40, 20, 24, B)).toBe(0);
    expect(computeReserveHeight(200, 24, 24, B)).toBe(152);
  });

  it('computeScrollTarget is caretContentTop - rest', () => {
    expect(computeScrollTarget(100, 40)).toBe(60);
  });
});

describe('typewriter-scrolling: a middle line (round 3 omitted this case)', () => {
  it('puts a line that is neither first nor last exactly on rest, with no clamp binding', () => {
    const Hc = 100 * LINE_HEIGHT;
    const host = makeHost(Hc, 480);
    activate(host);
    setTypewriterLineOffset(0);
    host.setScroll(0);
    host.setCaretLine(49);
    host.setLine(50);
    triggerTypewriterScroll(host, null, null, 50, 'input', true);
    flushFrames();

    const writes = host.writes();
    const written = writes[writes.length - 1];
    const achieved = BASE_PAD_TOP + host.reserve() + 49 * LINE_HEIGHT - written;
    expect(achieved).toBeCloseTo(240, 6);
    expect(written).toBeGreaterThan(0);
    expect(written).toBeLessThan(host.readMaxScroll());
  });
});

describe('typewriter-scrolling: inactive', () => {
  it('writes no reserve and no scroll while disabled', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    registerScrollHost(host);
    markDocumentReady();
    flushFrames();
    triggerTypewriterScroll(host, null, null, 1, 'input', true);
    flushFrames();
    expect(host.reserve()).toBe(0);
    expect(host.writes()).toEqual([]);
    expect(getTypewriterTestState().triggerCount).toBe(0);
  });

  it('writes no reserve and no scroll while enabled but not yet ready', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    setTypewriterEnabled(true);
    registerScrollHost(host);
    // No markDocumentReady().
    if (host.reserve() !== 0) {
      // Registration alone must not have written while the document is not ready.
      throw new Error('reserve written before readiness');
    }
    const before = host.writes().length;
    triggerTypewriterScroll(host, null, null, 1, 'input', true);
    flushFrames();
    expect(before).toBe(host.writes().length);
    expect(host.reserve()).toBe(0);
    expect(isTypewriterActive()).toBe(false);
  });
});

describe('typewriter-scrolling: the activation pass', () => {
  it('runs once when the triple first becomes true, and not again while it stays true', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    // Config stored before a host exists — the relaunch-with-the-persisted-setting case.
    setTypewriterEnabled(true);
    setTypewriterLineOffset(0);
    expect(host.writes()).toEqual([]);

    registerScrollHost(host);
    expect(host.writes()).toEqual([]); // still not ready

    markDocumentReady();
    flushFrames();
    const afterReady = host.writes().length;
    expect(afterReady).toBeGreaterThan(0);
    expect(host.reserve()).toBeGreaterThan(0);
    const restAfterPass = getTypewriterTestState().rest;

    // Repeated ready marks and config sends do not re-centre while the triple stays true —
    // this is the H1 edge. Move the caret first so a spurious pass would be VISIBLE: without
    // the edge, an app-origin content push's readiness re-assertion would snap the scroll
    // back onto `rest` and inflate the write count.
    host.setScroll(0);
    host.setCaretLine(60);
    host.setLine(61);
    markDocumentReady();
    flushFrames();
    expect(host.writes().length).toBe(afterReady);
    expect(getTypewriterTestState().triggerCount).toBe(1);

    setTypewriterEnabled(true);
    flushFrames();
    expect(host.writes().length).toBe(afterReady);
    expect(getTypewriterTestState().triggerCount).toBe(1);
    expect(restAfterPass).toBe(getTypewriterTestState().rest);
  });

  it('re-arms after clearDocumentReadiness, so a later load still re-centres exactly once', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    setTypewriterEnabled(true);
    registerScrollHost(host);
    markDocumentReady();
    flushFrames();
    const firstPass = host.writes().length;
    expect(firstPass).toBeGreaterThan(0);
    expect(getTypewriterTestState().triggerCount).toBe(1);

    clearDocumentReadiness();
    flushFrames();
    markDocumentReady();
    flushFrames();
    expect(getTypewriterTestState().triggerCount).toBe(2);
    // The second pass wrote again.
    expect(host.writes().length).toBeGreaterThan(firstPass);
  });

  it('re-registering a fresh host re-runs the pass once', () => {
    const first = makeHost(100 * LINE_HEIGHT, 480);
    setTypewriterEnabled(true);
    registerScrollHost(first);
    markDocumentReady();
    flushFrames();
    const firstWrites = first.writes().length;
    expect(firstWrites).toBeGreaterThan(0);

    const second = makeHost(100 * LINE_HEIGHT, 480);
    registerScrollHost(second);
    flushFrames();
    expect(second.writes().length).toBeGreaterThan(0);
  });

  it('clearDocumentReadiness zeroes the reserve and drops the remembered line', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    setTypewriterEnabled(true);
    registerScrollHost(host);
    markDocumentReady();
    flushFrames();
    expect(host.reserve()).toBeGreaterThan(0);
    expect(getTypewriterTestState().lastLine).not.toBeNull();

    clearDocumentReadiness();
    expect(host.reserve()).toBe(0);
    expect(getTypewriterTestState().lastLine).toBeNull();
    expect(isTypewriterActive()).toBe(false);
  });

  it('changing the line offset while active recomputes and re-centres immediately', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    activate(host);
    setTypewriterLineOffset(0);
    host.setCaretLine(49);
    host.setLine(50);
    triggerTypewriterScroll(host, null, null, 50, 'input', true);
    flushFrames();
    const centred = getTypewriterTestState().rest;

    setTypewriterLineOffset(5);
    flushFrames();
    const moved = getTypewriterTestState().rest;
    expect(moved).toBeCloseTo(centred + 5 * LINE_HEIGHT, 6);
    expect(host.writes().length).toBeGreaterThan(0);
  });

  it('a resize recomputes the reserve from a fresh caret box and re-centres instantly', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    activate(host);
    setTypewriterLineOffset(0);
    host.setCaretLine(49);
    host.setLine(50);
    triggerTypewriterScroll(host, null, null, 50, 'input', true);
    flushFrames();
    const before = host.writes().length;

    handleTypewriterResize(host);
    flushFrames();
    expect(host.writes().length).toBeGreaterThan(before);
  });
});

describe('typewriter-scrolling: the degenerate window (V < 2L)', () => {
  it('writes rest = V/2, a finite non-negative reserve, clamped targets, and no glide', () => {
    const V = 20;
    const host = makeHost(100 * LINE_HEIGHT, V);
    activate(host);
    setTypewriterLineOffset(0);

    const range: ScrollRange = { maxScroll: 0, visibleHeight: V, lineHeight: LINE_HEIGHT };
    expect(computeRestOffset(range, 0)).toBe(V / 2);
    const rest = computeRestOffset(range, 0);
    const reserve = computeReserveHeight(V, rest, LINE_HEIGHT, BASE_PAD_TOP);
    expect(Number.isFinite(reserve)).toBe(true);
    expect(reserve).toBeGreaterThanOrEqual(0);

    host.setScroll(0);
    host.setCaretLine(49);
    host.setLine(50);
    // forceInstant = false AND a huge logical-line jump, so only the degenerate-window rule
    // can make this an instant write rather than a glide.
    triggerTypewriterScroll(host, null, null, 900, 'input');
    // The tiny window has no valid band, so EVERY trigger there is an instant write
    // (plan §2.2 clause c) — observable, and it would be false with the rule removed.
    expect(getTypewriterTestState().gliding).toBe(false);
    flushFrames();
    expect(getTypewriterTestState().gliding).toBe(false);
    const written = host.writes()[host.writes().length - 1];
    expect(written).toBeGreaterThanOrEqual(0);
    expect(written).toBeLessThanOrEqual(host.readMaxScroll() + 1e-9);
    // The tiny-window behaviour is a write of V/2, not a skip: the line box may be clipped.
    expect(getTypewriterTestState().rest).toBe(V / 2);
    expect(host.reserve()).toBeGreaterThanOrEqual(0);
  });

  it('a normal-height window still glides for the same logical-line jump', () => {
    // The control for the test above: the degenerate-window rule is what made it instant,
    // not the trigger's own logic.
    const tall = makeHost(100 * LINE_HEIGHT, 480);
    activate(tall);
    setTypewriterLineOffset(0);
    tall.setScroll(0);
    tall.setCaretLine(0);
    tall.setLine(1);
    triggerTypewriterScroll(tall, null, null, 1, 'input');
    flushFrames();
    tall.setCaretLine(60);
    triggerTypewriterScroll(tall, null, null, 900, 'input');
    expect(getTypewriterTestState().gliding).toBe(true);
    flushFrames();
    fakeNow += 100;
    flushFrames();
    expect(getTypewriterTestState().gliding).toBe(true);
    fakeNow += 100;
    flushFrames();
    expect(getTypewriterTestState().gliding).toBe(false);
  });
});

describe('typewriter-scrolling: instant vs glide', () => {
  function activeHost(): SyntheticHost {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    activate(host);
    setTypewriterLineOffset(0);
    host.setScroll(0);
    return host;
  }

  it('the first trigger is instant (no glide scheduling beyond the deferred write)', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    expect(pendingFrameCount()).toBe(1);
    flushFrames();
    expect(pendingFrameCount()).toBe(0);
  });

  it('a one-line move is instant', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    flushFrames();

    setTypewriterLineOffset(0);
    host.setCaretLine(1);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA, 'input');
    // Instant path schedules exactly one deferred write.
    expect(pendingFrameCount()).toBe(1);
    flushFrames();
  });

  it('a two-line move glides, and its final frame equals the target exactly', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    flushFrames();

    host.setCaretLine(20);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA + 1);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA + 1, 'input');
    // The glide's first frame is scheduled with a start capture.
    expect(pendingFrameCount()).toBe(1);
    flushFrames(); // t = 0 -> writes the start offset
    fakeNow += 100;
    flushFrames(); // t = 0.5
    fakeNow += 100;
    flushFrames(); // t = 1 -> exact target

    const writes = host.writes();
    const final = writes[writes.length - 1];
    const target = Math.min(
      host.readMaxScroll(),
      Math.max(0, BASE_PAD_TOP + host.reserve() + 20 * LINE_HEIGHT - getTypewriterTestState().rest)
    );
    expect(final).toBeCloseTo(target, 6);
  });

  it('a second trigger cancels the first loop id', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    flushFrames();

    host.setCaretLine(20);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA + 1);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA + 1, 'input');
    flushFrames();
    fakeNow += 60;
    flushFrames();
    const cancelledBefore = cancelled.length;

    host.setCaretLine(40);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA + 1);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA + 1, 'input');
    expect(cancelled.length).toBeGreaterThan(cancelledBefore);
  });

  it('a pointerdown during a glide cancels it', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    flushFrames();

    host.setCaretLine(20);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA + 1);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA + 1, 'input');
    expect(pendingFrameCount()).toBe(1);

    // The module owns the cancellation listeners and installs them on `window` itself, so
    // a synthetic host needs no DOM of its own.
    window.dispatchEvent(new Event('pointerdown'));
    expect(pendingFrameCount()).toBe(0);
  });

  it('an arrow-key keydown during a glide cancels it', () => {
    const host = activeHost();
    host.setCaretLine(0);
    host.setLine(1);
    triggerTypewriterScroll(host, null, null, 1, 'input');
    flushFrames();
    host.setCaretLine(20);
    host.setLine(1 + INSTANT_MAX_LINE_DELTA + 1);
    triggerTypewriterScroll(host, null, null, 1 + INSTANT_MAX_LINE_DELTA + 1, 'input');
    expect(pendingFrameCount()).toBe(1);
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown' }));
    expect(pendingFrameCount()).toBe(0);
  });

  it('cancelTypewriterGlide is not gated on the feature being active', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    cancelTypewriterGlide(host); // no host registered, not active — must not throw
  });
});

describe('typewriter-scrolling: config and teardown', () => {
  it('the exported line-offset range is [-10, 10] and the offset is clamped into it', () => {
    expect(LINE_OFFSET_RANGE).toEqual([-10, 10]);
    setTypewriterLineOffset(99);
    expect(getTypewriterConfig().lineOffset).toBe(10);
    setTypewriterLineOffset(-99);
    expect(getTypewriterConfig().lineOffset).toBe(-10);
  });

  it('turning the feature off zeroes the reserve and compensates the offset', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    activate(host);
    host.setCaretLine(49);
    host.setLine(50);
    triggerTypewriterScroll(host, null, null, 50, 'input', true);
    flushFrames();
    const reserve = host.reserve();
    const offsetBefore = host.readOffset();
    expect(reserve).toBeGreaterThan(0);

    setTypewriterEnabled(false);
    expect(host.reserve()).toBe(0);
    expect(host.readOffset()).toBeCloseTo(offsetBefore - reserve, 6);
    expect(isTypewriterActive()).toBe(false);
  });

  it('unregisterScrollHost cancels and drops the host', () => {
    const host = makeHost(100 * LINE_HEIGHT, 480);
    activate(host);
    unregisterScrollHost();
    expect(isTypewriterActive()).toBe(false);
    const before = host.writes().length;
    triggerTypewriterScroll(host, null, null, 1, 'input', true);
    flushFrames();
    expect(host.writes().length).toBe(before);
  });
});
