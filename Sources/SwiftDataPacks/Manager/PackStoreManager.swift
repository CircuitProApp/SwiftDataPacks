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
        let url = try getUniquePackDirectoryURL(for: pack)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Generates a unique URL for a new pack directory without creating it.
    func getUniquePackDirectoryURL(for pack: Pack) throws -> URL {
        let baseName = sanitizeFilename(pack.title)
        var candidate = packsDirectoryURL.appendingPathComponent("\(baseName).pack", isDirectory: true)

        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        let shortID = String(pack.id.uuidString.prefix(8))
        candidate = packsDirectoryURL.appendingPathComponent("\(baseName)-\(shortID).pack", isDirectory: true)
        
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = packsDirectoryURL.appendingPathComponent("\(baseName) (\(i)).pack", isDirectory: true)
            i += 1
        }
        return candidate
    }
    
    /// Creates a document representation of a pack for exporting.
    func createExportDocument(for pack: InstalledPack) throws -> (PackDirectoryDocument, String) {
        let storeURL = pack.storeURL
        var files: [String: Data] = [:]

        // Main database file must exist
        files[pack.metadata.databaseFileName] = try Data(contentsOf: storeURL)
        
        // Include -wal and -shm files if they exist
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        if fm.fileExists(atPath: walURL.path) {
            files[walURL.lastPathComponent] = try Data(contentsOf: walURL)
        }
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        if fm.fileExists(atPath: shmURL.path) {
            files[shmURL.lastPathComponent] = try Data(contentsOf: shmURL)
        }

        let doc = PackDirectoryDocument(manifest: pack.metadata, databaseFiles: files)
        let suggestedName = sanitizeFilename(pack.metadata.title) + ".pack"
        
        return (doc, suggestedName)
    }

    /// Creates a document representation of a pack for exporting from a specific store URL.
    func createExportDocument(from storeURL: URL, metadata: Pack) throws -> (PackDirectoryDocument, String) {
        var files: [String: Data] = [:]

        // Main database file must exist
        files[metadata.databaseFileName] = try Data(contentsOf: storeURL)
        
        // Include -wal and -shm files if they exist
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        if fm.fileExists(atPath: walURL.path) {
            files[walURL.lastPathComponent] = try Data(contentsOf: walURL)
        }
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        if fm.fileExists(atPath: shmURL.path) {
            files[shmURL.lastPathComponent] = try Data(contentsOf: shmURL)
        }

        let doc = PackDirectoryDocument(manifest: metadata, databaseFiles: files)
        let suggestedName = sanitizeFilename(metadata.title) + ".pack"
        
        return (doc, suggestedName)
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
    
    func removeSQLiteSet(at main: URL) {
        let wal = URL(fileURLWithPath: main.path + "-wal")
        let shm = URL(fileURLWithPath: main.path + "-shm")
        if fm.fileExists(atPath: main.path) { try? fm.removeItem(at: main) }
        if fm.fileExists(atPath: wal.path) { try? fm.removeItem(at: wal) }
        if fm.fileExists(atPath: shm.path) { try? fm.removeItem(at: shm) }
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
