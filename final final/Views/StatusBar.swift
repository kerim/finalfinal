//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager
    let editorState: EditorViewState
    let onExitZoom: () -> Void
    @AppStorage("isSpellingEnabled") private var spellingEnabled = true
    @AppStorage("isGrammarEnabled") private var grammarEnabled = true
    @AppStorage("isSmartQuotesEnabled") private var smartQuotesEnabled = true
    @State private var showProofingPopover = false
    @State private var showOutlinePopover = false
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
                            // Hidden sizer: all titles overlap, ZStack gets width of widest.
                            // Must-fix A (review-fix round): also measures each title's
                            // "Zoomed: " variant -- the visible zoomed text (centerIndicatorLabel)
                            // is longer than the plain title -- so the pill's width stays stable
                            // across zoom in/out instead of visibly growing on zoom-in.
                            //
                            // Bug-fix round (post-acceptance): must measure against
                            // `editorState.sections` (the whole document), never
                            // `editorState.outlineSections` -- the latter is zoom-filtered to just
                            // the zoomed subtree (EditorViewState+Sections.swift), so the moment
                            // the user zooms in, the candidate set collapses to a smaller set of
                            // (typically shorter) titles at the exact same moment the visible
                            // label grows by the "Zoomed: " prefix -- the pill would shrink and
                            // its own label would truncate. Measuring the unfiltered list keeps
                            // the widest-title candidate (and the widest "Zoomed: " variant)
                            // available regardless of zoom state, so the sizer's ideal width is
                            // constant across zoom in/out rather than jumping.
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
            .help(spellingEnabled ? "Spelling: on (⌘;)" : "Spelling: off (⌘;)")
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
            .help(grammarEnabled ? "Grammar: on (⌘⇧;)" : "Grammar: off (⌘⇧;)")
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

    // MARK: - Outline Popover

    private var outlinePopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if editorState.outlineSections.isEmpty {
                    Text("No headings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(editorState.outlineSections) { section in
                        Button {
                            showOutlinePopover = false
                            NotificationCenter.default.post(
                                name: .scrollToSection,
                                object: nil,
                                userInfo: ["sectionId": section.id]
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(for: section))
                                    .frame(width: 6, height: 6)
                                Text(section.title.isEmpty ? "Untitled" : section.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.leading, CGFloat((section.headerLevel - 1) * 16))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(
                                section.title == editorState.currentSectionName
                                    ? themeManager.currentTheme.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(4)
        }
        .frame(minWidth: 200, maxWidth: 300, maxHeight: 400)
    }

    private func statusColor(for section: SectionViewModel) -> Color {
        switch section.status {
        case .next:
            return .gray.opacity(0.3)
        case .writing:
            return .yellow
        case .waiting:
            return .orange
        case .review:
            return .blue
        case .final_:
            return .green
        }
    }

    // MARK: - Proofing Indicator

    private var proofingIndicator: some View {
        Button {
            showProofingPopover.toggle()
        } label: {
            Circle()
                .fill(proofingStatusColor)
                .frame(width: 8, height: 8)
        }
        .buttonStyle(.plain)
        .help(proofingStatusText)
        .accessibilityIdentifier("status-bar-proofing")
    }

    private var proofingStatusColor: Color {
        switch editorState.proofingConnectionStatus {
        case .connected: .green
        case .checking: .yellow
        case .disconnected, .authError, .rateLimited: .red
        }
    }

    private var proofingStatusText: String {
        switch editorState.proofingConnectionStatus {
        case .connected: "LanguageTool connected"
        case .checking: "Checking..."
        case .disconnected: "LanguageTool disconnected"
        case .authError: "Invalid API key"
        case .rateLimited: "Rate limited"
        }
    }

    private var proofingStatusPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(proofingStatusColor)
                    .frame(width: 10, height: 10)
                Text(proofingStatusText)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Text(ProofingSettings.shared.mode.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Proofing Preferences...") {
                showProofingPopover = false
                NotificationCenter.default.post(name: .openProofingPreferences, object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(12)
        .frame(minWidth: 200)
    }

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

#Preview {
    StatusBar(editorState: EditorViewState(), onExitZoom: {})
        .environment(ThemeManager.shared)
}
