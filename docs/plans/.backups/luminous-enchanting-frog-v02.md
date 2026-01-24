# Phase 1.3 Theme System Implementation Plan (v02)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a theme system with multiple color schemes, theme switching, CSS variable injection for web editors, and persistence.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, GRDB 7.x

---

## Architecture Decisions

### Theme State Management
- `ThemeManager` @Observable class with static shared instance
- Theme persisted via app database `settings` table
- SwiftUI views consume theme via `@Environment`

### Web Editor Integration
- CSS variables injected via `window.FinalFinal.setTheme()` JavaScript API
- Editors use CSS custom properties for all themeable colors

### Available Themes
1. Light (system default)
2. Dark
3. Sepia (warm, paper-like)
4. Solarized Light
5. Solarized Dark

---

## Task 1: Add Settings CRUD to AppDatabase

**File:** `final final/Models/Database.swift` (modify)

**Step 1:** Add settings CRUD methods after the recent projects extension

```swift
// MARK: - AppDatabase Settings

extension AppDatabase {
    func getSetting(key: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    func setSetting(key: String, value: String) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    func deleteSetting(key: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
    }
}
```

**Verification:** Build succeeds

---

## Task 2: Extend AppColorScheme with CSS Variables and New Themes

**File:** `final final/Theme/ColorScheme.swift` (replace entire file)

**Step 1:** Replace with complete implementation

```swift
//
//  ColorScheme.swift
//  final final
//

import SwiftUI

struct AppColorScheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sidebarBackground: Color
    let sidebarText: Color
    let sidebarSelectedBackground: Color
    let editorBackground: Color
    let editorText: Color
    let editorSelection: Color
    let accentColor: Color
    let dividerColor: Color

    /// Generates CSS custom properties string for web editor injection
    var cssVariables: String {
        """
        --editor-bg: \(editorBackground.cssHex);
        --editor-text: \(editorText.cssHex);
        --editor-selection: \(editorSelection.cssHexWithAlpha);
        --accent-color: \(accentColor.cssHex);
        --sidebar-bg: \(sidebarBackground.cssHex);
        --sidebar-text: \(sidebarText.cssHex);
        --divider-color: \(dividerColor.cssHex);
        """
    }
}

// MARK: - Color CSS Hex Extension

extension Color {
    /// Converts Color to CSS hex string (e.g., "#FF5500")
    var cssHex: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        return String(format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }

    /// Converts Color to CSS rgba string for colors with alpha
    var cssHexWithAlpha: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
            return "rgba(0,0,0,0.3)"
        }
        let alpha = rgb.alphaComponent
        if alpha >= 0.99 {
            return cssHex
        }
        return String(format: "rgba(%d,%d,%d,%.2f)",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255),
            alpha
        )
    }
}

// MARK: - Theme Presets

extension AppColorScheme {
    static let light = AppColorScheme(
        id: "light",
        name: "Light",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.2),
        editorBackground: Color.white,
        editorText: Color.black,
        editorSelection: Color.accentColor.opacity(0.3),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let dark = AppColorScheme(
        id: "dark",
        name: "Dark",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.3),
        editorBackground: Color(white: 0.15),
        editorText: Color.white,
        editorSelection: Color.accentColor.opacity(0.4),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let sepia = AppColorScheme(
        id: "sepia",
        name: "Sepia",
        sidebarBackground: Color(red: 0.96, green: 0.94, blue: 0.89),
        sidebarText: Color(red: 0.35, green: 0.30, blue: 0.25),
        sidebarSelectedBackground: Color(red: 0.85, green: 0.80, blue: 0.70),
        editorBackground: Color(red: 0.98, green: 0.96, blue: 0.91),
        editorText: Color(red: 0.35, green: 0.30, blue: 0.25),
        editorSelection: Color(red: 0.85, green: 0.80, blue: 0.70).opacity(0.5),
        accentColor: Color(red: 0.65, green: 0.45, blue: 0.20),
        dividerColor: Color(red: 0.80, green: 0.75, blue: 0.65)
    )

    static let solarizedLight = AppColorScheme(
        id: "solarized-light",
        name: "Solarized Light",
        sidebarBackground: Color(red: 0.99, green: 0.96, blue: 0.89),  // base3
        sidebarText: Color(red: 0.40, green: 0.48, blue: 0.51),        // base00
        sidebarSelectedBackground: Color(red: 0.93, green: 0.91, blue: 0.84),
        editorBackground: Color(red: 0.99, green: 0.96, blue: 0.89),
        editorText: Color(red: 0.40, green: 0.48, blue: 0.51),
        editorSelection: Color(red: 0.93, green: 0.91, blue: 0.84),
        accentColor: Color(red: 0.15, green: 0.55, blue: 0.82),        // blue
        dividerColor: Color(red: 0.93, green: 0.91, blue: 0.84)
    )

    static let solarizedDark = AppColorScheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        sidebarBackground: Color(red: 0.00, green: 0.17, blue: 0.21),  // base03
        sidebarText: Color(red: 0.51, green: 0.58, blue: 0.59),        // base0
        sidebarSelectedBackground: Color(red: 0.03, green: 0.21, blue: 0.26),
        editorBackground: Color(red: 0.00, green: 0.17, blue: 0.21),
        editorText: Color(red: 0.51, green: 0.58, blue: 0.59),
        editorSelection: Color(red: 0.03, green: 0.21, blue: 0.26),
        accentColor: Color(red: 0.15, green: 0.55, blue: 0.82),
        dividerColor: Color(red: 0.03, green: 0.21, blue: 0.26)
    )

    static let all: [AppColorScheme] = [.light, .dark, .sepia, .solarizedLight, .solarizedDark]
}
```

