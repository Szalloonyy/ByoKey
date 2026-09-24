//
//  ItemCardView.swift
//  RecallDrop
//
//  One capture in the grid: thumbnail, title, text preview, agent badge,
//  reminder and processing status.
//

import SwiftUI
import RecallDropKit

struct ItemCardView: View {
    let item: CapturedItem
    var highlightTerms: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let preview = previewText {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(item.hasImage ? 2 : 5)
                        .multilineTextAlignment(.leading)
                }

                footer
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var previewText: String? {
        if !highlightTerms.isEmpty, let text = item.extractedText,
           let snippet = SearchSnippet.make(from: text, terms: highlightTerms, radius: 50) {
            return snippet
        }
        return item.previewText
    }

    @ViewBuilder
    private var header: some View {
        if item.hasImage {
            Color.clear
                .aspectRatio(1 / item.aspectRatio, contentMode: .fit)
                .overlay {
                    CaptureImageView(cacheKey: item.thumbnailCacheKey, data: item.thumbnailData, maxPixelSize: 700)
                }
                .clipped()
                .overlay(alignment: .topTrailing) { cornerIcons }
        } else if item.kind == .link {
            linkHeader
        } else {
            HStack {
                Image(systemName: "quote.opening")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                cornerIcons
            }
            .padding([.horizontal, .top], 10)
        }
    }

    private var linkHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.sourceAppName ?? item.sourceURL?.host ?? "Link")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let host = item.sourceURL?.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            cornerIcons
        }
        .padding([.horizontal, .top], 10)
    }

    @ViewBuilder
    private var cornerIcons: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.45), in: Circle())
                .padding(6)
                .accessibilityLabel("Pinned")
        }
    }

    @ViewBuilder
    private var footer: some View {
        let hasAgent = item.lastUsedAgentName != nil
        let isBusyOrFailed = item.processingState == .failed || item.processingState == .pending
            || item.processingState.isActive
        if hasAgent || item.reminderDate != nil || !item.openActionItems.isEmpty || isBusyOrFailed {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let name = item.lastUsedAgentName {
                        AgentBadge(emoji: item.lastUsedAgentEmoji ?? "🤖", name: name, color: item.lastUsedAgentColor,
                                   compact: item.reminderDate != nil)
                    }
                    if !item.openActionItems.isEmpty {
                        Label("\(item.openActionItems.count)", systemImage: "checklist")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(item.openActionItems.count) open steps")
                    }
                    Spacer(minLength: 0)
                    if let date = item.reminderDate {
                        ReminderBadge(date: date)
                    }
                }
                ProcessingBadge(item: item)
            }
            .padding(.top, 2)
        }
    }
}
