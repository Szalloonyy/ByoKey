//
//  LibraryView.swift
//  RecallDrop
//
//  A scoped view of the library (Inbox, Pinned, Reminders, Archive, a tag)
//  with instant filtering, kind filter, grid density and drag-and-drop
//  capture.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RecallDropKit

/// Navigation stack hosting the library and pushing item details.
struct LibraryStack: View {
    let scope: LibraryScope

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var router = environment.router
        NavigationStack(path: $router.libraryPath) {
            LibraryView(scope: scope)
                .navigationDestination(for: UUID.self) { itemID in
                    ItemDetailView(itemID: itemID)
                }
        }
    }
}

struct LibraryView: View {
    let scope: LibraryScope

    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \CapturedItem.createdAt, order: .reverse) private var allItems: [CapturedItem]

    @State private var searchText = ""
    @State private var kindFilter: CaptureKind?
    @State private var isDropTargeted = false

    var body: some View {
        let query = SearchQuery(parsing: searchText)
        let items = filteredItems(query: query)

        Group {
            if items.isEmpty {
                emptyState(isSearching: !query.isEmpty)
            } else {
                ItemGridView(items: items, highlightTerms: query.highlightTerms)
            }
        }
        .background(Theme.canvasBackground)
        .navigationTitle(scope.title)
        .searchable(text: $searchText, prompt: "Search text, titles, notes, #tags")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                viewOptionsMenu
            }
        }
        .onDrop(of: ItemProviderLoader.supportedTypes, isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                DropHighlightView(title: "Drop to Capture")
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Filtering

    private func filteredItems(query: SearchQuery) -> [CapturedItem] {
        var result = allItems.filter { item in
            switch scope {
            case .inbox: !item.isArchived
            case .pinned: item.isPinned && !item.isArchived
            case .reminders: item.reminderDate != nil
            case .archive: item.isArchived
            case .tag(let tag): item.tags.contains(tag) && !item.isArchived
            }
        }
        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }
        if !query.isEmpty {
            return result
                .compactMap { item in SearchMatcher.score(query, record: item.searchRecord).map { (item, $0) } }
                .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.createdAt > rhs.0.createdAt : lhs.1 > rhs.1 }
                .map(\.0)
        }
        switch scope {
        case .reminders:
            return result.sorted { ($0.reminderDate ?? .distantFuture) < ($1.reminderDate ?? .distantFuture) }
        case .inbox, .tag:
            return result.filter(\.isPinned) + result.filter { !$0.isPinned }
        case .pinned, .archive:
            return result
        }
    }

    // MARK: Toolbar

    private var viewOptionsMenu: some View {
        @Bindable var settings = environment.settings
        return Menu {
            Picker("Show", selection: $kindFilter) {
                Text("All Captures").tag(CaptureKind?.none)
                ForEach(CaptureKind.allCases) { kind in
                    Label(kind.pluralLabel, systemImage: kind.symbolName).tag(CaptureKind?.some(kind))
                }
            }
            Picker("Card Size", selection: $settings.gridDensity) {
                ForEach(GridDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
        } label: {
            Label("View Options", systemImage: kindFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        var options = CaptureService.Options()
        if case .tag(let tag) = scope { options.tags = [tag] }
        let pinDropped = scope == .pinned
        Task {
            let created = await environment.capture.capture(providers: providers, options: options)
            if pinDropped {
                for item in created { item.isPinned = true }
            }
            environment.router.showToast(created.isEmpty
                ? "Nothing to capture in that drop."
                : "Captured \(created.count) item\(created.count == 1 ? "" : "s").")
        }
        return true
    }

    // MARK: Empty states

    @ViewBuilder
    private func emptyState(isSearching: Bool) -> some View {
        if isSearching {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch scope {
            case .inbox:
                ContentUnavailableView {
                    Label("Nothing Captured Yet", systemImage: "tray.and.arrow.down")
                } description: {
                    Text(Self.inboxHint)
                }
            case .pinned:
                ContentUnavailableView("No Pinned Captures", systemImage: "pin",
                                       description: Text("Pin the captures you want to keep at hand."))
            case .reminders:
                ContentUnavailableView("No Reminders", systemImage: "bell",
                                       description: Text("Use “Remind Me” on a capture to resurface it later."))
            case .archive:
                ContentUnavailableView("Archive Is Empty", systemImage: "archivebox",
                                       description: Text("Archived captures stay searchable without cluttering your inbox."))
            case .tag(let tag):
                ContentUnavailableView("No Captures Tagged #\(tag)", systemImage: "number")
            }
        }
    }

    private static var inboxHint: String {
        #if os(macOS)
        "Drop screenshots, images or links here or on the Drop Shelf, paste with ⌘V, or use the menu bar icon."
        #else
        "Tap + to paste, pick photos, scan a document or save a link – or share from any app."
        #endif
    }
}

/// Dashed outline shown while something is dragged over a drop target.
struct DropHighlightView: View {
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label(title, systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
    }
}
