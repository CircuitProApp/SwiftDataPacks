//
//  PackRegistry.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

/// Manages the list of installed packs by reading from and writing to a JSON file.
///
/// This class encapsulates the logic for persisting the `InstalledPack` array,
/// providing a clean, in-memory source of truth that can be saved to disk.
@Observable
class PackRegistry {
    /// The current list of installed packs.
    private(set) var packs: [InstalledPack]
    
    /// The URL of the JSON file that stores the registry.
    private let storeURL: URL
    
    init(storeURL: URL) {
        self.storeURL = storeURL
        self.packs = Self.load(from: storeURL)
    }

    /// Adds a pack to the registry and sorts the list.
    func add(_ pack: InstalledPack) {
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
        sort()
    }
    
    /// Removes a pack from the registry by its ID.
    @discardableResult
    func remove(id: UUID) -> InstalledPack? {
        guard let index = packs.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return packs.remove(at: index)
    }

    /// Persists the current list of packs to the JSON file.
    func save() {
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(packs)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("FATAL: Could not save the pack registry at \(storeURL.path). Error: \(error)")
        }
    }
    
    private func sort() {
        packs.sort { $0.metadata.title.localizedCaseInsensitiveCompare($1.metadata.title) == .orderedAscending }
    }

    /// A static loader to read packs from a specific URL.
    private static func load(from url: URL) -> [InstalledPack] {
        guard let data = try? Data(contentsOf: url),
              let packs = try? JSONDecoder().decode([InstalledPack].self, from: data)
        else {
            return []
        }
        return packs
    }
}
