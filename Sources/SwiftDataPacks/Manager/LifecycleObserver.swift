//
//  LifecycleObserver.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/18/25.
//

import Foundation
import OSLog
import SwiftData

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let loLogger = Logger(subsystem: "app.circuitpro.SwiftDataPacks", category: "LifecycleObserver")

@MainActor
internal class LifecycleObserver {
    static let shared = LifecycleObserver()
    private var hasRun = false
    private let lock = NSLock()

    private init() {
        #if canImport(UIKit)
        let notificationName = UIApplication.didFinishLaunchingNotification
        #elseif canImport(AppKit)
        let notificationName = NSApplication.didFinishLaunchingNotification
        #else
        loLogger.warning("No application lifecycle notifications available for this platform. Pending deletions will not be cleaned up on launch.")
        return
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cleanupPendingDeletions),
            name: notificationName,
            object: nil
        )
    }

    @objc private func cleanupPendingDeletions() {
        lock.lock()
        defer {
            lock.unlock()
            // Clean up the observer after it has run to prevent any potential future calls.
            if hasRun {
                NotificationCenter.default.removeObserver(self)
            }
        }

        guard !hasRun else { return }

        loLogger.info("Application did finish launching. Performing pending deletions cleanup...")
        
        guard let rootURL = SwiftDataPackManager.getRootURL() else {
            loLogger.error("Could not determine root URL for cleanup. Aborting.")
            return
        }
        
        // The schema is not needed for cleanup operations, so we can pass a dummy one.
        let storage = PackStorageManager(rootURL: rootURL, schema: Schema([]))
        PendingDeletionsManager.cleanup(storage: storage)
        
        hasRun = true
    }
}
