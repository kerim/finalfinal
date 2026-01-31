# Fix Onboarding Merge Issues

## Problem
After merging the onboarding branch into main, two features are broken:
1. **Getting Started** - appears in Help menu but doesn't open when clicked
2. **Project Picker** - doesn't appear when all project windows are closed

Both features work correctly on the `onboarding` branch.

## Root Cause Analysis

The merge itself was successful - all onboarding code is on main. The issue is that **post-merge changes on main** broke the functionality.

### Changes on main after merge (commit 6a5d854):
1. `ViewCommands()` added to FinalFinalApp's `.commands { }` block
2. ContentView.swift refactored:
   - Observers moved to view extension methods (`.withContentObservers()`, `.withSidebarSync()`)
   - NavigationSplitView now uses `columnVisibility: $sidebarVisibility` binding
   - Toggle sidebar notification handlers added (`.toggleOutlineSidebar`, `.toggleAnnotationSidebar`)
3. `NSWindow.allowsAutomaticWindowTabbing = false` added to AppDelegate
4. New components: `ChevronButton.swift`, `NativeToolbarButton.swift`

### Notification Architecture (Both Branches)
The notification chain should be:
1. **Getting Started**: Help menu → `HelpCommands.onGettingStarted()` → posts `.openGettingStarted` → FinalFinalApp receives → `openGettingStarted()` → state = `.gettingStarted`
2. **Project Close**: `windowShouldClose()` → `FileOperations.handleCloseProject()` → posts `.projectDidClose` → FinalFinalApp receives → `handleProjectClosed()` → state = `.picker`

Note: Both ContentView and FinalFinalApp listen to `.projectDidClose`:
- FinalFinalApp: updates `appViewState` to `.picker`
- ContentView: calls `onClosed()` callback (which also sets state)

## Fix Approach (Keep Both Features)

Since theoretical analysis hasn't identified the exact cause, we'll use systematic debugging:

### Step 1: Add diagnostic logging
Add print statements to trace the notification flow:
- `HelpCommands.swift:17` - Log when Getting Started button clicked
- Verify notification is posted

### Step 2: Test with ViewCommands removed
Temporarily remove ViewCommands to isolate if that's the cause:
- Comment out `ViewCommands()` in FinalFinalApp.swift
- Build and test

### Step 3: If ViewCommands is the culprit
Investigate why `CommandGroup(after: .sidebar)` interferes with HelpCommands' `CommandGroup(replacing: .help)`.

Potential fixes:
- Reorder commands in `.commands { }` block
- Use different CommandGroup placement
- Move ViewCommands button actions to use callbacks like HelpCommands

### Step 4: If ContentView refactoring is the culprit
The view extension methods (`.withContentObservers()`, `.withSidebarSync()`) may be affecting SwiftUI's view lifecycle. Fix by:
- Keep the sidebar visibility sync logic
- But inline the observers rather than using extensions
- Or ensure the view modifier chain doesn't break `.onReceive()` in FinalFinalApp

## Files to Modify

| File | Change |
|------|--------|
| `final final/Commands/HelpCommands.swift` | Add diagnostic logging |
| `final final/App/FinalFinalApp.swift` | Test with/without ViewCommands |
| `final final/Views/ContentView.swift` | May need to inline observers |

## Verification

1. Build and run the app
2. Check console for diagnostic logs
3. Click Help → Getting Started → should open Getting Started project and show log
4. Close the project (Cmd+W or File → Close) → should show project picker
5. Verify Cmd+[ and Cmd+] still toggle sidebars (if ViewCommands kept)
