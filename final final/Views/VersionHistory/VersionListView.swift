//
//  VersionListView.swift
//  final final
//
//  Left column showing scrollable list of version snapshots.
//

import SwiftUI

// MARK: - SnapshotListItem

struct SnapshotListItem: Identifiable {
    let snapshot: Snapshot
    var id: String { snapshot.id }

    /// Count # lines in markdown (cheap, no full parse)
    static func sectionCount(from markdown: String) -> Int {
        markdown.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .count
    }
}

// MARK: - VersionListView

/// Left column view showing scrollable list of version snapshots
struct VersionListView: View {
    let snapshots: [SnapshotListItem]
    @Binding var selectedSnapshotId: String?
    @Binding var showNamedOnly: Bool
    let onSelectSnapshot: (String) -> Void

    @Environment(ThemeManager.self) private var themeManager

    /// Lazily-computed word count cache (filled as rows scroll into view)
    @State private var wordCountCache: [String: Int] = [:]

    /// Group snapshots by time period
    private var groupedSnapshots: [(title: String, snapshots: [SnapshotListItem])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [SnapshotListItem] = []
        var yesterday: [SnapshotListItem] = []
        var thisWeek: [SnapshotListItem] = []
        var thisMonth: [SnapshotListItem] = []
        var older: [SnapshotListItem] = []

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)!
        let startOfMonth = calendar.date(byAdding: .month, value: -1, to: now)!

        for item in snapshots {
            if item.snapshot.createdAt >= startOfToday {
                today.append(item)
            } else if item.snapshot.createdAt >= startOfYesterday {
                yesterday.append(item)
            } else if item.snapshot.createdAt >= startOfWeek {
                thisWeek.append(item)
            } else if item.snapshot.createdAt >= startOfMonth {
                thisMonth.append(item)
            } else {
                older.append(item)
            }
        }

        var groups: [(String, [SnapshotListItem])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { groups.append(("This Month", thisMonth)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter toggle header
            Picker("Filter", selection: $showNamedOnly) {
                Text("All").tag(false)
                Text("Named").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // Snapshot list
            ScrollViewReader { proxy in
                List(selection: $selectedSnapshotId) {
                    ForEach(groupedSnapshots, id: \.title) { group in
                        SwiftUI.Section(header: Text(group.title).font(.caption).foregroundStyle(themeManager.currentTheme.sidebarTextSecondary)) {
                            ForEach(group.snapshots) { item in
                                SnapshotRowView(
                                    snapshot: item.snapshot,
                                    wordCountCache: $wordCountCache,
                                    allSnapshots: snapshots
                                )
                                .tag(item.snapshot.id)
                                .id(item.snapshot.id)
                                .listRowBackground(
                                    selectedSnapshotId == item.snapshot.id
                                        ? themeManager.currentTheme.sidebarSelectedBackground
                                        : themeManager.currentTheme.sidebarBackground
                                )
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
        }
        .background(themeManager.currentTheme.sidebarBackground)
    }
}

// MARK: - SnapshotRowView

/// Individual row for a snapshot in the list
struct SnapshotRowView: View {
    let snapshot: Snapshot
    @Binding var wordCountCache: [String: Int]
    let allSnapshots: [SnapshotListItem]

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false
    @State private var sectionCount: Int = 0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Word delta compared to the next (older) snapshot
    private var wordDelta: Int? {
        guard let currentCount = wordCountCache[snapshot.id] else { return nil }
        // Find this snapshot's index, then get the next (older) one
        guard let idx = allSnapshots.firstIndex(where: { $0.snapshot.id == snapshot.id }),
              idx + 1 < allSnapshots.count else { return nil }
        let olderSnapshotId = allSnapshots[idx + 1].snapshot.id
        guard let olderCount = wordCountCache[olderSnapshotId] else { return nil }
        return currentCount - olderCount
    }

    /// Section delta compared to the next (older) snapshot
    private var sectionDelta: Int? {
        guard sectionCount > 0 else { return nil }
        guard let idx = allSnapshots.firstIndex(where: { $0.snapshot.id == snapshot.id }),
              idx + 1 < allSnapshots.count else { return nil }
        let olderMarkdown = allSnapshots[idx + 1].snapshot.previewMarkdown
        let olderCount = SnapshotListItem.sectionCount(from: olderMarkdown)
        let delta = sectionCount - olderCount
        return delta != 0 ? delta : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1: name or date-only
            if snapshot.isNamed {
                Text(snapshot.name ?? "")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(themeManager.currentTheme.sidebarText)
                    .lineLimit(1)
            } else {
                Text(Self.dateOnlyFormatter.string(from: snapshot.createdAt))
                    .font(.body)
                    .foregroundStyle(themeManager.currentTheme.sidebarText)
                    .lineLimit(1)
            }

            // Line 2: full date+time for named, time-only for unnamed
            if snapshot.isNamed {
                Text(Self.dateTimeFormatter.string(from: snapshot.createdAt))
                    .font(.caption)
                    .foregroundStyle(themeManager.currentTheme.sidebarTextSecondary)
            } else {
                Text(Self.timeFormatter.string(from: snapshot.createdAt))
                    .font(.caption)
                    .foregroundStyle(themeManager.currentTheme.sidebarTextSecondary)
            }

            // Third line: always present for consistent row height
            HStack(spacing: 6) {
                if let delta = wordDelta, delta != 0 {
                    Text(delta > 0 ? "+\(delta) words" : "\(delta) words")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(deltaColor(for: delta))
                }

                if let sDelta = sectionDelta {
                    Text(sDelta > 0 ? "+\(sDelta) sections" : "\(sDelta) sections")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(deltaColor(for: sDelta))
                }

                // Fallback: show absolute word count when no deltas
                if (wordDelta == nil || wordDelta == 0) && sectionDelta == nil {
                    if let wc = wordCountCache[snapshot.id] {
                        Text("\(wc) words")
                            .font(.caption)
                            .foregroundStyle(themeManager.currentTheme.sidebarTextSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(snapshot.isNamed ? themeManager.currentTheme.accentColor.opacity(0.12) : .clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: snapshot.id) {
            // Lazy word count computation
            if wordCountCache[snapshot.id] == nil {
                wordCountCache[snapshot.id] = MarkdownUtils.wordCount(for: snapshot.previewMarkdown)
            }
            sectionCount = SnapshotListItem.sectionCount(from: snapshot.previewMarkdown)
        }
    }

    private func deltaColor(for delta: Int) -> Color {
        if delta > 0 {
            return themeManager.currentTheme.statusColors.deltaPositive
        } else {
            return themeManager.currentTheme.statusColors.deltaNegative
        }
    }
}
