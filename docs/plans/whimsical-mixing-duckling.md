# Plan: Zotero Connection Failure — NSAlert (v02)

## Context

The toast notification implemented in v01 was too subtle (hard to see, disappears too quickly, looks different from the existing `/cite` failure alert). The user wants the same NSAlert that the CAYW picker already shows: **"Zotero Not Running" / "Zotero is not running. Please open Zotero and try again."**

This is a simplification: replace the SwiftUI toast infrastructure with direct `showZoteroAlert()` calls from the coordinator catch blocks. A 60-second cooldown prevents repeated modal alerts from lazy resolution retries.

## Changes

### 1. Roll back toast infrastructure (revert v01 additions)

**Remove from `EditorViewState+Types.swift`:**
- Delete the `.zoteroConnectionFailed` notification name

**Remove from `EditorViewState.swift`:**
- Delete `showZoteroToast`, `lastZoteroToastTime`, `showZoteroToastIfNeeded()`
- Delete `showZoteroToast = false` from `resetForProjectSwitch()`

**Remove from `ContentView.swift`:**
- Delete the `ZoteroToast` struct
- Delete the `.overlay` for `ZoteroToast`
- Delete the `.onReceive` for `.zoteroConnectionFailed`

### 2. Add cooldown to coordinator — `MilkdownCoordinator+MessageHandlers.swift`

Add a static cooldown property (static so it's shared across coordinator instances and survives editor switches):

```swift
/// Cooldown: last time the Zotero alert was shown (prevents spam from repeated resolution failures)
private static var lastZoteroAlertTime: Date = .distantPast
```

Add a cooldown-guarded wrapper alongside the existing `showZoteroAlert`:

```swift
/// Show the Zotero "not running" alert if cooldown (60s) has elapsed.
/// Uses the same NSAlert as the CAYW picker path for consistency.
private func showZoteroAlertIfNeeded() {
    let now = Date()
    guard now.timeIntervalSince(Self.lastZoteroAlertTime) >= 60 else { return }
    Self.lastZoteroAlertTime = now
    showZoteroAlert(
        title: "Zotero Not Running",
        message: "Zotero is not running. Please open Zotero and try again."
    )
}
```

### 3. Call alert from catch blocks — `MilkdownCoordinator+MessageHandlers.swift`

**`handleCitationSearch`** — replace `NotificationCenter.default.post(...)` calls with `showZoteroAlertIfNeeded()`:

```swift
} catch ZoteroError.notRunning {
    print("[MilkdownEditor] Citation search: Zotero not running")
    showZoteroAlertIfNeeded()
    sendCitationSearchCallback(webView: webView, json: "[]")
} catch ZoteroError.networkError(_) {
    print("[MilkdownEditor] Citation search: network error")
    showZoteroAlertIfNeeded()
    sendCitationSearchCallback(webView: webView, json: "[]")
} catch ZoteroError.noResponse {
    print("[MilkdownEditor] Citation search: no response")
    showZoteroAlertIfNeeded()
    sendCitationSearchCallback(webView: webView, json: "[]")
} catch {
    print("[MilkdownEditor] Citation search error: \(error.localizedDescription)")
    sendCitationSearchCallback(webView: webView, json: "[]")
}
```

**`handleResolveCitekeys`** — replace `NotificationCenter.default.post(...)` with `showZoteroAlertIfNeeded()` (keep ping guard):

```swift
} catch ZoteroError.notRunning {
    print("[MilkdownEditor] Zotero not running - cannot resolve citekeys")
    let actuallyDown = !(await ZoteroService.shared.ping())
    if actuallyDown {
        showZoteroAlertIfNeeded()
    }
} catch {
    print("[MilkdownEditor] Failed to resolve citekeys: \(error.localizedDescription)")
    showZoteroAlertIfNeeded()
}
```

## Files to modify

| File | Change |
|------|--------|
| `final final/ViewState/EditorViewState+Types.swift` | Remove `.zoteroConnectionFailed` |
| `final final/ViewState/EditorViewState.swift` | Remove toast state + cooldown + reset |
| `final final/Views/ContentView.swift` | Remove `ZoteroToast`, overlay, `.onReceive` |
| `final final/Editors/MilkdownCoordinator+MessageHandlers.swift` | Add static cooldown + `showZoteroAlertIfNeeded()`, update catch blocks |

## Verification

1. Quit Zotero, add a new uncached citekey (e.g. `[@ferrerPostimperialPluralistNationalism2023]`) → NSAlert appears identical to `/cite` failure
2. Click OK, wait — alert does NOT reappear for 60 seconds
3. After 60s cooldown, trigger again → alert reappears
4. Open Zotero, add same citekey → no alert, citation resolves
5. `/cite` with Zotero closed → still shows its own NSAlert (unchanged)
6. Open empty document with Zotero closed → no alert
7. Open document with only cached citations + Zotero closed → no alert (nothing to resolve)
