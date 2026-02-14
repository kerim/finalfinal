//
//  OutlineSidebar+Components.swift
//  final final
//
//  Reusable view components for outline sidebar: badges, indicators, previews, breadcrumbs.
//

import SwiftUI

/// Floating badge showing the target header level during drag
/// Supports deep headers (H7+) with ######+N notation
struct DragLevelBadge: View {
    let level: Int
    @Environment(ThemeManager.self) private var themeManager

    /// Display text for the level badge
    private var levelText: String {
        if level <= 6 {
            return String(repeating: "#", count: level)
        } else {
            // Deep header: ######+N
            return String(repeating: "#", count: 6) + "+\(level - 6)"
        }
    }

    var body: some View {
        Text(levelText)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(themeManager.currentTheme.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 4)
    }
}

/// Visual indicator for drop insertion point between cards
/// Shows a prominent badge on the left side so it's visible above dragged cards
/// Uses fixed height for predictable overlay positioning
struct DropIndicatorLine: View {
    let level: Int

    @Environment(ThemeManager.self) private var themeManager

    /// Fixed height for predictable offset calculation in overlay positioning
    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            // Prominent badge on LEFT side (visible above card overlay)
            DragLevelBadge(level: level)

            Rectangle()
                .fill(themeManager.currentTheme.accentColor)
                .frame(height: 3)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
    }
}

/// Drag preview for subtree drag operations
/// Shows parent card with stacked shadow effect and "+N" badge
struct SubtreeDragPreview: View {
    let section: SectionViewModel
    let childCount: Int

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Stacked shadow effect - two layers behind
            if childCount > 1 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.sidebarBackground)
                    .frame(width: 280)
                    .offset(x: 6, y: 6)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }

            if childCount > 0 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.sidebarBackground)
                    .frame(width: 280)
                    .offset(x: 3, y: 3)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }

            // Main card
            SectionCardView(
                section: section,
                onSingleClick: {},
                onDoubleClick: { _ in },
                onSectionUpdated: nil
            )
            .frame(width: 280)
            .background(themeManager.currentTheme.sidebarBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.accentColor, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

            // Badge showing "+N" children count
            if childCount > 0 {
                Text("+\(childCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.accentColor)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
    }
}

/// Hint popup for first-time subtree drag discoverability
struct SubtreeDragHint: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "option")
                .font(.system(size: 14, weight: .medium))
            Text("Hold ⌥ while dragging to include child sections")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(themeManager.currentTheme.sidebarSelectedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

/// Zoom navigation breadcrumb bar
struct ZoomBreadcrumb: View {
    let zoomedSection: SectionViewModel?
    let onZoomOut: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        if let section = zoomedSection {
            HStack {
                Button {
                    onZoomOut()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("All Sections")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(.plain)

                Text("›")
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))

                Text(section.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(themeManager.currentTheme.sidebarBackground.opacity(0.95))
        }
    }
}
