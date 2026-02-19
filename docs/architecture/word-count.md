# Word Count Architecture

Word counts flow through multiple layers, from per-section calculation to document totals with goal tracking.

---

## Data Model

```swift
// Section/Block model stores word count and goals
struct Section {
    wordCount: Int              // Cached count for this section only
    wordGoal: Int?              // Section-level target (optional)
    goalType: GoalType          // .exact, .approx, .minimum
    aggregateGoal: Int?         // Subtree target (section + descendants, optional)
    aggregateGoalType: GoalType // Goal type for aggregate
}

// Document-level goal settings (stored in settings table)
struct DocumentGoalSettings {
    goal: Int?               // Document word target
    goalType: GoalType       // How to interpret the goal
    excludeBibliography: Bool // Exclude bibliography from totals
}
```

## Section-Only vs Aggregate Word Counts

Word counts have two scopes:

- **Section-only** (`sectionOnlyWordCount`): Counts words from the heading block to the next heading of ANY level. This is the section's own content, excluding child sections.
- **Aggregate** (`wordCountForHeading`): Counts words from the heading to the next same-or-higher level heading. This includes all descendant sections.

The sidebar displays section-only counts by default. When an aggregate goal is set, the sidebar switches to showing the aggregate count with a sigma (Σ) prefix.

## Calculation Flow

1. **Block Word Count**: Each block stores its own `wordCount`, calculated by `BlockSyncService` during the 300ms polling cycle.

2. **Section-Only Count**: `Database+BlocksWordCount.sectionOnlyWordCount(blockId:)` sums word counts from this heading to the next heading (any level):
   ```swift
   func sectionOnlyWordCount(blockId: String) throws -> Int {
       // Find next heading of ANY level
       // Sum block.wordCount from this heading to next heading
   }
   ```

3. **Aggregate Count**: `Database+BlocksWordCount.wordCountForHeading(blockId:)` sums word counts from this heading to the next same-or-higher level heading, including all child sections.

4. **Observation Loop**: `EditorViewState.startObserving()` computes both counts on each emission:
   ```swift
   for i in viewModels.indices {
       if let wc = try? database.sectionOnlyWordCount(blockId: vm.id) {
           viewModels[i].wordCount = wc
       }
       if viewModels[i].aggregateGoal != nil {
           if let awc = try? database.wordCountForHeading(blockId: vm.id) {
               viewModels[i].aggregateWordCount = awc
           }
       }
   }
   ```

5. **Document Total**: `EditorViewState.filteredTotalWordCount` computes totals:
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
| Section Card | Section-only count | `SectionViewModel.wordCount` |
| Section Card | Section goal progress | `wordCount` vs `wordGoal` |
| Section Card | Aggregate count (when aggregate goal set) | `Σ aggregateWordCount/aggregateGoal` |
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

Word counts update in real-time during zoom via two mechanisms:

### 1. ValueObservation (primary)

The `observeOutlineBlocks` ValueObservation does NOT use `.removeDuplicates()`. This is deliberate: the observation queries heading blocks, but word counts are derived from body blocks. When body text changes, the heading query returns identical rows, but the word count aggregation produces different results. Without `.removeDuplicates()`, every database write (from BlockSyncService's 300ms polling) triggers re-emission, which recalculates word counts.

**Safety**: GRDB fires once per committed transaction, not per row. With BlockSyncService batching, this means ~3 emissions/second max. Guards (`isObservationSuppressed`, `contentState == .idle`) prevent processing during drag-drop and other transitions.

### 2. Direct callback (fallback)

When `contentState` is non-idle (blocking ValueObservation), a direct callback provides updates:

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

## Goal Popover

`WordCountGoalPopover` (in `SectionCardView.swift`) provides UI for setting both section and aggregate goals. Key design choices:

- **Local state**: Uses `@State` for input fields to prevent flickering from `@Observable` re-renders during ValueObservation updates
- **Atomic save**: `ContentView.updateSection()` writes all metadata fields (status, wordGoal, goalType, aggregateGoal, aggregateGoalType, tags) in a single SQL UPDATE to prevent intermediate ValueObservation fires from resetting fields
- **Goal type picker**: Segmented control with `.exact`, `.approx`, `.minimum` for each goal independently
