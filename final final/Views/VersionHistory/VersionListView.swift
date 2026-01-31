//
//  VersionListView.swift
//  final final
//
//  Left column showing scrollable list of version snapshots.
//

import SwiftUI

/// Left column view showing scrollable list of version snapshots
struct VersionListView: View {
    let snapshots: [Snapshot]
    @Binding var selectedSnapshotId: String?
    let onSelectSnapshot: (String) -> Void

    @Environment(ThemeManager.self) private var themeManager

    /// Group snapshots by time period
    private var groupedSnapshots: [(title: String, snapshots: [Snapshot])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [Snapshot] = []
        var yesterday: [Snapshot] = []
        var thisWeek: [Snapshot] = []
        var thisMonth: [Snapshot] = []
        var older: [Snapshot] = []

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)!
        let startOfMonth = calendar.date(byAdding: .month, value: -1, to: now)!

        for snapshot in snapshots {
            if snapshot.createdAt >= startOfToday {
                today.append(snapshot)
            } else if snapshot.createdAt >= startOfYesterday {
                yesterday.append(snapshot)
            } else if snapshot.createdAt >= startOfWeek {
                thisWeek.append(snapshot)
            } else if snapshot.createdAt >= startOfMonth {
                thisMonth.append(snapshot)
            } else {
                older.append(snapshot)
            }
        }

        var groups: [(String, [Snapshot])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { groups.append(("This Month", thisMonth)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedSnapshotId) {
                ForEach(groupedSnapshots, id: \.title) { group in
                    SwiftUI.Section(header: Text(group.title).font(.caption).foregroundStyle(themeManager.currentTheme.sidebarTextSecondary)) {
                        ForEach(group.snapshots) { snapshot in
                            SnapshotRowView(snapshot: snapshot, theme: themeManager.currentTheme)
                                .tag(snapshot.id)
                                .id(snapshot.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selectedSnapshotId) { _, newValue in
                if let id = newValue {
                    onSelectSnapshot(id)
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(themeManager.currentTheme.sidebarBackground)
    }
}

/// Individual row for a snapshot in the list
struct SnapshotRowView: View {
    let snapshot: Snapshot
    let theme: AppColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Star for named saves
                if snapshot.isNamed {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }

                // Display name
                Text(snapshot.displayName)
                    .font(.body)
                    .foregroundStyle(theme.sidebarText)
                    .lineLimit(1)
            }

            // Time
            Text(formattedTime)
                .font(.caption)
                .foregroundStyle(theme.sidebarTextSecondary)
        }
        .padding(.vertical, 4)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: snapshot.createdAt)
    }
}
