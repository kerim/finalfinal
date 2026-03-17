//
//  SectionTypography.swift
//  final final
//

import SwiftUI

/// Carbon-style typography gradient for section titles
/// H1: 28px light → H6: 14px bold
extension Font {
    static func sectionTitle(level: Int) -> Font {
        switch level {
        case 0:
            // Pseudo-section: same as H1 but italic would be applied separately
            return .system(size: 28, weight: .light)
        case 1:
            return .system(size: 28, weight: .light)
        case 2:
            return .system(size: 24, weight: .regular)
        case 3:
            return .system(size: 20, weight: .regular)
        case 4:
            return .system(size: 17, weight: .medium)
        case 5:
            return .system(size: 15, weight: .semibold)
        default:
            return .system(size: 14, weight: .bold)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Chapter One")
            .font(.sectionTitle(level: 1))
        Text("Introduction")
            .font(.sectionTitle(level: 2))
        Text("Background")
            .font(.sectionTitle(level: 3))
        Text("Context")
            .font(.sectionTitle(level: 4))
        Text("Details")
            .font(.sectionTitle(level: 5))
        Text("Notes")
            .font(.sectionTitle(level: 6))
    }
    .padding()
}
