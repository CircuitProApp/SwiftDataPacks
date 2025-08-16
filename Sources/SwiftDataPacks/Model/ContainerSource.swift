//
//  ContainerSource.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

/// Describes a specific source for a SwiftData ModelContainer within the pack management system.
public enum ContainerSource: Hashable, Identifiable {
    /// Represents the primary, user-writable data store.
    case mainStore
    
    /// Represents a specific, installed data pack, identified by its unique ID.
    case pack(id: UUID)

    /// Provides a stable, string-based ID for `Identifiable` conformance (e.g., for use in SwiftUI lists).
    public var id: String {
        switch self {
        case .mainStore:
            return "mainStore"
        case .pack(let id):
            return "pack-\(id.uuidString)"
        }
    }
}
