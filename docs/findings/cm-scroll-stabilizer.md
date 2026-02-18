# CM6 Post-Scroll Height Drift

Fix for persistent blank/white gaps after rapid scrolling in CodeMirror source mode.

**Status:** Fixed (Phase A only; Phases B and C not needed)
**File:** `web/codemirror/src/scroll-stabilizer.ts`
**Prerequisite:** Requires `line-height-fix.ts` (Phase 1/1b/2) for correct base metrics

---

## Symptoms

- Rapid scrolling (trackpad flick top-to-bottom or bottom-to-top) left blank gaps where content should be
- Quick direction reversals (down fast, immediately up) produced persistent white bands
- Sidebar click to mid-document followed by rapid scroll showed gaps
- Gaps sometimes persisted until scrolling back to the top and down again slowly
- Only visible in documents with 50+ sections and mixed heading levels (H1-H3)

## Root Cause

CM6's virtual renderer can't complete enough measurement cycles during rapid scrolling. Height estimates change as new content is measured, but the viewport isn't re-verified after scrolling stops. The `line-height-fix.ts` patches corrected the *accuracy* of height estimates (Phase 1: lineHeight, Phase 1b: charWidth, Phase 2: heading-aware gaps), but CM6 still needs time to *apply* those corrected estimates to the viewport layout.

The core issue is timing: during fast scroll, CM6 lazily measures rendered content and updates its height map. When scrolling stops abruptly, the height map may have accumulated drift from stale estimates that haven't been reconciled with actual measurements.

## Investigation

### Approaches considered

| Approach | Outcome |
|----------|---------|
| `dispatch({})` after scroll | Too heavy — triggers full update cycle on all plugins, risks "update during update" errors |
| Fixed count of trailing `requestMeasure()` | Wasteful for short scrolls, insufficient for long scrolls |
| Scroll position manipulation (`scrollTop`) | Fights CM6's internal scroll anchoring; gaps (not jumps) are the symptom |
| Adaptive `requestMeasure({ read, write })` | Correct — self-terminates when heights stabilize |

### Why `requestMeasure()` is the right primitive

- Lightweight (no-op if heights unchanged)
- Documented CM6 API for requesting height re-verification
- Doesn't trigger plugin update cycles
- Lets CM6 reconcile its internal height map with actual DOM measurements

## The Fix

A `ViewPlugin` that debounces scroll events and triggers adaptive measurement cycles after scrolling stops.

### Mechanism

1. Scroll listener (`{ passive: true }`) resets a 120ms debounce timer on every scroll event
2. After 120ms of no scrolling, triggers `view.requestMeasure({ read, write })`
3. `read` captures `contentDOM.getBoundingClientRect().height`
4. `write` compares against last known height — if delta > 5px, schedules another round via `requestAnimationFrame`
5. Chain self-terminates when heights stabilize (delta <= 5px) or after 4 rounds (safety cap)
6. If user scrolls again during the chain, the chain is cancelled and debounce restarts

### Timing constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `DEBOUNCE_DELAY` | 120ms | Delay after last scroll event before measurement |
| `HEIGHT_EPSILON` | 5px | Threshold for "heights changed meaningfully" |
| `MAX_STABILIZE_ROUNDS` | 4 | Safety cap on measurement chain |

### Observed behavior (from debug logs)

Typical stabilization takes 2 rounds: the first `requestMeasure()` triggers CM6 to reconcile its height map, producing a height change (deltas of 50-4100px observed). The second round confirms heights are stable (delta 0px).

```
[scroll-stabilizer] scroll idle, starting stabilization
[scroll-stabilizer] round 0: height=4105.0, delta=4105.0
[scroll-stabilizer] round 1: height=4105.0, delta=0.0
[scroll-stabilizer] stable after 2 round(s)
```

The large delta in round 0 reflects CM6 correcting its viewport height estimates, not actual content changes. The 5px epsilon prevents false positives from sub-pixel rendering differences.

## Phases B and C: Not Needed

The plan included two additional phases if Phase A proved insufficient:

- **Phase B:** Throttled measurement every ~150ms during active scrolling
- **Phase C:** Direction-change detection with immediate measurement on reversal

Testing confirmed Phase A alone resolves all gap scenarios (rapid scroll, direction reversals, sidebar jumps). Phases B and C were not implemented.

## Key Files

| File | Change |
|------|--------|
| `web/codemirror/src/scroll-stabilizer.ts` | ViewPlugin with adaptive post-scroll measurement |
| `web/codemirror/src/main.ts` | Import + register in extensions array (after `focusModePlugin`) |

## Design Decisions

**Why ViewPlugin over domEventHandlers?** Needs `destroy()` for cleanup (remove listener, clear timers, cancel rAF) and internal state across scroll events.

**Why `{ passive: true }` scroll listener?** Browser doesn't wait for JS before scrolling — no jank introduced.

**Why adaptive rounds instead of fixed count?** Documents vary in size. A short document may need 0 rounds; a 50+ section document may need 2. The adaptive approach handles both without wasting cycles.

**Why cancel chain on new scroll?** If the user scrolls again during stabilization, the in-progress measurements are stale. Better to restart the debounce and stabilize from the new position.

## Debug Support

Enable logging in Web Inspector console:

```javascript
window.__FF_SCROLL_DEBUG__ = true
```

Shows stabilization triggers, round counts, and height deltas.

## See Also

- [cm-scroll-height-contamination.md](cm-scroll-height-contamination.md) -- The prerequisite fix for height estimation accuracy
- [codemirror.md](../lessons/codemirror.md) -- "Post-Scroll Height Drift" lesson
