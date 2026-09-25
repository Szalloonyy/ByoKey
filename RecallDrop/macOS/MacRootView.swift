//
//  MacRootView.swift
//  RecallDrop (macOS)
//
//  Main window: sidebar navigation (Inbox, Pinned, Reminders, Archive, Tags,
//  Search, Agents, Settings) and a capture toolbar.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RecallDropKit

struct MacRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \CapturedItem.createdAt, order: .reverse) private var items: [CapturedItem]

    var body: some View {
        @Bindable var router = environment.router
        NavigationSplitView {
            MacSidebar(items: items)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail(for: router.sidebarSelection)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                captureMenu
            }
        }
        .sheet(isPresented: $router.isNewNotePresented) {
            NewNoteSheet()
        }
        .fileImporter(isPresented: $router.isFileImporterPresented, allowedContentTypes: [.image, .plainText],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let created = await environment.capture.capture(fileURLs: urls)
                environment.router.showToast("Imported \(created.count) item\(created.count == 1 ? "" : "s").")
            }
        }
        .onPasteCommand(of: ItemProviderLoader.supportedTypes) { providers in
            Task {
                let created = await environment.capture.capture(providers: providers)
                if !created.isEmpty { environment.router.showToast("Captured from the clipboard.") }
            }
        }
        .appChrome()
        .onAppear {
            MacCaptureCoordinator.shared.openWindowAction = openWindow
        }
    }

    @ViewBuilder
    private func detail(for selection: SidebarDestination?) -> some View {
        switch selection {
        case .library(let scope):
            LibraryStack(scope: scope)
                .id(scope)
        case .search:
            SearchStack()
        case .agents:
            AgentsStack()
        case .settings:
            NavigationStack {
                SettingsView()
            }
        case nil:
            ContentUnavailableView("Choose a Section", systemImage: "sidebar.left")
        }
    }

    private var captureMenu: some View {
        Menu {
            Button {
                Task { await MacCaptureCoordinator.shared.captureClipboard() }
            } label: {
                Label("Capture from Clipboard", systemImage: "doc.on.clipboard")
            }
            Button {
                Task { await MacCaptureCoordinator.shared.captureScreenRegion() }
            } label: {
                Label("Capture Screen Region", systemImage: "rectangle.dashed")
            }
            Button {
                environment.router.isFileImporterPresented = true
            } label: {
                Label("Import Images…", systemImage: "photo.badge.plus")
            }
            Button {
                environment.router.isNewNotePresented = true
            } label: {
                Label("New Note", systemImage: "note.text.badge.plus")
            }
            Divider()
            Button {
                DropShelfController.shared.toggle()
            } label: {
                Label("Show or Hide Drop Shelf", systemImage: "tray.and.arrow.down")
            }
        } label: {
            Label("Capture", systemImage: "plus")
        } primaryAction: {
            environment.router.isNewNotePresented = true
        }
        .help("Capture (click for a note, hold for more)")
    }
}

private struct MacSidebar: View {
    let items: [CapturedItem]

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let router = environment.router
        List(selection: Binding(get: { router.sidebarSelection }, set: { router.select($0) })) {
            Section("Library") {
                ForEach(LibraryScope.primary, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.symbolName)
                        .badge(count(for: scope))
                        .tag(SidebarDestination.library(scope))
                }
            }

            let tags = tagCounts
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.tag) { entry in
                        Label(entry.tag, systemImage: "number")
                            .badge(entry.count)
                            .tag(SidebarDestination.library(.tag(entry.tag)))
                    }
                }
            }

            Section("RecallDrop") {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarDestination.search)
                Label("Agents", systemImage: "sparkles")
                    .tag(SidebarDestination.agents)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarDestination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            statusFooter
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        let busy = environment.pipeline.busyCount
        HStack(spacing: 6) {
            if busy > 0 {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing \(busy)…")
            } else if environment.settings.offlineOnly {
                Image(systemName: "lock.shield")
                Text("Offline Only")
            } else if environment.settings.aiUnavailableReason != nil {
                Image(systemName: "key")
                Text("No API key")
            } else {
                Image(systemName: "checkmark.circle")
                Text(environment.settings.provider.displayName)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func count(for scope: LibraryScope) -> Int {
        switch scope {
        case .inbox: items.filter { !$0.isArchived }.count
        case .pinned: items.filter { $0.isPinned && !$0.isArchived }.count
        case .reminders: items.filter { $0.reminderDate != nil }.count
        case .archive: items.filter(\.isArchived).count
        case .tag(let tag): items.filter { $0.tags.contains(tag) && !$0.isArchived }.count
        }
    }

    private var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items where !item.isArchived {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(30)
            .map { (tag: $0.key, count: $0.value) }
    }
}
