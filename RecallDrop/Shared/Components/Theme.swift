//
//  Theme.swift
//  RecallDrop
//
//  Colors and small style helpers shared by the app and the share extension.
//

import SwiftUI
import RecallDropKit

enum Theme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.35, green: 0.34, blue: 0.96), Color(red: 0.64, green: 0.31, blue: 0.94)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var placeholderFill: Color {
        Color.primary.opacity(0.06)
    }
}

extension AgentColor {
    var color: Color {
        switch self {
        case .purple: .purple
        case .indigo: .indigo
        case .blue: .blue
        case .cyan: .cyan
        case .teal: .teal
        case .mint: .mint
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

extension View {
    /// Rounded card with a hairline border, used by grid cells and panels.
    func cardStyle(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        self
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    /// Section container used in detail views.
    func panelStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: 14)
    }
}

/// A section header with an SF Symbol, used inside panels.
struct PanelHeader: View {
    let title: String
    let systemImage: String
    var trailing: AnyView?

    init(_ title: String, systemImage: String, trailing: AnyView? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}
