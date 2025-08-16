//
//  PackDirectoryDocument.swift
//  Test
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import UniformTypeIdentifiers
import SwiftUI

struct PackDirectoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.folder, UTType.package] }
    static var writableContentTypes: [UTType] { [UTType.folder] }

    let files: [String: Data] // filename -> bytes

    init(files: [String: Data]) { self.files = files }

    init(configuration: ReadConfiguration) throws {
        // We don’t import via this document; leave empty
        self.files = [:]
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for (name, data) in files {
            children[name] = FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
