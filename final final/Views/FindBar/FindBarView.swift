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
                .help(state.showReplace ? "Hide Replace" : "Show Replace (⌘H)")

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
