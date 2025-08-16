//
//  PackDirectoryDocument.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import UniformTypeIdentifiers
import SwiftUI

/// A `FileDocument` that represents a SwiftData Pack as a folder on disk.
///
/// This document is used for exporting. It takes a `Pack` metadata object and its
/// database files, and bundles them into a directory containing a `manifest.json`.
public struct PackDirectoryDocument: FileDocument {
    
    // MODIFIED: We now explicitly work with folders for both import and export.
    public static var readableContentTypes: [UTType] { [.folder] }
    public static var writableContentTypes: [UTType] { [.folder] }

    /// The core metadata for the pack, which will be saved as `manifest.json`.
    let manifest: Pack
    
    /// The raw data for the database files (e.g., "Database.store", "Database.store-wal").
    let databaseFiles: [String: Data]

    /// Creates a document ready for exporting.
    public init(manifest: Pack, databaseFiles: [String: Data]) {
        self.manifest = manifest
        self.databaseFiles = databaseFiles
    }

    /// This initializer is not used, as importing is handled directly by the `SwiftDataPackManager`.
    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    /// Generates the file structure for the pack folder.
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]

        // 1. Encode the type-safe `Pack` manifest to JSON data.
        let manifestData = try JSONEncoder().encode(manifest)
        children["manifest.json"] = FileWrapper(regularFileWithContents: manifestData)
        
        // 2. Add all the database files to the directory.
        for (name, data) in databaseFiles {
            children[name] = FileWrapper(regularFileWithContents: data)
        }

        // 3. Return a directory FileWrapper containing the manifest and database files.
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
