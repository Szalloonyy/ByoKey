//
//  RecallDropCommands.swift
//  RecallDrop (macOS)
//
//  Menu bar commands of the main window.
//

import SwiftUI

struct RecallDropCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                MacCaptureCoordinator.shared.showNewNote()
            }
            .keyboardShortcut("n")

            Button("Import Images…") {
                MacCaptureCoordinator.shared.importFiles()
            }
            .keyboardShortcut("o")

            Button("Capture from Clipboard") {
                Task { await MacCaptureCoordinator.shared.captureClipboard() }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Capture Screen Region") {
                Task { await MacCaptureCoordinator.shared.captureScreenRegion() }
            }

            Divider()

            Button("Show or Hide Drop Shelf") {
                DropShelfController.shared.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Button("Quick Note Panel") {
                QuickNotePanelController.shared.show()
            }
        }

        CommandMenu("Library") {
            ForEach(Array(LibraryScope.primary.enumerated()), id: \.offset) { index, scope in
                Button(scope.title) {
                    environment.router.showLibrary(scope)
                    MacCaptureCoordinator.shared.openMainWindow()
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Search") {
                environment.router.select(.search)
                MacCaptureCoordinator.shared.openMainWindow()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Agents") {
                environment.router.select(.agents)
                MacCaptureCoordinator.shared.openMainWindow()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
