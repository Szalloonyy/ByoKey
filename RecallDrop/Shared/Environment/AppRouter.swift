//
//  AppRouter.swift
//  RecallDrop
//
//  Navigation state shared by both platforms, so notifications, URLs,
//  menu bar actions and commands can open items and sheets.
//

import Foundation
import Observation

/// Library sections, used by the macOS sidebar and the iOS scope picker.
enum LibraryScope: Hashable, Sendable {
    case inbox
    case pinned
    case reminders
    case archive
    case tag(String)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .pinned: "Pinned"
        case .reminders: "Reminders"
        case .archive: "Archive"
        case .tag(let tag): "#\(tag)"
        }
    }

    var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .pinned: "pin"
        case .reminders: "bell"
        case .archive: "archivebox"
        case .tag: "number"
        }
    }

    static let primary: [LibraryScope] = [.inbox, .pinned, .reminders, .archive]
}

enum SidebarDestination: Hashable, Sendable {
    case library(LibraryScope)
    case search
    case agents
    case settings
}

enum AppTab: Hashable, Sendable {
    case library
    case search
    case agents
    case settings
}

@MainActor
@Observable
final class AppRouter {
    // macOS sidebar
    var sidebarSelection: SidebarDestination? = .library(.inbox)
    // iOS tabs
    var selectedTab: AppTab = .library
    var libraryScope: LibraryScope = .inbox

    /// Items pushed onto the library's navigation stack.
    var libraryPath: [UUID] = []
    var searchPath: [UUID] = []

    var isCapturePresented = false
    var isNewNotePresented = false
    var isFileImporterPresented = false

    /// Shown as a transient banner.
    var toastMessage: String?

    func open(itemID: UUID) {
        selectedTab = .library
        if case .library = sidebarSelection {} else {
            sidebarSelection = .library(libraryScope)
        }
        libraryPath = [itemID]
    }

    /// Sidebar selection by the user: switching sections starts at their root.
    func select(_ destination: SidebarDestination?) {
        guard destination != sidebarSelection else { return }
        sidebarSelection = destination
        libraryPath = []
        searchPath = []
        if case .library(let scope) = destination {
            libraryScope = scope
        }
    }

    func showLibrary(_ scope: LibraryScope) {
        libraryScope = scope
        sidebarSelection = .library(scope)
        selectedTab = .library
        libraryPath = []
    }

    func showToast(_ message: String) {
        toastMessage = message
    }

    /// Handles `recalldrop://item/<uuid>`, `recalldrop://capture` and `recalldrop://note`.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "recalldrop" else { return }
        switch url.host?.lowercased() {
        case "item":
            if let id = UUID(uuidString: url.lastPathComponent) { open(itemID: id) }
        case "capture":
            selectedTab = .library
            isCapturePresented = true
        case "note":
            isNewNotePresented = true
        case "search":
            selectedTab = .search
            sidebarSelection = .search
        default:
            break
        }
    }

    static func url(for itemID: UUID) -> URL {
        URL(string: "recalldrop://item/\(itemID.uuidString)")!
    }
}
