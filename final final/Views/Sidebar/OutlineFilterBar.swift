//
//  OutlineFilterBar.swift
//  final final
//

import SwiftUI

/// Filter bar for the outline sidebar
/// Provides status filtering dropdown
struct OutlineFilterBar: View {
    @Binding var selectedFilter: SectionStatus?
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            Menu {
                Button {
                    selectedFilter = nil
                } label: {
                    HStack {
                        Text("All")
                        if selectedFilter == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(SectionStatus.allCases, id: \.self) { status in
                    Button {
                        selectedFilter = status
                    } label: {
                        HStack {
                            Circle()
                                .fill(themeManager.currentTheme.statusColors.color(for: status))
                                .frame(width: 8, height: 8)
                            Text(status.displayName)
                            if selectedFilter == status {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(filterLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterLabel: String {
        guard let filter = selectedFilter else {
            return "All"
        }
        return filter.displayName
    }
}

#Preview {
    @Previewable @State var filter: SectionStatus?

    VStack {
        OutlineFilterBar(selectedFilter: $filter)
        Divider()
        Text("Selected: \(filter?.displayName ?? "All")")
    }
    .frame(width: 300)
    .environment(ThemeManager.shared)
}
