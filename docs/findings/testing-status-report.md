# Automated Testing Status Report

Date: 2026-02-11

## Overview

The original plan ("Add Automated Testing to FINAL|FINAL") had 9 steps. Steps 1-8 are fully implemented. Step 9 (golden snapshots) is partially done. However, the XCUITest smoke tests (Step 8) are blocked by a bug where SwiftUI's `WindowGroup` does not create an `NSWindow` when launched via XCUITest.

## Original Plan — Implementation Status

| Step | Feature | Status |
|------|---------|--------|
| 1 | JS `__testSnapshot()` hook in both editors | Fully implemented |
| 2 | `--uitesting` launch argument infrastructure | Fully implemented |
| 3 | Minimal accessibility identifiers (10 total) | Fully implemented |
| 4 | Test fixture factory | Fully implemented |
| 5 | UI test target in project.yml | Fully implemented |
| 6 | Swift test helpers (EditorTestHelper + UITestHelpers) | Fully implemented |
| 7 | Integration tests for JS-Swift bridge (8 tests) | Fully implemented |
| 8 | XCUITest smoke tests (6 tests) | Implemented but blocked by 0-windows bug |
| 9 | Golden snapshot storage + comparison | Partially implemented (fixture gen done, SnapshotStore missing) |

### What's missing from Step 9

- `final finalTests/Helpers/SnapshotStore.swift` — golden snapshot loading + comparison
- `final finalTests/Snapshots/` directory — golden JSON snapshots
- `testMilkdownMatchesGolden` and `testCodeMirrorMatchesGolden` test cases
- `final finalUITests/SnapshotBridgeTests.swift` — 3 tests using temp-file bridge for deeper assertions

## The Blocking Bug: XCUITest 0-Windows

### Symptom

When launched by XCUITest, the app reaches `.runningForeground` (state 4) with a full menu bar, but `WindowGroup` never creates an `NSWindow`. Both `NSApp.windows.count` (app-side) and `app.windows.count` (test-side) report 0.

The app works fine when launched manually.

### What has been ruled out

| Factor | How verified |
|--------|--------------|
| Wrong bundle ID | Verified `com.kerim.final-final` in project.yml, pbxproj, test code |
| Missing accessibility IDs | All 10 identifiers confirmed in source |
| Info.plist window suppression | No `LSUIElement` or `LSBackgroundOnly` |
| EditorPreloader blocking | Preloader skips in test mode |
| `-ApplePersistenceIgnoreState YES` flag | Removed; saved state cleaned manually instead |
| Early `NSApp.activate()` in `applicationWillFinishLaunching` | Removed; still 0 windows |
| Missing `activate()` in test helper | Added back; still 0 windows |

### Variable isolation across 3 test runs

| Variable | Run 1 | Run 2 | Run 3 |
|----------|-------|-------|-------|
| `-ApplePersistenceIgnoreState YES` | YES | NO | NO |
| Early activation in `willFinishLaunching` | YES | YES | NO |
| `activate()` from test helper | YES | NO | YES |
| State cleanup before launch | NO | YES | YES |
| **Result** | 0 windows | 0 windows | 0 windows |

### Open hypotheses (not yet tested)

1. **`.task { await determineInitialState() }` never runs or completes** — The window content starts in `.loading` state. If the async task doesn't fire, the view stays as a `ProgressView` inside a frame, which might not trigger `NSWindow` creation. Needs logging.

2. **Database initialization race** — `AppDelegate.applicationDidFinishLaunching` inits the database. `determineInitialState()` uses `DocumentManager.shared` which may depend on it. If the task runs before the database is ready, it could silently fail.

3. **Missing `NSApp.setActivationPolicy(.regular)`** — We removed this along with `activate()`. Under XCUITest, the app might default to `.accessory` activation policy. Should be tested separately.

4. **SwiftUI scene lifecycle under XCUITest** — `WindowGroup` may behave differently when launched by `XCUIApplication.launch()`. Worth testing with a minimal SwiftUI app.

5. **`@NSApplicationDelegateAdaptor` wiring under test launch** — The adaptor pattern might not fully wire up when XCUITest launches the app.

### Suggested next steps

1. Add logging inside `determineInitialState()` to confirm it runs and which branch it takes
2. Add a delayed `NSApp.windows.count` log in `applicationDidFinishLaunching` to check app-side window creation
3. Test `setActivationPolicy(.regular)` in `applicationDidFinishLaunching` (after scene evaluation) without `activate()`
4. Try a minimal SwiftUI app to isolate whether the bug is general or specific to this app

## Current file state (uncommitted changes from debugging)

| File | Change |
|------|--------|
| `final final/App/AppDelegate.swift` | Early activation block removed from `applicationWillFinishLaunching` |
| `final finalUITests/UITestHelpers.swift` | `activate()` added after `launch()` in both methods |
| `final finalUITests/SmokeTests.swift` | Diagnostic dump code present in `testAppLaunches` |
| `final final/App/FinalFinalApp.swift` | `loadingView` has `.accessibilityIdentifier("loading-view")` |
