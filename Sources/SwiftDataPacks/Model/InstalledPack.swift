//
//  InstalledPack.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

/// Represents a data pack installed into the application.
/// Each pack resides in its own folder inside the app’s Packs directory, e.g. "Resistors.pack".
public struct InstalledPack: Hashable, Identifiable, Codable {
    /// Core metadata of the pack. The `id` from this is used for identification.
    public let metadata: Pack

    /// The URL of the pack’s folder on disk (…/Packs/<Title>.pack).
    public var directoryURL: URL

    /// A flag indicating if the pack's database can be written to.
    public var allowsSave: Bool = false

    /// Identifiable conformance.
    public var id: UUID { metadata.id }

    /// The URL of the SwiftData store inside the pack folder.
    public var storeURL: URL {
        directoryURL.appendingPathComponent(metadata.databaseFileName)
    }
}
