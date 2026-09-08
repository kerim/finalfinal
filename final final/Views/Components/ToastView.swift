//
//  ToastView.swift
//  final final
//
//  Renders `ToastCenter.shared.current` — see that type's doc comment for the queueing rules.
//  Hosted bottom-centre over the document by `ContentView`'s `.overlay(alignment: .bottom)`.
//  UX contract §4.1/D6, §7 (themed panel), §7a (toasts are a themed surface).
//

import SwiftUI

struct ToastView: View {
    @Environment(ThemeManager.self) private var themeManager
    let toast: Toast

    /// The plain-success default (§8's "toast or progress toast" example, "Version saved.",
    /// fades on this timing). A toast with a longer story to tell -- Export's action button,
    /// the Getting Started warning -- sets `Toast.fadeDelayOverride` instead; see
    /// `ToastFactory` for those durations.
    private static let fadeDelay: Duration = .seconds(3)

    var body: some View {
        let theme = themeManager.currentTheme

        HStack(spacing: Spacing.s12) {
            leadingIcon(theme: theme)

            Text(toast.message)
                .font(.uiBody)
                .foregroundStyle(theme.tooltipText)
                .accessibilityIdentifier("toast-message")

            if let action = toast.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.plain)
                    .font(.uiBody)
                    .underline()
                    .foregroundStyle(theme.tooltipText)
                    .accessibilityIdentifier("toast-action")
            }

            // No ✕ on a `.progress` toast: it isn't cancellable (§4.2 -- Cancel appears only for
            // an operation that can genuinely be stopped part-way, which none of today's
            // exports/prints are), so dismissing it would hide the progress indicator while the
            // operation keeps running with the menu still disabled and no visible explanation left at all.
            if toast.style != .progress {
                Button {
                    withAnimation {
                        ToastCenter.shared.dismissCurrent()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.uiCaption)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.tooltipText)
                .accessibilityIdentifier("toast-dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Spacing.s16)
        .padding(.vertical, Spacing.s12)
        .background(theme.tooltipBackground, in: RoundedRectangle(cornerRadius: CornerRadius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        // `.task(id:)` restarts whenever `toast.id` changes (a new toast landed in the slot) and
        // is cancelled the instant this view is torn down (the slot went empty) — so a fading
        // toast's timer never outlives the toast it belongs to, with no separate timer object
        // needed. `ToastCenter` itself stays timer-free; see its own doc comment.
        .task(id: toast.id) {
            guard toast.fades else { return }
            try? await Task.sleep(for: toast.fadeDelayOverride ?? Self.fadeDelay)
            guard !Task.isCancelled, ToastCenter.shared.current?.id == toast.id else { return }
            withAnimation {
                ToastCenter.shared.dismissCurrent()
            }
        }
    }

    @ViewBuilder
    private func leadingIcon(theme: AppColorScheme) -> some View {
        switch toast.style {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.tooltipText)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.tooltipText)
        case .progress:
            // A static glyph, not an animated spinner: most exports (Markdown, TextBundle, even
            // a short PDF) finish before an animated `ProgressView` could visibly draw even one
            // rotation, so a spinner here never actually appears in practice.
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.tooltipText)
        case .info:
            // Neutral, not `EmptyView()` -- an absent icon would leave `HStack`'s spacing as an
            // unexplained gap before the message text.
            Image(systemName: "info.circle.fill")
                .foregroundStyle(theme.tooltipText)
        }
    }
}
