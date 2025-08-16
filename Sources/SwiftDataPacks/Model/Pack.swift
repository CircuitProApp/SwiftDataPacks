//
//  Pack.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

/// Represents the core, portable metadata for a data pack.
/// This object is encoded into the `manifest.json` inside the `.pack` file.
public struct Pack: Codable, Hashable, Sendable {
    /// A unique, stable identifier for the pack.
    public let id: UUID
    
    /// The user-facing title of the pack (e.g., "Resistors Pack").
    public var title: String
    
    /// The version of the pack's content, used for updates.
    public let version: Int
    
    /// The filename of the main database file within the package.
    /// Best to keep this consistent, but having it in the manifest allows for future flexibility.
    public let databaseFileName: String

    public init(id: UUID, title: String, version: Int, databaseFileName: String = "database.store") {
        self.id = id
        self.title = title
        self.version = version
        self.databaseFileName = databaseFileName
    }
}
