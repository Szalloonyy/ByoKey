//
//  BackgroundActivity.swift
//  RecallDrop
//
//  Asks the system for extra time while an analysis finishes after the user
//  leaves the app (or closes the share sheet). Uses ProcessInfo's expiring
//  activity, which – unlike UIApplication background tasks – is available in
//  app extensions and on macOS.
//

import Foundation

final class BackgroundActivity: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    init(reason: String) {
        let semaphore = self.semaphore
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired {
                // Time is up: release the waiting block so the process can suspend.
                semaphore.signal()
            } else {
                // Keeping this block alive keeps the assertion alive.
                _ = semaphore.wait(timeout: .now() + 170)
            }
        }
    }

    func end() {
        semaphore.signal()
    }
}
