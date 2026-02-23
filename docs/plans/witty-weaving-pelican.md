# Menu Reorganization

## Context

The app currently has 8 menus (File, Edit, Format, View, Theme, Citations, Export, Help), several of which have only 1-2 items. This plan consolidates them into a cleaner structure: File, Edit, View, Help.

## Target Menu Structure

### File menu (add export items)
- New Project... (Cmd+N)
- Open Project... (Cmd+O)
- Open Recent >
- Close Project (Cmd+W)
- ---
- Save (Cmd+S)
- Save Version... (Cmd+Shift+S)
- Version History... (Cmd+Option+V)
- ---
- Import Markdown... (Cmd+Shift+I)
- Export Markdown... (Cmd+Shift+E)
- ---
- Export as Word... (Cmd+Option+E)
- Export as PDF... (Cmd+Option+P)
- Export as ODT...
- Export Preferences...

### Edit menu (absorb Format menu + collect Insert items)
- Find... (Cmd+F)
- Find and Replace... (Cmd+H)
- Find Next (Cmd+G)
- Find Previous (Cmd+Shift+G)
- Use Selection for Find (Cmd+E)
- ---
- Check Spelling (Cmd+;)
- Check Grammar (Cmd+Shift+;)
- ---
- Format > (submenu — formerly standalone menu)
  - Bold (Cmd+B)
  - Italic (Cmd+I)
  - Strikethrough
  - ---
  - Heading > (nested submenu, unchanged)
  - ---
  - Bullet List
  - Numbered List
  - Blockquote
  - Code Block
  - ---
  - Link (Cmd+K)
- Insert > (submenu — collected from scattered items)
  - Section Break (Cmd+Shift+Return)
  - Highlight (Cmd+Shift+H)
  - Footnote (Cmd+Shift+N)
  - Task (Cmd+Shift+T)
  - Comment (Cmd+Shift+C)
  - Reference (Cmd+Shift+R)

### View menu (absorb Theme, Focus/Editor toggles, Refresh Citations)
- Toggle Outline Sidebar (Cmd+[)
- Toggle Annotations Sidebar (Cmd+])
- ---
- Toggle Focus Mode (Cmd+Shift+F)
- Toggle Editor Mode (Cmd+/)
- ---
- Refresh Citations (Cmd+Shift+R)
- ---
- Theme >
  - High Contrast Day (Cmd+Option+1)
  - Low Contrast Day (Cmd+Option+2)
  - High Contrast Night (Cmd+Option+3)
  - Low Contrast Night (Cmd+Option+4)

### Help menu (unchanged)

**Note:** Cmd+Shift+R is used by both "Insert Reference" (Edit > Insert) and "Refresh Citations" (View). This conflict already exists today between the Citations and Edit menus — the reorganization doesn't change it. We can address it separately if desired.

## Files to Modify

### 1. `final final/Commands/FileCommands.swift`
- Add export items (Word, PDF, ODT, Export Preferences) to the `CommandGroup(replacing: .importExport)` block, after a divider following the existing Import/Export Markdown items

### 2. `final final/Commands/ViewCommands.swift`
- Add Toggle Focus Mode (Cmd+Shift+F) and Toggle Editor Mode (Cmd+/)
- Add Refresh Citations (Cmd+Shift+R)
- Add Theme submenu using `Menu("Theme") { ForEach(AppColorScheme.all) { ... } }`
- Move `.refreshAllCitations` notification name here from CitationCommands.swift

### 3. `final final/Commands/EditorCommands.swift`
- Remove Toggle Focus Mode and Toggle Editor Mode from `CommandGroup(after: .textEditing)`
- Convert standalone `CommandMenu("Format")` into a `Menu("Format") { ... }` inside `CommandGroup(after: .textEditing)`
- Wrap Insert items (Section Break, Highlight, Footnote, Task, Comment, Reference) in `Menu("Insert") { ... }`
- Keep Find commands and Spelling/Grammar toggles as-is

### 4. `final final/Commands/ExportCommands.swift`
- Remove `ExportCommands: Commands` struct (menu items moved to FileCommands)
- Keep `ExportOperations` struct and notification name extensions (they're used by other code)

### 5. `final final/Commands/ThemeCommands.swift`
- Delete file (menu items moved to ViewCommands)

### 6. `final final/Commands/CitationCommands.swift`
- Delete file (menu item and notification name moved to ViewCommands)

### 7. `final final/App/FinalFinalApp.swift` (line 87-97)
- Remove `ThemeCommands()`, `CitationCommands()`, and `ExportCommands()` from `.commands` block

### 8. Run `xcodegen generate` after file changes

## Verification
1. Build with `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Launch app and verify each menu:
   - File: export items appear after Import/Export Markdown
   - Edit: Format and Insert appear as submenus; Focus/Editor toggles are gone
   - View: Focus/Editor toggles, Refresh Citations, and Theme submenu appear
   - No standalone Theme, Citations, or Export menus in the menu bar
3. Verify all keyboard shortcuts still work
