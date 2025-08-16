//
//  UserContext.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData
import OSLog

/// A property wrapper that provides direct access to the `ModelContext` for the
/// user's primary, writable data store.
///
/// This wrapper is the ideal tool for any operation—reads or writes—that should
/// *only* affect the user's own data, completely isolated from any installed read-only packs.
/// It provides a stable `ModelContext` instance for the lifetime of the view, mirroring
/// the behavior and ease-of-use of SwiftUI's native `@Environment(\.modelContext)`.
///
/// ### Usage
///
/// In your SwiftUI view, simply declare the property:
/// ```
/// @UserContext private var userContext
/// ```
///
/// You can now use `userContext` exactly as you would a standard `ModelContext`:
/// ```
/// // Writing data
/// let newItem = Component(name: "My New Item")
/// userContext.insert(newItem)
/// try userContext.save()
///
/// // Reading data
/// let request = FetchDescriptor<Component>()
/// let userComponents = try userContext.fetch(request)
/// ```

private let ucLogger = Logger(subsystem: "app.circuitpro.SwiftDataPacks", category: "UserContext")

@propertyWrapper
@MainActor
public struct UserContext: DynamicProperty {
    @Environment(SwiftDataPackManager.self) private var manager

    public init() {}

    public var wrappedValue: UserWriter {
        UserWriter(manager: manager)
    }
}

@MainActor
public struct UserWriter {
    private unowned let manager: SwiftDataPackManager

    init(manager: SwiftDataPackManager) {
        self.manager = manager
    }

    // MARK: - Simple API (auto-saves)

    // Insert into user store and save.
    public func insert<T: PersistentModel>(_ model: T) {
        do {
            try manager.performWrite { ctx in
                ctx.insert(model)
            }
        } catch {
            ucLogger.error("Insert failed: \(String(describing: error))")
        }
    }

    // Update only if this object exists in the user store.
    public func update<T: PersistentModel>(_ model: T, apply: (T) -> Void) {
        do {
            try manager.performWrite { ctx in
                if let local: T = try refetch(model, in: ctx) {
                    apply(local)
                } else {
                    // Not user-owned (likely from a pack) – refuse to modify
                    ucLogger.notice("Refused update of read-only pack item.")
                }
            }
        } catch {
            ucLogger.error("Update failed: \(String(describing: error))")
        }
    }

    // Delete only if user-owned.
    public func delete<T: PersistentModel>(_ model: T) {
        do {
            try manager.performWrite { ctx in
                if let local: T = try refetch(model, in: ctx) {
                    ctx.delete(local)
                } else {
                    ucLogger.notice("Refused delete of read-only pack item.")
                }
            }
        } catch {
            ucLogger.error("Delete failed: \(String(describing: error))")
        }
    }

    // Optional: batch multiple edits and save once.
    public func transaction(_ block: (ModelContext) throws -> Void) {
        do {
            try manager.performWrite(block)
        } catch {
            ucLogger.error("Transaction failed: \(String(describing: error))")
        }
    }

    // MARK: - Helpers (user store refetch)

    // Try to resolve the passed object inside the user store context.
    private func refetch<T: PersistentModel>(_ obj: T, in ctx: ModelContext) throws -> T? {
        let id = obj.persistentModelID
        var fd = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
        fd.fetchLimit = 1
        return try ctx.fetch(fd).first
    }
}
