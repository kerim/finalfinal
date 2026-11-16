//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    // Internal (not private) because StatusBar+Popovers.swift, an extension of this struct in
    // a separate file, reads this. An `@Environment` value is injected by ancestor views
    // regardless of the property's own visibility -- making it internal only changes which
    // files in this module can reference the property, not how it gets populated.
    @Environment(ThemeManager.self) internal var themeManager
    let editorState: EditorViewState
    let onExitZoom: () -> Void
    @AppStorage("isSpellingEnabled") private var spellingEnabled = true
    @AppStorage("isGrammarEnabled") private var grammarEnabled = true
    @AppStorage("isSmartQuotesEnabled") private var smartQuotesEnabled = true
    // Internal (not private): read/written from StatusBar+Popovers.swift.
    @State internal var showProofingPopover = false
    @State internal var showOutlinePopover = false
    @State private var showEditorModeTooltip = false
    @State private var editorModeTooltipTask: Task<Void, Never>?

    var body: some View {
        HStack {
            Text(wordCountDisplay)
                .font(.caption)
                .accessibilityIdentifier("status-bar-word-count")
            Spacer()
            // Merge of the center section indicator and the old separate trailing zoom pill
            // (review round: the two showed nearly the same text at once, and the trailing pill
            // crammed into the icon row read as oversized). While zoomed, this SAME control's
            // text reads "Zoomed: <heading>" (reusing zoomPillLabel's degrade-gracefully rule --
            // see its own doc comment) instead of the plain section name, and gains a small
            // leading exit glyph. One control can't both open the outline popover on a click AND
            // exit zoom on a click, so the exit glyph is its own separate leading Button -- but
            // (review-fix round, must-fix A) that Button and the outline-popover Button both live
            // INSIDE one shared HStack, with the tinted pill background/padding/corner-radius
            // applied to that whole HStack rather than to either button's own label, so it reads
            // as one pill with two tap zones, not a pill plus a floating chevron. Default design
            // call, stated here rather than asked: `chevron.left` matches ZoomBreadcrumb's own
            // exit icon (OutlineSidebar+Components.swift) -- "same act, same treatment" (UX
            // contract §1.3).
            HStack(spacing: Spacing.s4) {
                // Must-fix H (review-fix round; this explanation was deleted along with the old
                // separate trailing pill's code and is restored here): visibility keys on the raw
                // `zoomedSectionId`, not a `zoomedSection` object lookup, because a structural
                // operation (section delete/duplicate, etc.) can mint a fresh section id and
                // leave the old one orphaned from `editorState.sections` for one beat -- an
                // object-lookup condition would go nil during that window and the exit zone would
                // visibly flicker out and back in. The raw id stays populated across that beat, so
                // keying on it avoids the flicker (see `centerIndicatorLabel`'s own
                // degrade-gracefully handling for what the label does when the lookup fails).
                if editorState.zoomedSectionId != nil {
                    Button {
                        onExitZoom()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: TypeScale.chromeTiny))
                            // Must-fix A (review-fix round): a real tappable area -- the glyph
                            // alone was ~10x10pt. 20x20 matches this app's other small
                            // icon-only chrome buttons (e.g. ChevronButton's inner visual).
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Must-fix A (review-fix round): match every sibling status-bar control (and
                    // the sidebar's own exit chevron, OutlineSidebar+Components.swift) instead of
                    // inheriting the dimmed secondary text color from the outer HStack below.
                    .foregroundColor(themeManager.currentTheme.accentColor)
                    // Must-fix 1 (review-fix round, carried over from the old trailing pill):
                    // guards the re-entrant zoom-out race -- a click during the async zoom-out
                    // transition (contentState != .idle) must not fire a second, concurrent
                    // performUserZoomOut/zoomOut() call. Mirrors ZoomBreadcrumb's own exit
                    // button and HeadingZoomClickRouter.decide's contentState == .idle gate.
                    .disabled(editorState.contentState != .idle)
                    // Must-fix E (review-fix round): one Title-Case phrase for both the tooltip
                    // and the VoiceOver label -- see `zoomExitActionLabel`'s doc comment.
                    .help(zoomExitActionLabel)
                    .accessibilityLabel(zoomExitActionLabel)
                    .accessibilityIdentifier("status-bar-zoom-exit")
                }
                Button {
                    showOutlinePopover.toggle()
                } label: {
                    HStack(spacing: Spacing.s4) {
                        ZStack {
                            // Hidden sizer, isolated into its own `CenterIndicatorSizer` subview
                            // (bug-fix round, ship-fix/fullsuite-round2): `editorState.sections`
                            // churns right when `requestEditorModeToggle()`/mode switching
                            // remounts the editor, and reading it directly here would make it a
                            // dependency of THIS view's -- i.e. all of `StatusBar`'s, including
                            // the `status-bar-editor-mode` mode-badge Button below in the same
                            // body -- Observation tracking, not just of this small sizer.
                            // Swift's Observation invalidates and re-runs the WHOLE view whose
                            // body read a changed property, not just the expression that read
                            // it; a SwiftUI re-render landing between that Button's mouse-down
                            // and mouse-up (its `.buttonStyle(.plain)`) can silently cancel the
                            // click -- confirmed as the regression behind
                            // EditorModeSwitchUndoE2ETests.testUndoAfterWysiwygToSourceViaStatusBarBadge
                            // (three straight passes, then three straight fails once this sizer
                            // was added). Passing `editorState` itself down (not the extracted
                            // `.sections` array) means only `CenterIndicatorSizer.body` -- not
                            // this one -- subscribes to `.sections` changes.
                            CenterIndicatorSizer(editorState: editorState)
                            // Visible current title -- "Zoomed: <heading>" while zoomed.
                            Text(centerIndicatorLabel)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: 200)
                        Image(systemName: "chevron.down")
                            .font(.system(size: TypeScale.chromeTiny))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(documentOutlineActionLabel)
                .popover(isPresented: $showOutlinePopover) {
                    outlinePopover
                }
                // Must-fix D (review-fix round): the primary label always describes the button's
                // own ACTION ("Document Outline", matching its `.help()` tooltip verbatim,
                // unaffected by zoom state) so VoiceOver announces that first. The
                // "currently zoomed into X" (or, unzoomed, the plain current-section name) state
                // that used to BE the label now lives in `.accessibilityValue`, read second.
                .accessibilityLabel(documentOutlineActionLabel)
                .accessibilityValue(Text(centerIndicatorAccessibilityLabel))
                .accessibilityIdentifier("status-bar-outline")
            }
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s2)
            .background(themeManager.currentTheme.accentColor.opacity(0.2))
            .cornerRadius(CornerRadius.control)
            Spacer()

            // Proofing status indicator (only when LanguageTool is active)
            if ProofingSettings.shared.mode.isLanguageTool {
                proofingIndicator
                    .popover(isPresented: $showProofingPopover) {
                        proofingStatusPopover
                    }
            }

            // Spelling toggle
            Button {
                spellingEnabled.toggle()
                NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil)
            } label: {
                Text("Spelling")
                    .font(.caption)
                    .lineLimit(1)
                    .strikethrough(!spellingEnabled)
            }
            .buttonStyle(.plain)
            .foregroundColor(spellingEnabled
                ? themeManager.currentTheme.accentColor
                : themeManager.currentTheme.sidebarText.opacity(0.4))
            .help(spellingEnabled ? "Spelling: on" : "Spelling: off")
            .accessibilityIdentifier("status-bar-spelling")

            // Grammar toggle
            Button {
                grammarEnabled.toggle()
                NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil)
            } label: {
                Text("Grammar")
                    .font(.caption)
                    .lineLimit(1)
                    .strikethrough(!grammarEnabled)
            }
            .buttonStyle(.plain)
            .foregroundColor(grammarEnabled
                ? themeManager.currentTheme.accentColor
                : themeManager.currentTheme.sidebarText.opacity(0.4))
            .help(grammarEnabled ? "Grammar: on" : "Grammar: off")
            .accessibilityIdentifier("status-bar-grammar")

            // Smart quotes toggle
            Button {
                smartQuotesEnabled.toggle()
                NotificationCenter.default.post(
                    name: .smartQuotesStateChanged,
                    object: nil,
                    userInfo: ["enabled": smartQuotesEnabled]
                )
            } label: {
                Image(systemName: "quote.opening")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(smartQuotesEnabled
                ? themeManager.currentTheme.accentColor
                : themeManager.currentTheme.sidebarText.opacity(0.4))
            .help(smartQuotesEnabled ? "Smart Quotes: on" : "Smart Quotes: off")
            .accessibilityIdentifier("status-bar-smart-quotes")

            // Clickable editor mode badge
            Button {
                // t-177a10f1: the same receipt line as the Cmd-/ menu command (ViewCommands.swift): persisted when the click reaches the app,
                // before the caret-save round trip and any gate, so a UI test never resends a click the app already has.
                DebugLog.alwaysPersisted("[TRANS] toggle received to=\(editorState.editorMode == .wysiwyg ? "markdown" : "rich text")")
                editorState.requestEditorModeToggle()
            } label: {
                Text(editorState.editorMode.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            // Stable identity for this Button independent of any dynamic content elsewhere in
            // the status bar (bug-fix round, ship-fix/fullsuite-round2) -- belt-and-braces
            // alongside the `CenterIndicatorSizer` extraction above.
            .id("status-bar-editor-mode-badge")
            // Plain `.help(...)` inherits AppKit's system-wide help-tag delay (~1-1.5s,
            // not configurable per-view in SwiftUI), which read as sluggish for this
            // frequently-hovered badge. Custom onHover + delayed overlay instead, same
            // Task.sleep + cancel-on-new-hover pattern as
            // OutlineSidebar.maybeShowSubtreeDragHint. `.accessibilityHint` replaces the
            // VoiceOver description `.help(...)` used to provide.
            .onHover { hovering in
                editorModeTooltipTask?.cancel()
                if hovering {
                    editorModeTooltipTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        showEditorModeTooltip = true
                    }
                } else {
                    showEditorModeTooltip = false
                }
            }
            .overlay(alignment: .top) {
                if showEditorModeTooltip {
                    Text("\(editorState.editorMode.switchToLabel) (⌘/)")
                        .font(.caption)
                        .foregroundColor(themeManager.currentTheme.tooltipText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(themeManager.currentTheme.tooltipBackground)
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        )
                        .fixedSize()
                        .offset(y: -28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .accessibilityHint(Text("\(editorState.editorMode.switchToLabel) (⌘/)"))
            .accessibilityIdentifier("status-bar-editor-mode")

            if editorState.focusModeEnabled {
                Text("Focus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.accentColor.opacity(0.3))
                    .cornerRadius(4)
                    .accessibilityIdentifier("status-bar-focus")
            }
        }
        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(themeManager.currentTheme.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-bar")
        .onReceive(NotificationCenter.default.publisher(for: .proofingConnectionStatusChanged)) { _ in
            editorState.proofingConnectionStatus = SpellCheckService.shared.connectionStatus
        }
        .onReceive(NotificationCenter.default.publisher(for: .proofingModeChanged)) { _ in
            editorState.proofingConnectionStatus = SpellCheckService.shared.connectionStatus
        }
    }

    private var displayTitle: String {
        editorState.currentSectionName.isEmpty ? "No section" : editorState.currentSectionName
    }

    /// Must-fix 2 (review-fix round): the zoom pill's visible label. Deliberately NOT `private`
    /// -- `@testable import` needs this to assert the degrade-gracefully path directly (see
    /// `ZoomExitPillTests`) without standing up SwiftUI's render pipeline.
    var zoomPillLabel: String {
        guard let section = editorState.zoomedSection else { return "Zoomed" }
        return "Zoomed: \(section.title.isEmpty ? "Untitled" : section.title)"
    }

    /// VoiceOver counterpart to `zoomPillLabel` -- same degrade-gracefully rule.
    var zoomAccessibilityLabel: String {
        guard let section = editorState.zoomedSection else { return "Zoomed" }
        return "Zoomed into \(section.title.isEmpty ? "Untitled" : section.title)"
    }

    /// The merged center indicator's visible text: `zoomPillLabel` ("Zoomed: <heading>",
    /// degrading to a bare "Zoomed") while zoomed, `displayTitle` otherwise. Deliberately NOT
    /// `private` -- same testability reasoning as `zoomPillLabel` itself.
    var centerIndicatorLabel: String {
        editorState.zoomedSectionId != nil ? zoomPillLabel : displayTitle
    }

    /// VoiceOver counterpart to `centerIndicatorLabel`.
    var centerIndicatorAccessibilityLabel: String {
        editorState.zoomedSectionId != nil ? zoomAccessibilityLabel : displayTitle
    }

    /// Must-fix E (review-fix round): one Title-Case phrase for the exit-zoom button's tooltip
    /// AND its VoiceOver label -- they used to differ ("All Sections" vs. "Exit zoom"), two
    /// names for the same action (contract §5, "one concept, one word, everywhere"). Deliberately
    /// NOT `private` -- same testability reasoning as `zoomPillLabel` and friends above.
    var zoomExitActionLabel: String { "Exit Zoom" }

    /// Same rationale as `zoomExitActionLabel` immediately above, applied to its pill sibling:
    /// one Title-Case phrase for the outline button's tooltip AND its VoiceOver label, so two
    /// adjacent tooltips inside the same merged pill (this control's own doc comment at the top
    /// of `body`) agree on casing instead of one reading "Exit Zoom" and the other "Document
    /// outline". Deliberately NOT `private` -- same testability reasoning as `zoomExitActionLabel`.
    var documentOutlineActionLabel: String { "Document Outline" }

    // outlinePopover, statusColor(for:), proofingIndicator, proofingStatusColor,
    // proofingStatusText, and proofingStatusPopover live in StatusBar+Popovers.swift, moved
    // there to keep this struct's body under SwiftLint's type_body_length limit.

    /// Word count display text. Priority: selection ("X of Y words") >
    /// zoomed section ("X of Y words") > goal ("X/Y words") > plain ("X words").
    /// Uses filteredTotalWordCount for consistency with sidebar (respects excludeBibliography)
    private var wordCountDisplay: String {
        let total = editorState.filteredTotalWordCount
        if let selected = editorState.selectedWordCount {
            return "\(selected) of \(total) words"
        }
        if let zoomed = editorState.zoomedFilteredWordCount {
            return "\(zoomed) of \(total) words"
        }
        if let goal = editorState.documentGoal {
            return "\(total)/\(goal) words"
        }
        return "\(total) words"
    }
}

/// Hidden width-measurement sizer for the merged center section indicator (see `StatusBar.body`'s
/// own doc comment where this is used). Extracted into its own `View` so `editorState.sections`
/// is an Observation dependency of ONLY this small subview's `body`, not of the whole `StatusBar`
/// view -- see the call site's doc comment for the full regression this isolates.
///
/// All titles overlap in the `ZStack`, which gets the width of the widest. Also measures each
/// title's "Zoomed: " variant -- the visible zoomed text (`centerIndicatorLabel`) is longer than
/// the plain title -- so the pill's width stays stable across zoom in/out instead of visibly
/// growing on zoom-in. Measures against `editorState.sections` (the whole document), never
/// `editorState.outlineSections` -- the latter is zoom-filtered to just the zoomed subtree
/// (`EditorViewState+Sections.swift`), so the moment the user zooms in, the candidate set would
/// collapse to a smaller set of (typically shorter) titles at the exact same moment the visible
/// label grows by the "Zoomed: " prefix, shrinking the pill and truncating its own label.
/// Measuring the unfiltered list keeps the widest-title candidate (and the widest "Zoomed: "
/// variant) available regardless of zoom state.
private struct CenterIndicatorSizer: View {
    let editorState: EditorViewState

    var body: some View {
        ZStack {
            ForEach(editorState.sections) { section in
                Text(section.title.isEmpty ? "Untitled" : section.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            ForEach(editorState.sections) { section in
                Text("Zoomed: \(section.title.isEmpty ? "Untitled" : section.title)")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

#Preview {
    StatusBar(editorState: EditorViewState(), onExitZoom: {})
        .environment(ThemeManager.shared)
}
