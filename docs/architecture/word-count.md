# Word Count Architecture

Word counts flow through multiple layers, from per-section calculation to document totals with goal tracking.

---

## Data Model

```swift
// Section model stores word count
struct Section {
    wordCount: Int           // Cached count for this section
    wordGoal: Int?           // User-set target (optional)
    goalType: GoalType       // .exact, .approx, .minimum
}

// Document-level goal settings (stored in settings table)
struct DocumentGoalSettings {
    goal: Int?               // Document word target
    goalType: GoalType       // How to interpret the goal
    excludeBibliography: Bool // Exclude bibliography from totals
}
```

## Calculation Flow

1. **Section Word Count**: Calculated by `MarkdownUtils.wordCount()` during section sync
   - Strips markdown syntax before counting
   - Counts words separated by whitespace
   - Stored in `Section.wordCount` field

2. **Section Sync**: `SectionSyncService.syncContent()` recalculates word counts when sections are created/updated:
   ```swift
   let wordCount = MarkdownUtils.wordCount(for: sectionMarkdown)
   ```

3. **Document Total**: `EditorViewState.filteredTotalWordCount` computes totals:
   ```swift
   var filteredTotalWordCount: Int {
       sections
           .filter { !excludeBibliography || !$0.isBibliography }
           .reduce(0) { $0 + $1.wordCount }
   }
   ```

## UI Display

| Location | What's Shown | Source |
|----------|--------------|--------|
| Status Bar | Document total | `filteredTotalWordCount` |
| Section Card | Section count | `SectionViewModel.wordCount` |
| Section Card | Goal progress | `wordCount` vs `wordGoal` |
| Filter Bar | Document goal progress | `filteredTotalWordCount` vs `documentGoal` |

## Goal Colors

Word count colors indicate progress toward goals:

```swift
func goalColor(wordCount: Int, goal: Int, type: GoalType) -> Color {
    let ratio = Double(wordCount) / Double(goal)
    switch type {
    case .exact:
        // Green when within +/-10%, yellow when close, red when far
    case .approx:
        // Green when >=80%, yellow when 50-80%, gray below
    case .minimum:
        // Green when >=100%, yellow when 80-100%, red below
    }
}
```

## Section Status Persistence

Status changes from `StatusDot` are persisted immediately via a `.onChange(of: section.status)` modifier on `SectionCardView`. When the status value changes, `onSectionUpdated` fires, which calls `ContentView.updateSection()` to write the new status to the database. This ensures status survives zoom in/out and app restarts.

## Zoom Mode Word Count Update

**Problem**: During zoom mode, ValueObservation is blocked by the `contentState` guard, preventing word count updates from reaching the UI.

**Solution**: Direct callback pattern bypasses ValueObservation:

```
Editor Content Changes
        |
SectionSyncService.syncZoomedSections()
        |
Database updated (word counts saved)
        |
onZoomedSectionsUpdated callback fired
        |
EditorViewState.refreshZoomedSections()
        |
Fetches from DB, updates sections array
        |
UI reflects new word counts
```

**Implementation**:
- `SectionSyncService.onZoomedSectionsUpdated`: Callback invoked after zoomed sections are saved
- `EditorViewState.refreshZoomedSections()`: Reads from database and updates in-memory sections
- Wired up in `ContentView.configureForCurrentProject()`

This ensures word counts update in real-time while editing zoomed sections, even though ValueObservation is blocked.
