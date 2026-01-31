# Auto-Version in About Screen

## Approach

This follows the standard macOS pattern for version display. The system About panel (accessible via the app menu) is a built-in component that reads version information from Info.plist. By using Xcode build setting variables instead of hardcoded values, the version automatically stays in sync with project.yml.

## Problem

The macOS About panel ("About final final" in the app menu) shows hardcoded version numbers instead of automatically reading from the build settings.

**Current state:**
- `project.yml` defines: `MARKETING_VERSION: "1"`, `CURRENT_PROJECT_VERSION: "0.2.3"`
- `Info.plist` has hardcoded: `CFBundleShortVersionString: 1.0`, `CFBundleVersion: 1`
- The About panel shows the hardcoded Info.plist values, not the project.yml values

## Solution

Replace hardcoded version strings in Info.plist with Xcode build setting variables:

| Key | Current Value | New Value |
|-----|---------------|-----------|
| `CFBundleShortVersionString` | `1.0` | `$(MARKETING_VERSION)` |
| `CFBundleVersion` | `1` | `$(CURRENT_PROJECT_VERSION)` |

## Implementation

### File to modify

`final final/Info.plist`

### Changes

1. Line 35: Change `<string>1.0</string>` to `<string>$(MARKETING_VERSION)</string>`
2. Line 48: Change `<string>1</string>` to `<string>$(CURRENT_PROJECT_VERSION)</string>`

## Verification

1. Regenerate Xcode project: `xcodegen generate`
2. Build the app: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
3. Open the built app
4. Click "final final" menu → "About final final"
5. Confirm it shows "Version 1 (0.2.3)" matching project.yml values
