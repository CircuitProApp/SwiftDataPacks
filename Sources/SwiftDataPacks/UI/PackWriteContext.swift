//
//  PackWriteContext.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//


import SwiftUI
import SwiftData

/// A proxy for `ModelContext` that provides a safe, transactional interface for
/// writing to the user's primary data store.
///
/// This object mimics the most common methods of `ModelContext` (`insert`, `delete`, `save`),
/// allowing for a familiar and ergonomic API in your views. Internally, it collects
/// all requested changes and executes them in a single, safe transaction against the
/// user's writable store when `save()` is called. This completely avoids the state
/// and concurrency issues that arise from using a long-lived, shared `ModelContext`.
public struct PackWriteContext {
    // A reference to the manager, which will be injected by the property wrapper.
    var manager: SwiftDataPackManager?

    // Internal "scratchpad" for pending changes.
    private var pendingInserts: [any PersistentModel] = []
    private var pendingDeletes: [any PersistentModel] = []
    
    /// A flag indicating if there are any unsaved changes.
    public var hasChanges: Bool {
        !pendingInserts.isEmpty || !pendingDeletes.isEmpty
    }
    
    /// Registers a model to be inserted when `save()` is called.
    public mutating func insert(_ model: any PersistentModel) {
        pendingInserts.append(model)
    }
    
    /// Registers a model to be deleted when `save()` is called.
    public mutating func delete(_ model: any PersistentModel) {
        pendingDeletes.append(model)
    }
    
    /// Commits all pending insertions and deletions in a single, safe transaction.
    ///
    /// This method uses the underlying `SwiftDataPackManager` to ensure all operations
    /// are performed only on the user's writable store. The pending changes are
    /// cleared after the transaction completes, whether it succeeds or fails.
    /// - Throws: Rethrows any error from the underlying save operation.
    @MainActor public mutating func save() throws {
        guard let manager else {
            fatalError("PackWriteContext cannot be used without a manager. Ensure it is created via the @UserWriteContext property wrapper.")
        }
        
        // Use a temporary copy of the changes so we can clear the originals.
        let inserts = pendingInserts
        let deletes = pendingDeletes
        
        // This is crucial: clear the pending changes *before* the transaction.
        // If the save fails, you don't want to try saving the same items twice.
        self.pendingInserts.removeAll()
        self.pendingDeletes.removeAll()
        
        // Perform the robust, transactional write.
        try manager.performWrite { realContext in
            for model in deletes {
                // If the model is not in the context, this find and delete is necessary
            
                     realContext.delete(model)
            
            }
            for model in inserts {
                realContext.insert(model)
            }
        }
    }
}
