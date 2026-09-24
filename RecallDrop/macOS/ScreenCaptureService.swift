//
//  ScreenCaptureService.swift
//  RecallDrop (macOS)
//
//  Interactive screen capture using the system's own selection UI
//  (`screencapture -i`: drag for a region, Space for a window, Esc cancels).
//  Requires the Screen Recording permission.
//

import AppKit
import CoreGraphics

@MainActor
enum ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case toolFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "RecallDrop needs the Screen Recording permission to capture the screen."
            case .toolFailed(let status): "The screen capture tool failed (status \(status))."
            }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns the PNG data, or `nil` when the user cancelled the selection.
    static func captureInteractiveRegion() async throws -> Data? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "recalldrop-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -x no sound, -o no window shadow
        process.arguments = ["-i", "-x", "-o", fileURL.path(percentEncoded: false)]
        let status = try await run(process)

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            // No file and a clean exit means the user pressed Esc.
            if status == 0 { return nil }
            throw CaptureError.toolFailed(status)
        }
        return try Data(contentsOf: fileURL)
    }

    private static func run(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
