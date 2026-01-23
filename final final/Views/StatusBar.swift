//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    var body: some View {
        HStack {
            Text("0 words")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("No section")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("WYSIWYG")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    StatusBar()
}
