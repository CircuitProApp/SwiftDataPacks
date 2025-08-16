//
//  PackStoreManager.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation
import SwiftData

/// Manages the file system storage for all data packs.
///
/// This struct is responsible for creating, deleting, and locating pack directories
/// and their contents, including the quarantine for pending deletions. It operates purely
/// at the file system level.
struct PackStorageManager {
    let fm = FileManager.default
    let rootURL: URL
    let schema: Schema

    /// The top-level directory where all pack folders are stored.
    var packsDirectoryURL: URL {
        rootURL.appendingPathComponent("Packs", isDirectory: true)
    }

    /// The directory for temporarily holding packs that are pending deletion.
    var quarantineDirectoryURL: URL {
        packsDirectoryURL.appendingPathComponent("PendingDeletion", isDirectory: true)
    }

    init(rootURL: URL, schema: Schema) {
        self.rootURL = rootURL
        self.schema = schema
    }

    /// Ensures the core directories (Packs, Quarantine) exist.
    func bootstrap() throws {
        try fm.createDirectory(at: packsDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: quarantineDirectoryURL, withIntermediateDirectories: true)
    }

    /// Creates a new, empty, and uniquely named directory for a pack.
    func createUniquePackDirectory(for pack: Pack) throws -> URL {
        let baseName = sanitizeFilename(pack.title)
        var candidate = packsDirectoryURL.appendingPathComponent("\(baseName).pack", isDirectory: true)

        if !fm.fileExists(atPath: candidate.path) {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
            return candidate
        }

        let shortID = String(pack.id.uuidString.prefix(8))
        candidate = packsDirectoryURL.appendingPathComponent("\(baseName) - \(shortID).pack", isDirectory: true)
        
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = packsDirectoryURL.appendingPathComponent("\(baseName) (\(i)).pack", isDirectory: true)
            i += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Copies the SQLite file set (store, wal, shm) from a source to a destination.
    func copySQLiteSet(from srcMain: URL, to destMain: URL) throws {
        try fm.createDirectory(at: destMain.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destMain.path) { try fm.removeItem(at: destMain) }
        try fm.copyItem(at: srcMain, to: destMain)

        let srcWal = URL(fileURLWithPath: srcMain.path + "-wal")
        let destWal = URL(fileURLWithPath: destMain.path + "-wal")
        if fm.fileExists(atPath: srcWal.path) {
            if fm.fileExists(atPath: destWal.path) { try? fm.removeItem(at: destWal) }
            try fm.copyItem(at: srcWal, to: destWal)
        }

        let srcShm = URL(fileURLWithPath: srcMain.path + "-shm")
        let destShm = URL(fileURLWithPath: destMain.path + "-shm")
        if fm.fileExists(atPath: srcShm.path) {
            if fm.fileExists(atPath: destShm.path) { try? fm.removeItem(at: destShm) }
            try fm.copyItem(at: srcShm, to: destShm)
        }
    }

    /// Removes an entire pack directory. If removal fails, moves it to quarantine.
    func removePackDirectory(at dir: URL) {
        guard fm.fileExists(atPath: dir.path) else { return }
        do {
            try fm.removeItem(at: dir)
        } catch {
            let dest = quarantineDirectoryURL.appendingPathComponent(dir.lastPathComponent)
            try? fm.moveItem(at: dir, to: dest)
        }
    }

    /// Empties the quarantine directory.
    func emptyQuarantine() {
        guard let items = try? fm.contentsOfDirectory(at: quarantineDirectoryURL, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
    
    /// Throws an error if a store file at the given URL cannot be opened.
    func validateStore(at url: URL) throws {
        let cfg = ModelConfiguration("validate-\(UUID().uuidString)", schema: schema, url: url, allowsSave: false)
        _ = try ModelContainer(for: schema, configurations: [cfg])
    }
    
    /// Sanitizes a string to be used as a valid filename component.
    private func sanitizeFilename(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = s.unicodeScalars.compactMap { illegal.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Pack" : trimmed
    }
}
