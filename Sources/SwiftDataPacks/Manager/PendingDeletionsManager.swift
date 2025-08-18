//
//  PendingDeletionsManager.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/18/25.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "app.circuitpro.SwiftDataPacks", category: "PendingDeletionsManager")

// Encapsulates the logic for managing the pending deletions file.
internal enum PendingDeletionsManager {
    static func fileURL(storage: PackStorageManager) -> URL {
        storage.packsDirectoryURL.appendingPathComponent("pending_deletions.json")
    }

    static func load(storage: PackStorageManager) -> [UUID] {
        let url = fileURL(storage: storage)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([UUID].self, from: data)
        else {
            return []
        }
        return ids
    }

    static func save(_ ids: [UUID], storage: PackStorageManager) {
        let url = fileURL(storage: storage)
        do {
            let data = try JSONEncoder().encode(ids)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save pending deletions file: \(error)")
        }
    }
    
    static func add(id: UUID, storage: PackStorageManager) {
        var ids = load(storage: storage)
        if !ids.contains(id) {
            ids.append(id)
            save(ids, storage: storage)
        }
    }

    static func cleanup(storage: PackStorageManager) {
        let pendingIDs = Set(load(storage: storage))
        guard !pendingIDs.isEmpty else { return }
        
        let fm = FileManager.default
        guard let allPackDirs = try? fm.contentsOfDirectory(at: storage.packsDirectoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return
        }
        
        for dirURL in allPackDirs {
            guard dirURL.hasDirectoryPath else { continue }
            
            let manifestURL = dirURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let metadata = try? JSONDecoder().decode(Pack.self, from: data) else {
                continue
            }
            
            if pendingIDs.contains(metadata.id) {
                storage.removePackDirectory(at: dirURL)
                logger.info("Cleaned up pack '\(metadata.title)' marked for deletion.")
            }
        }
        
        save([], storage: storage)
    }
}
