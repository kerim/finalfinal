//
//  FindBarView.swift
//  final final
//
//  Native-style find and replace bar following Apple HIG.
//

import SwiftUI

/// Find and replace bar following Apple's design standards
struct FindBarView: View {
    @Bindable var state: FindBarState
    /// Esc-ladder live state for this window (UX contract §6). Optional so existing preview/
    /// test call sites keep compiling unchanged.
    var escapeLadder: EscapeLadderContext?
    @Environment(ThemeManager.self) private var themeManager
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isReplaceFieldFocused: Bool
    @State private var showReplaceToggleTooltip = false
    @State private var replaceToggleTooltipTask: Task<Void, Never>?
    /// Measured width of the tooltip bubble, read by the `.offset(x:)` that shifts it fully to
    /// the left of the Replace-arrow toggle. Measured by an `.onGeometryChange` on the real
    /// tooltip `Text` itself, inside its own `if showReplaceToggleTooltip { ... }` conditional
    /// mount -- see that `.overlay`'s doc comment below for why an always-mounted "ghost"
    /// measuring view was tried and reverted.
    ///
    /// Seeded to 160 (a safe overestimate) rather than 0. `.onGeometryChange` doesn't report the
    /// real width until a frame after the tooltip first mounts, so on that very first frame this
    /// initial value is what `.offset(x: -(replaceToggleTooltipWidth + 8))` actually uses. At 0
    /// that resolved to only an 8pt leftward shift -- nowhere near enough to clear the toggle
    /// button -- and a real e2e run (ShortcutTooltipE2ETests.swift:165) caught the tooltip
    /// overlapping the button on that exact first frame, since the test reads the tooltip's frame
    /// immediately after `waitForExistence` succeeds. 160 was chosen by directly measuring both
    /// possible tooltip strings with `NSAttributedString.size(withAttributes:)` at `.caption`
    /// (10pt) plus the 8pt-each-side horizontal padding applied below: "Hide Replace" measures
    /// ~79.5pt and the wider "Show Replace (⌥⌘F)" measures ~119.3pt. 160 clears the wider string
    /// with ~35% of headroom to spare for font-rendering/OS-version variance. Overshooting is
    /// safe -- SwiftUI corrects to the exact measured width on the next frame, and a slightly
    /// too-large first-frame gap is invisible; undershooting reproduces the overlap bug above.
    @State private var replaceToggleTooltipWidth: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Search field with magnifying glass
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: TypeScale.caption))

                    TextField("Find", text: $state.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: TypeScale.chromeLabel))
                        .focused($isSearchFieldFocused)
                        .accessibilityIdentifier("find-bar-search-field")
                        .onSubmit {
                            state.findNext()
                        }
                        .onChange(of: state.searchQuery) { _, _ in
                            state.find()
                        }

                    if !state.searchQuery.isEmpty {
                        Button {
                            state.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: TypeScale.caption))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 180, maxWidth: .infinity)

                // Match count
                if state.totalMatches > 0 {
                    Text("\(state.currentMatch) of \(state.totalMatches)")
                        .font(.system(size: TypeScale.smallUI))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if !state.searchQuery.isEmpty {
                    Text("No matches")
                        .font(.system(size: TypeScale.smallUI))
                        .foregroundStyle(.secondary)
                }

                // Navigation buttons
                HStack(spacing: 2) {
                    Button {
                        state.findPrevious()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: TypeScale.caption, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.searchQuery.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Find Previous (⇧⌘G)")

                    Button {
                        state.findNext()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: TypeScale.caption, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.searchQuery.isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Find Next (⌘G)")
                }

                Spacer()

                // Replace toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.showReplace.toggle()
                    }
                } label: {
                    Image(systemName: state.showReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: TypeScale.body))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("find-bar-replace-toggle")
                // Plain `.help(...)` inherits AppKit's system-wide help-tag delay (~1-1.5s,
                // not configurable per-view in SwiftUI) -- once this tooltip started naming
                // its real binding (⌥⌘F, replacing an incorrect earlier shortcut claim), that delay was long
                // enough most people hovering it would give up before it ever appeared.
                // Custom onHover + delayed overlay instead, same Task.sleep +
                // cancel-on-new-hover pattern as StatusBar.showEditorModeTooltip.
                // `.accessibilityHint` replaces the VoiceOver description `.help(...)` used
                // to provide.
                .onHover { hovering in
                    replaceToggleTooltipTask?.cancel()
                    if hovering {
                        replaceToggleTooltipTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            showReplaceToggleTooltip = true
                        }
                    } else {
                        showReplaceToggleTooltip = false
                    }
                }
                // Opens to the LEADING (left) side of the button, not above or below it.
                // Both vertical directions collide with something real: opening upward runs
                // into the window's title bar (this button sits in the find bar's top row,
                // only ~8pt of padding below the title bar, unlike StatusBar's identical-
                // looking tooltip pattern which safely opens upward because StatusBar is the
                // LAST child at the bottom of the editor column -- see
                // ContentView+EditorPresentation.swift's `detailView`:
                // `VStack { findBar; editorView; StatusBar }`). Opening downward runs into the
                // Replace row: when `state.showReplace` is true, that row (search field,
                // "Replace", "All" buttons) renders directly below this button in the very
                // space a downward tooltip would occupy, so a fixed downward offset overlapped
                // it. Sideways avoids both: this button sits at the end of a `Spacer()` in the
                // top HStack (search field / match count / nav buttons -- Spacer -- replace
                // toggle -- options menu -- close button), so the Spacer's stretched, empty
                // region is directly to its leading edge in both Replace states -- the Replace
                // row is a second, separate HStack below this whole row, so it is never in the
                // leading tooltip's path either way. Trailing was rejected: the options menu
                // and close button sit only 8pt past this button's trailing edge, too tight for
                // the tooltip bubble.
                //
                // PREVIOUS BUG #1 (found by a real e2e screenshot of
                // `testHoveringReplaceToggleShowsCustomTooltip`, not caught by the test's own
                // assertions, which only check the tooltip's text/identifier, never its
                // geometry): this used `.overlay(alignment: .leading) { if
                // showReplaceToggleTooltip { Text(...).fixedSize().alignmentGuide(.leading) { d
                // in d.width + 8 } ... } }`. That should, by the documented semantics of
                // `alignmentGuide`, push the tooltip fully outside the button's own frame -- but
                // the actual screenshot showed the tooltip rendering in place over the button's
                // own chevron icon and bleeding right into the options menu/close button, i.e.
                // the guide override had no visible effect. The one other tooltip in this
                // codebase built on the same onHover+overlay shape
                // (`StatusBar.swift`'s `showEditorModeTooltip`) does NOT use `alignmentGuide` at
                // all -- it uses a plain `.offset(y: -28)`, which only works there because that
                // tooltip's text is short and the offset only has to clear a fixed-height
                // button vertically. Rebuilt on that same proven `.offset`-based mechanism
                // instead, adapted for a *width*-dependent horizontal offset (this tooltip's
                // text swaps between "Hide Replace" and "Show Replace (⌥⌘F)", two very different
                // widths): `.onGeometryChange` measures the tooltip bubble's actual rendered
                // width into `replaceToggleTooltipWidth`, and `.offset(x: -(width + 8))` shifts
                // it left by exactly that width plus an 8pt gap, landing its trailing edge 8pt
                // left of the button with no overlap in either Replace-row state.
                //
                // PREVIOUS BUG #2 (found by a real e2e run, not this test's own logic -- the fix
                // for bug #1 above introduced this one): to keep `.onGeometryChange` measuring
                // continuously even while hidden, that round removed the `if
                // showReplaceToggleTooltip` gate entirely and made this `Text` always exist in
                // the tree, toggling visibility with `.opacity(showReplaceToggleTooltip ? 1 : 0)`
                // + `.accessibilityHidden(!showReplaceToggleTooltip)` instead (mirroring
                // `AnnotationPanel.swift`'s pattern). That broke `waitForExistence` for real:
                // `testHoveringReplaceToggleShowsCustomTooltip` hovered, waited, and
                // `app.staticTexts["find-bar-replace-toggle-tooltip"]` never became queryable
                // within 3s, even though the "not visible before hover" check just above it
                // (which only asserts `.exists` is false) kept passing.
                //
                // PREVIOUS BUG #3 (also found by a real e2e run, with an AX hierarchy dump
                // confirming the tooltip text genuinely never rendered anywhere in the tree
                // within the 3s window -- not an accessibility-query subtlety): the fix for bug
                // #2 above split measurement and visibility into two views -- a second,
                // permanently-mounted, invisible "ghost" copy of the tooltip text hosted in a
                // `.background` here, feeding `.onGeometryChange` -> `replaceToggleTooltipWidth`
                // continuously so the width was already current by the time the real,
                // conditionally-mounted tooltip appeared -- while restoring the real tooltip's
                // `if showReplaceToggleTooltip { ... }` conditional-mount shape exactly as it
                // was before bug #1's rewrite. That still failed the same `waitForExistence`
                // check, identically, across two separate rounds. The exact mechanism was never
                // pinned down for either bug #2 or bug #3 -- but with two different
                // always-mounted-parallel-view shapes both breaking existence detection in this
                // VM test environment, the fix below drops the second view entirely rather than
                // chase a fourth theory: `.onGeometryChange` now lives directly on the real
                // tooltip `Text`, inside its own conditional mount, so nothing about
                // mounting/unmounting differs from the original, reliably-passing version at
                // all. The accepted trade-off: the very first frame the tooltip appears, its
                // measured width is still at `replaceToggleTooltipWidth`'s initial value (0)
                // until `.onGeometryChange` reports the real width one frame later, causing a
                // one-frame visual jump from an initial (too-far-right) offset to the correct
                // one -- a single SwiftUI render frame, imperceptible in practice, and a strictly
                // smaller risk than the existence-timing regression bugs #2 and #3 introduced.
                //
                // The real, user-visible tooltip: conditionally mounted (existence toggles with
                // `showReplaceToggleTooltip`, the original, proven-reliable existence
                // semantics). Colors use system NSColor tokens instead of
                // `themeManager.currentTheme.tooltip*` so this tooltip matches the native system
                // tooltip style of Find Previous/Find Next right next to it (`.help(...)`,
                // unthemed) rather than the app's own dark chrome theme. Round-tripped through
                // `find-bar-replace-toggle-tooltip`'s accessibility identifier so
                // ShortcutTooltipE2ETests can assert it actually renders.
                .overlay(alignment: .leading) {
                    if showReplaceToggleTooltip {
                        Text(state.showReplace ? "Hide Replace" : "Show Replace (⌥⌘F)")
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .labelColor))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { newWidth in
                                replaceToggleTooltipWidth = newWidth
                            }
                            .offset(x: -(replaceToggleTooltipWidth + 8))
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("find-bar-replace-toggle-tooltip")
                    }
                }
                .accessibilityHint(Text(state.showReplace ? "Hide Replace" : "Show Replace (⌥⌘F)"))

                // Options menu
                Menu {
                    Toggle("Ignore Case", isOn: $state.ignoreCase)
                    Toggle("Wrap Around", isOn: $state.wrapAround)
                    Divider()
                    Picker("Match Mode", selection: $state.matchMode) {
                        ForEach(FindBarState.MatchMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: TypeScale.body))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Search Options")

                // Close button
                Button {
                    state.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TypeScale.smallUI, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // No .keyboardShortcut(.escape) here (hygiene, not a behavior change): this
                // shortcut WAS load-bearing under the old code outside Focus Mode (the removed
                // AppDelegate monitor only consumed Esc while Focus Mode was on) -- but the new
                // escape ladder now owns Esc for this surface in every case, Focus Mode or not
                // (UX contract §6), so a separate SwiftUI shortcut here would be redundant, not
                // load-bearing.
                .help("Close (Esc)")
                .accessibilityIdentifier("find-bar-close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Replace row (collapsible)
            if state.showReplace {
                HStack(spacing: 8) {
                    // Replace field
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .font(.system(size: TypeScale.caption))

                        TextField("Replace", text: $state.replaceText)
                            .textFieldStyle(.plain)
                            .font(.system(size: TypeScale.chromeLabel))
                            .focused($isReplaceFieldFocused)
                            .onSubmit {
                                state.replaceCurrent()
                            }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .frame(minWidth: 180, maxWidth: .infinity)

                    // Replace buttons
                    Button("Replace") {
                        state.replaceCurrent()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.searchQuery.isEmpty ? .secondary : themeManager.currentTheme.accentColor)
                    .disabled(state.searchQuery.isEmpty)
                    .help("Replace current match")

                    Button("All") {
                        state.replaceAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.searchQuery.isEmpty ? .secondary : themeManager.currentTheme.accentColor)
                    .disabled(state.searchQuery.isEmpty)
                    .help("Replace all matches")

                    // Status message
                    if let message = state.statusMessage {
                        Text(message)
                            .font(.system(size: TypeScale.smallUI))
                            .foregroundStyle(.secondary)
                            .onAppear {
                                // Auto-clear status after 3 seconds
                                Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    state.statusMessage = nil
                                }
                            }
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("find-bar")
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: state.focusRequestCount) { _, _ in
            isSearchFieldFocused = true
        }
        // Both handlers report the OR of the two fields (not just their own `focused` value):
        // when focus moves from one find-bar field directly to the other, computing the OR at
        // the moment each fires keeps `findBarFieldFocused` continuously true across the
        // transition instead of ever dropping to false in between. Reporting only the field's
        // own value on the false branch (fixed from an earlier bug where the false branch was
        // missing entirely) would otherwise latch `findBarFieldFocused` true forever the first
        // time either field was ever focused.
        .onChange(of: isSearchFieldFocused) { _, _ in
            escapeLadder?.setFindBarFieldFocused(isSearchFieldFocused || isReplaceFieldFocused)
        }
        .onChange(of: isReplaceFieldFocused) { _, _ in
            escapeLadder?.setFindBarFieldFocused(isSearchFieldFocused || isReplaceFieldFocused)
        }
        .onDisappear {
            escapeLadder?.clearFindBarFocus()
        }
    }
}

#Preview {
    VStack {
        FindBarView(state: {
            let state = FindBarState()
            state.isVisible = true
            state.showReplace = true
            state.searchQuery = "test"
            state.totalMatches = 5
            state.currentMatch = 2
            return state
        }())

        Spacer()
    }
    .frame(width: 600, height: 400)
}
