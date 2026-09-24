//
//  SearchAndFilterView.swift
//  RecallDrop
//
//  Instant search across OCR text, titles, notes, summaries and tags, with
//  filters for scope, kind, tag, agent and reminders. Supports the query
//  syntax of RecallDropKit.SearchQuery ("phrase", -word, #tag, is:pinned …).
//

import SwiftUI
import SwiftData
import RecallDropKit

struct SearchStack: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var router = environment.router
        NavigationStack(path: $router.searchPath) {
            SearchAndFilterView()
                .navigationDestination(for: UUID.self) { itemID in
                    ItemDetailView(itemID: itemID)
                }
        }
    }
}

struct SearchAndFilterView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case inbox = "Inbox"
        case pinned = "Pinned"
        case archive = "Archive"

        var id: String { rawValue }
    }

    enum DateRange: String, CaseIterable, Identifiable {
        case any = "Any Time"
        case today = "Today"
        case week = "Past 7 Days"
        case month = "Past 30 Days"

        var id: String { rawValue }

        func contains(_ date: Date, now: Date = Date()) -> Bool {
            switch self {
            case .any: true
            case .today: Calendar.current.isDateInToday(date)
            case .week: date >= now.addingTimeInterval(-7 * 86_400)
            case .month: date >= now.addingTimeInterval(-30 * 86_400)
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \CapturedItem.createdAt, order: .reverse) private var allItems: [CapturedItem]
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var searchText = ""
    @State private var scope: Scope = .all
    @State private var kind: CaptureKind?
    @State private var tag: String?
    @State private var agentName: String?
    @State private var remindersOnly = false
    @State private var openStepsOnly = false
    @State private var dateRange: DateRange = .any

    var body: some View {
        let query = SearchQuery(parsing: searchText)
        let results = results(for: query)

        VStack(spacing: 0) {
            filterBar
            Divider()
            if results.isEmpty {
                if query.isEmpty && !hasActiveFilters {
                    ContentUnavailableView {
                        Label("Search Your Captures", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search matches text inside screenshots, titles, summaries, notes and tags. Try \"exact phrase\", #tag, -exclude, is:pinned or has:reminder.")
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                ItemGridView(items: results, highlightTerms: query.highlightTerms)
            }
        }
        .background(Theme.canvasBackground)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Text, titles, notes, #tags…")
    }

    private var hasActiveFilters: Bool {
        scope != .all || kind != nil || tag != nil || agentName != nil || remindersOnly || openStepsOnly || dateRange != .any
    }

    private var allTags: [String] {
        var counts: [String: Int] = [:]
        for item in allItems {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                filterMenu(title: kind?.pluralLabel ?? "Kind", isActive: kind != nil) {
                    Button("Any Kind") { kind = nil }
                    ForEach(CaptureKind.allCases) { value in
                        Button {
                            kind = value
                        } label: {
                            Label(value.pluralLabel, systemImage: value.symbolName)
                        }
                    }
                }

                filterMenu(title: tag.map { "#\($0)" } ?? "Tag", isActive: tag != nil) {
                    Button("Any Tag") { tag = nil }
                    ForEach(allTags.prefix(40), id: \.self) { value in
                        Button("#\(value)") { tag = value }
                    }
                }

                filterMenu(title: agentName ?? "Agent", isActive: agentName != nil) {
                    Button("Any Agent") { agentName = nil }
                    ForEach(agents) { agent in
                        Button("\(agent.emoji) \(agent.displayName)") { agentName = agent.displayName }
                    }
                    Button("📱 \(LocalAnalysis.agentName)") { agentName = LocalAnalysis.agentName }
                }

                filterMenu(title: dateRange == .any ? "Date" : dateRange.rawValue, isActive: dateRange != .any) {
                    ForEach(DateRange.allCases) { range in
                        Button(range.rawValue) { dateRange = range }
                    }
                }

                Toggle(isOn: $remindersOnly) {
                    Label("Reminders", systemImage: "bell")
                }
                .toggleStyle(.button)

                Toggle(isOn: $openStepsOnly) {
                    Label("Open Steps", systemImage: "checklist")
                }
                .toggleStyle(.button)

                if hasActiveFilters {
                    Button("Reset") {
                        scope = .all
                        kind = nil
                        tag = nil
                        agentName = nil
                        remindersOnly = false
                        openStepsOnly = false
                        dateRange = .any
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .controlSize(.small)
        }
    }

    private func filterMenu<Content: View>(title: String, isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.18) : Theme.placeholderFill, in: Capsule())
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func results(for query: SearchQuery) -> [CapturedItem] {
        let foldedAgent = agentName.map(SearchText.fold)
        let now = Date()
        let candidates = allItems.filter { item in
            switch scope {
            case .all: break
            case .inbox: if item.isArchived { return false }
            case .pinned: if !item.isPinned { return false }
            case .archive: if !item.isArchived { return false }
            }
            if let kind, item.kind != kind { return false }
            if let tag, !item.tags.contains(tag) { return false }
            if remindersOnly, item.reminderDate == nil { return false }
            if openStepsOnly, item.openActionItems.isEmpty { return false }
            if !dateRange.contains(item.createdAt, now: now) { return false }
            if let foldedAgent {
                let names = item.agentRuns.map { SearchText.fold($0.agentName) }
                if !names.contains(foldedAgent) { return false }
            }
            return true
        }
        guard !query.isEmpty else { return candidates }
        return candidates
            .compactMap { item in SearchMatcher.score(query, record: item.searchRecord).map { (item, $0) } }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.createdAt > rhs.0.createdAt : lhs.1 > rhs.1 }
            .map(\.0)
    }
}