**Verification:** Build succeeds

---

## Task 3: Create ThemeManager

**File:** `final final/Theme/ThemeManager.swift` (new)

**Step 1:** Create ThemeManager.swift

```swift
//
//  ThemeManager.swift
//  final final
//

import SwiftUI

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var currentTheme: AppColorScheme = .light

    private let settingsKey = "selectedThemeId"

    private init() {
        loadThemeFromDatabase()
    }

    func setTheme(_ theme: AppColorScheme) {
        currentTheme = theme
        saveThemeToDatabase()
        print("[ThemeManager] Theme changed to: \(theme.name)")
    }

    func setTheme(byId id: String) {
        if let theme = AppColorScheme.all.first(where: { $0.id == id }) {
            setTheme(theme)
        }
    }

    /// Returns CSS variables string for web editor injection
    var cssVariables: String {
        currentTheme.cssVariables
    }

    // MARK: - Persistence

    private func loadThemeFromDatabase() {
        guard let database = AppDelegate.shared?.database else {
            print("[ThemeManager] Database not available, using default theme")
            return
        }

        do {
            if let savedId = try database.getSetting(key: settingsKey),
               let theme = AppColorScheme.all.first(where: { $0.id == savedId }) {
                currentTheme = theme
                print("[ThemeManager] Loaded theme: \(theme.name)")
            } else {
                print("[ThemeManager] No saved theme, using default")
            }
        } catch {
            print("[ThemeManager] Failed to load theme: \(error)")
        }
    }

    private func saveThemeToDatabase() {
        guard let database = AppDelegate.shared?.database else {
            print("[ThemeManager] Database not available, cannot save theme")
            return
        }

        do {
            try database.setSetting(key: settingsKey, value: currentTheme.id)
            print("[ThemeManager] Saved theme: \(currentTheme.name)")
        } catch {
            print("[ThemeManager] Failed to save theme: \(error)")
        }
    }
}
```

**Verification:** Build succeeds

---

## Task 4: Create Theme Menu Commands

**File:** `final final/Commands/ThemeCommands.swift` (new)

**Step 1:** Create Commands directory if needed and add ThemeCommands.swift

