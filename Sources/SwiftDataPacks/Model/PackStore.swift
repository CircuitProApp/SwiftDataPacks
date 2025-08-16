//
//  PackStore.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import Foundation

public enum PackStore {
    /// Loads the list of installed packs from a JSON file at the specified URL.
    /// - Parameter url: The URL of the `installed_packs.json` file.
    /// - Returns: An array of `InstalledPack` objects. Returns an empty array if the file doesn't exist or is corrupted.
    static func load(from url: URL) -> [InstalledPack] {
        guard let data = try? Data(contentsOf: url),
              let packs = try? JSONDecoder().decode([InstalledPack].self, from: data)
        else {
            return []
        }
        return packs
    }

    /// Saves the list of installed packs to a JSON file at the specified URL.
    /// This method will create directories if needed and performs an atomic write.
    /// - Parameters:
    ///   - packs: The array of `InstalledPack` objects to save.
    ///   - url: The destination URL for the `installed_packs.json` file.
    static func save(_ packs: [InstalledPack], to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            
            let data = try JSONEncoder().encode(packs)
            try data.write(to: url, options: .atomic)
        } catch {
            print("FATAL: Could not save the pack store at \(url.path). Error: \(error)")
        }
    }
}
