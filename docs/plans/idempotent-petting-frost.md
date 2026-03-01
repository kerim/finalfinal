# Plan: Fix "Export Preferences..." Menu Item

## Context

The "Export Preferences..." menu item in the File > Export menu doesn't open the Settings window. The current implementation posts a `.showExportPreferences` notification, which AppDelegate receives and tries to open via `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil))` — a private selector that doesn't reliably work. Additionally, the Settings window may not come to front when the app is in fullscreen mode.

Since the app targets **macOS 26+**, the fix is to use `@Environment(\.openSettings)` — the officially supported SwiftUI API for opening the Settings scene programmatically (available since macOS 14).

---

## Changes

### 1. Add `OpenExportPreferencesModifier` — `final final/App/FinalFinalApp.swift`

Create a small `ViewModifier` that holds `@Environment(\.openSettings)` and listens for the notification:

```swift
private struct OpenExportPreferencesModifier: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showExportPreferences)) { _ in
                openSettings()
                // Ensure window comes to front (e.g., when main window is fullscreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate()
                }
            }
    }
}
```

Apply it to the root `Group` in the `WindowGroup` body (alongside the existing `.onReceive` modifiers):

```swift
.modifier(OpenExportPreferencesModifier())
```

### 2. Remove old handler — `final final/App/AppDelegate.swift`

Delete lines 121–129 (the `NotificationCenter` observer for `.showExportPreferences` that uses the private `showSettingsWindow:` selector).

### 3. Keep tab-switching — `final final/Views/Preferences/PreferencesView.swift`

The `.onReceive(.showExportPreferences)` modifier already added to `PreferencesView` ensures the Export tab is selected when opening from this menu item. No further change needed.

---

## Verification

1. Click File > Export > Export Preferences... — Settings window should open on the Export tab
2. Switch to a different Settings tab (e.g., Appearance), close Settings, then click Export Preferences... again — should open on Export tab
3. Enter fullscreen mode, then click Export Preferences... — Settings window should appear and come to front
4. Open Settings via the app menu (final final > Settings...) — should still work as before