```swift
//
//  ThemeCommands.swift
//  final final
//

import SwiftUI

struct ThemeCommands: Commands {
    var body: some Commands {
        CommandMenu("Theme") {
            ForEach(AppColorScheme.all) { theme in
                Button(theme.name) {
                    ThemeManager.shared.setTheme(theme)
                }
                .keyboardShortcut(keyboardShortcut(for: theme))
            }
        }
    }

    private func keyboardShortcut(for theme: AppColorScheme) -> KeyboardShortcut? {
        switch theme.id {
        case "light": return KeyboardShortcut("1", modifiers: [.command, .option])
        case "dark": return KeyboardShortcut("2", modifiers: [.command, .option])
        case "sepia": return KeyboardShortcut("3", modifiers: [.command, .option])
        case "solarized-light": return KeyboardShortcut("4", modifiers: [.command, .option])
        case "solarized-dark": return KeyboardShortcut("5", modifiers: [.command, .option])
        default: return nil
        }
    }
}
```

**Verification:** Build succeeds

---

## Task 5: Integrate ThemeManager into FinalFinalApp

**File:** `final final/App/FinalFinalApp.swift` (modify)

**Step 1:** Add ThemeCommands and environment

```swift
//
//  FinalFinalApp.swift
//  final final
//

import SwiftUI

@main
struct FinalFinalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ThemeManager.shared)
        }
        .commands {
            ThemeCommands()
        }
    }
}
```

**Verification:** Build succeeds

---

## Task 6: Update ContentView to Display Theme Colors

**File:** `final final/Views/ContentView.swift` (modify)

**Step 1:** Update ContentView to use theme colors

```swift
//
//  ContentView.swift
//  final final
//

import SwiftUI

struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Outline Sidebar")
                    .font(.headline)
                    .foregroundColor(themeManager.currentTheme.sidebarText)
                    .padding()
                Spacer()
                Text("Phase 1.6 will implement\nthe full outline view")
                    .font(.caption)
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding()

                // Theme indicator for testing
                VStack(spacing: 4) {
                    Text("Current Theme:")
                        .font(.caption2)
                    Text(themeManager.currentTheme.name)
                        .font(.caption)
                        .bold()
                }
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.8))
                .padding()
            }
            .frame(minWidth: 200)
            .background(themeManager.currentTheme.sidebarBackground)
        } detail: {
            VStack {
                Spacer()
                Text("Editor Area")
                    .font(.largeTitle)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                Text("Phase 1.4-1.5 will add\nMilkdown and CodeMirror editors")
                    .font(.body)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
                StatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.editorBackground)
        }
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
```

**Verification:** Build succeeds

---

## Task 7: Update StatusBar to Use Theme Colors

**File:** `final final/Views/StatusBar.swift` (modify)

**Step 1:** Update StatusBar to use theme colors

```swift
//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            Text("0 words")
                .font(.caption)
            Spacer()
            Text("No section")
                .font(.caption)
            Spacer()
            Text("WYSIWYG")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(themeManager.currentTheme.accentColor.opacity(0.2))
                .cornerRadius(4)
        }
        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(themeManager.currentTheme.sidebarBackground)
    }
}

#Preview {
    StatusBar()
        .environment(ThemeManager.shared)
}
```

**Verification:** Build succeeds

---

## Task 8: Add setTheme API to Web Editors

**File:** `web/milkdown/src/main.ts` (modify)

**Step 1:** Add setTheme method to FinalFinal API

```typescript
// Milkdown WYSIWYG Editor - Stub for Phase 1.1

console.log('[Milkdown] Editor stub loaded');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
    };
  }
}

let currentContent = '';

window.FinalFinal = {
  setContent(markdown: string) {
    currentContent = markdown;
    console.log('[Milkdown] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[Milkdown] setFocusMode:', enabled);
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[Milkdown] scrollToOffset:', offset);
  },
  setTheme(cssVariables: string) {
    const root = document.documentElement;
    const pairs = cssVariables.split(';').filter(s => s.trim());
    pairs.forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[Milkdown] Theme applied with', pairs.length, 'variables');
  }
};

console.log('[Milkdown] window.FinalFinal API registered');
```

**File:** `web/codemirror/src/main.ts` (modify)

**Step 2:** Add same setTheme method to CodeMirror

