//
//  IOSRootView.swift
//  RecallDrop (iOS)
//
//  Tab-based root: Library (masonry grid with a floating capture button),
//  Search, Agents and Settings.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct IOSRootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var router = environment.router
        TabView(selection: $router.selectedTab) {
            IOSLibraryTab()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)

            SearchStack()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            AgentsStack()
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(AppTab.agents)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .appChrome()
    }
}

private struct IOSLibraryTab: View {
    @Environment(AppEnvironment.self) private var environment
    @Query private var items: [CapturedItem]

    var body: some View {
        @Bindable var router = environment.router
        NavigationStack(path: $router.libraryPath) {
            LibraryView(scope: router.libraryScope)
                // The scope menu hangs off the title, which needs the inline style.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu {
                    ForEach(LibraryScope.primary, id: \.self) { scope in
                        Button {
                            router.showLibrary(scope)
                        } label: {
                            Label(scope.title, systemImage: scope.symbolName)
                        }
                    }
                    let tags = topTags
                    if !tags.isEmpty {
                        Menu {
                            ForEach(tags, id: \.self) { tag in
                                Button("#\(tag)") { router.showLibrary(.tag(tag)) }
                            }
                        } label: {
                            Label("Tags", systemImage: "number")
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    FloatingActionButton {
                        router.isCapturePresented = true
                    }
                    .padding(20)
                }
                .navigationDestination(for: UUID.self) { itemID in
                    ItemDetailView(itemID: itemID)
                }
        }
        .sheet(isPresented: $router.isCapturePresented) {
            CaptureSheet()
        }
        .sheet(isPresented: $router.isNewNotePresented) {
            NewNoteSheet()
        }
    }

    private var topTags: [String] {
        var counts: [String: Int] = [:]
        for item in items where !item.isArchived {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(25).map(\.key)
    }
}

/// The round "+" button floating over the library.
struct FloatingActionButton: View {
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.brandGradient, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Capture")
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
    }
}
