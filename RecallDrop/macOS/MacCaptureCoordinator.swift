//
//  MacCaptureCoordinator.swift
//  RecallDrop (macOS)
//
//  One place for the Mac capture actions, so the menu bar extra, the Drop
//  Shelf, global hotkeys, menu commands and the toolbar behave the same:
//  clipboard, interactive screen region, file import, quick note, windows.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RecallDropKit

@MainActor
final class MacCaptureCoordinator {
    static let shared = MacCaptureCoordinator()

    /// Captured from a live view; lets hotkeys and panels open SwiftUI windows.
    var openWindowAction: OpenWindowAction?

    private var environment: AppEnvironment { AppEnvironment.shared }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureScreen: Task { await captureScreenRegion() }
        case .captureClipboard: Task { await captureClipboard() }
        case .quickNote: QuickNotePanelController.shared.show()
        case .toggleDropShelf: DropShelfController.shared.toggle()
        }
    }

    // MARK: Capture

    func captureClipboard() async {
        let payload = MacPasteboard.readPayload()
        guard !payload.isEmpty else {
            notify("The clipboard is empty.")
            return
        }
        let items = await environment.capture.capture(payload)
        notify(items.isEmpty ? "Nothing on the clipboard could be captured." : "Captured from the clipboard.")
    }

    func captureScreenRegion() async {
        let shelfWasVisible = DropShelfController.shared.isVisible
        DropShelfController.shared.hide()
        defer { if shelfWasVisible { DropShelfController.shared.show() } }

        do {
            guard let data = try await ScreenCaptureService.captureInteractiveRegion() else { return }
            try await environment.capture.captureImage(data, kind: .screenshot)
            notify("Screenshot captured.")
        } catch ScreenCaptureService.CaptureError.permissionDenied {
            presentScreenRecordingAlert()
        } catch {
            notify(error.localizedDescription)
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import into RecallDrop"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let items = await environment.capture.capture(fileURLs: urls)
            notify("Imported \(items.count) item\(items.count == 1 ? "" : "s").")
        }
    }

    func capture(providers: [NSItemProvider], agentIDs: [UUID]? = nil) async -> Int {
        let items = await environment.capture.capture(providers: providers, options: .init(agentIDs: agentIDs))
        return items.count
    }

    // MARK: Windows

    func openMainWindow() {
        NSApp.activate()
        if let openWindowAction {
            openWindowAction(id: WindowID.main)
        } else if let url = URL(string: "recalldrop://open") {
            NSWorkspace.shared.open(url)
        }
    }

    func open(itemID: UUID) {
        NSApp.activate()
        if let openWindowAction {
            openWindowAction(id: WindowID.item, value: itemID)
        } else {
            environment.router.open(itemID: itemID)
            openMainWindow()
        }
    }

    func showNewNote() {
        environment.router.isNewNotePresented = true
        openMainWindow()
    }

    // MARK: Feedback

    private func notify(_ message: String) {
        if NSApp.isActive {
            environment.router.showToast(message)
        } else {
            // Started with a global shortcut from another app: no RecallDrop window is in front.
            MacHUD.shared.show(message)
        }
    }

    private func presentScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = "To capture a screen region, allow RecallDrop under System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch RecallDrop. You can always drop or paste screenshots instead."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, let url = ScreenCaptureService.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads the general pasteboard into a capture payload.
@MainActor
enum MacPasteboard {
    static func readPayload(_ pasteboard: NSPasteboard = .general) -> CapturedPayload {
        var payload = CapturedPayload()

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !fileURLs.isEmpty {
            for url in fileURLs where ImageProcessor.isImageFile(url) {
                if let data = try? Data(contentsOf: url) {
                    payload.images.append(.init(data: data, sourceURL: nil))
                }
            }
            if !payload.images.isEmpty { return payload }
        }

        let webURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { !$0.isFileURL }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)
        ]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                payload.images.append(.init(data: data, sourceURL: webURLs.first))
                return payload
            }
        }

        payload.urls = webURLs
        if payload.urls.isEmpty, let text = pasteboard.string(forType: .string)?.trimmedNonEmpty {
            payload.texts = [text]
        }
        return payload
    }
}