```typescript
// CodeMirror 6 Source Editor - Stub for Phase 1.1

console.log('[CodeMirror] Editor stub loaded');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
    };
  }
}

let currentContent = '';

window.FinalFinal = {
  setContent(markdown: string) {
    currentContent = markdown;
    console.log('[CodeMirror] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[CodeMirror] scrollToOffset:', offset);
  },
  setTheme(cssVariables: string) {
    const root = document.documentElement;
    const pairs = cssVariables.split(';').filter(s => s.trim());
    pairs.forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[CodeMirror] Theme applied with', pairs.length, 'variables');
  }
};

console.log('[CodeMirror] window.FinalFinal API registered');
```

**Verification:** TypeScript compiles (if pnpm build runs)

---

## Task 9: Update Version and Build

**File:** `project.yml` (modify)

**Step 1:** Bump version from 0.1.3 to 0.1.4

Change line 27:
```yaml
        CURRENT_PROJECT_VERSION: "0.1.4"
```

**Step 2:** Regenerate and build

```bash
cd "/Users/niyaro/Documents/Code/final final" && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 10: Swift Code Review

**After all code is written and builds successfully**, run a Swift code review using the `swift-engineering:swift-code-reviewer` agent.

**Step 1:** Launch the code reviewer agent

```
Task(
  subagent_type="swift-engineering:swift-code-reviewer",
  prompt="Review the Phase 1.3 Theme System implementation. Focus on:

1. Swift files created/modified:
   - final final/Theme/ColorScheme.swift
   - final final/Theme/ThemeManager.swift
   - final final/Models/Database.swift (settings extension)
   - final final/Commands/ThemeCommands.swift
   - final final/App/FinalFinalApp.swift
   - final final/Views/ContentView.swift
   - final final/Views/StatusBar.swift

2. Check for:
   - Swift style and conventions
   - @Observable and @MainActor usage correctness
   - Thread safety concerns with ThemeManager singleton
   - SwiftUI environment injection patterns
   - GRDB usage patterns
   - Any potential memory leaks or retain cycles

3. Verify alignment with project patterns from existing code (ProjectStore, EditorViewState)."
)
```

**Step 2:** Address any issues identified by the reviewer

Fix any bugs, style issues, or architectural concerns before marking the phase complete.

**Verification:** Code review passes with no critical issues

---

## Verification Checklist

Phase 1.3 is complete when:

**Theme menu:**
- [ ] Theme menu appears in menu bar
- [ ] All 5 themes listed (Light, Dark, Sepia, Solarized Light, Solarized Dark)
- [ ] Cmd+Opt+1 through Cmd+Opt+5 switch themes

**SwiftUI theming:**
- [ ] Sidebar background changes with theme
- [ ] Sidebar text color changes with theme
- [ ] Editor area background changes with theme
- [ ] Status bar respects theme colors

**Persistence:**
- [ ] Theme persists after app restart
- [ ] Console shows "[ThemeManager] Loaded theme: X" on launch

**Web editor API:**
- [ ] `window.FinalFinal.setTheme` exists in both editors
- [ ] CSS variables set on document root when called

**Code review:**
- [ ] Swift code reviewer agent run
- [ ] All critical issues addressed

---

## Critical Files

| File | Purpose |
|------|---------|
| `Theme/ColorScheme.swift` | Theme definitions + CSS variable generation |
| `Theme/ThemeManager.swift` | State management + persistence |
| `Models/Database.swift` | Settings CRUD methods |
| `Commands/ThemeCommands.swift` | Menu bar integration |
| `App/FinalFinalApp.swift` | Environment + commands registration |
| `Views/ContentView.swift` | Theme-aware main layout |
| `Views/StatusBar.swift` | Theme-aware status bar |
| `web/*/src/main.ts` | setTheme JavaScript API |

---

## Next Phase

**Phase 1.4: Editor Integration (Milkdown)** will implement:
- Full Milkdown WYSIWYG editor setup
- Swift ↔ JS bridge for content sync
- Focus mode plugin
- Theme CSS application to actual editor
