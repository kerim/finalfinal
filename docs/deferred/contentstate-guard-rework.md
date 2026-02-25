# The `contentState` Guard Pattern Problem

## Current Design

`EditorViewState` has a `contentState` enum that tracks transitions:
```swift
enum ContentState {
    case idle
    case zoomTransition
    case bibliographyUpdate
    // etc.
}
```

The ValueObservation handler in `startObserving()` has this guard:
```swift
guard contentState == .idle else {
    print("[OBSERVE] SKIPPED due to contentState: \(contentState)")
    continue
}
```

## Why It Exists

The guard prevents race conditions during complex operations:
- During zoom transitions, you don't want stale DB observations overwriting the zoomed content
- During bibliography updates, you don't want mid-update observations causing partial renders

## Why It's Problematic

1. **Lost Updates**: Any database change that happens while `contentState != .idle` is silently dropped. The observation fires, sees the guard, and discards the update forever.

2. **Timing Sensitivity**: Operations must carefully manage `contentState` transitions. If something sets `contentState` but crashes before resetting to `.idle`, observations are permanently blocked.

3. **Cascading Workarounds**: Both bugs we're fixing require bypassing this guard with direct notifications or manual refreshes. Each workaround adds complexity.

4. **Hidden Dependencies**: The guard creates implicit coupling - services must "know" that the observation path might be blocked and compensate.

## More Robust Alternatives

### Option 1: Queue Instead of Drop
```swift
// Instead of skipping, queue the observation
private var pendingObservations: [([Section], String?)] = []

// In observation handler:
if contentState != .idle {
    pendingObservations.append((sections, bibHash))
    return
}

// When contentState returns to .idle:
func processQueuedObservations() {
    for (sections, bibHash) in pendingObservations {
        handleObservation(sections, bibHash)
    }
    pendingObservations.removeAll()
}
```

### Option 2: Granular State Flags
Instead of one `contentState` blocking everything, use specific flags:
```swift
var isZoomTransitionInProgress = false
var isBibliographyUpdateInProgress = false
var isSectionSyncInProgress = false

// In observation handler - only block what's necessary:
if isZoomTransitionInProgress && observationType == .sections {
    return // Block section updates during zoom
}
// But allow bibliography observations through
```

### Option 3: Versioned State
Track a version number and only apply observations that are "newer":
```swift
var stateVersion: Int = 0

// Before any operation that modifies state:
let operationVersion = stateVersion + 1
stateVersion = operationVersion

// In observation handler:
// Only skip if an operation started AFTER this observation was triggered
```

### Option 4: Reactive Streams with Backpressure
Use Combine to create a proper reactive pipeline where observations can be buffered, debounced, or coalesced based on state:
```swift
sectionsObservation
    .filter { [weak self] _ in self?.contentState == .idle }
    .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
    .sink { sections in ... }
```

### Option 5: Command Pattern
Instead of direct state mutation, queue commands that get processed in order:
```swift
enum EditorCommand {
    case updateSections([Section])
    case updateBibliography(String)
    case zoomTo(String)
}

// All changes go through a single processing queue
func process(_ command: EditorCommand) {
    commandQueue.append(command)
    processNextCommand()
}
```

## Recommendation for Future

The **Queue Instead of Drop** approach (Option 1) is the simplest improvement - it preserves the current architecture but ensures no updates are lost. When `contentState` returns to `.idle`, process any queued observations.

For a more significant refactor, **Granular State Flags** (Option 2) would allow finer control over what gets blocked during which operations, reducing the blast radius of each guard.

---

*Created: 2026-02-05*
*Context: Discovered while debugging bibliography rendering and zoom word count bugs*
