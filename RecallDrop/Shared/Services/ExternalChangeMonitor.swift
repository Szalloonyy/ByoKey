//
//  ExternalChangeMonitor.swift
//  RecallDrop
//
//  The share extension writes to the shared store from another process.
//  It posts a Darwin notification afterwards; a running app picks it up and
//  refreshes its queries. When the app was not running, the timestamp in the
//  shared defaults tells it on the next activation.
//

import Foundation

@MainActor
final class ExternalChangeMonitor {
    static let shared = ExternalChangeMonitor()

    nonisolated static let notificationName = "com.recalldrop.store-did-change"

    private var handler: (() -> Void)?
    private var isObserving = false

    func start(onChange handler: @escaping () -> Void) {
        self.handler = handler
        guard !isObserving else { return }
        isObserving = true
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    ExternalChangeMonitor.shared.handler?()
                }
            },
            Self.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Called by the share extension after saving.
    nonisolated static func postChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
