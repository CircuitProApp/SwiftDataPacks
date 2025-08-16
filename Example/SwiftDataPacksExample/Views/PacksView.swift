//
//  PacksView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import UniformTypeIdentifiers
import SwiftDataPacks

struct PacksView: View {

    @PackManager private var manager
    @State private var isPickingFile = false
    
    @State private var documentToExport: PackDirectoryDocument?
    @State private var exportSuggestedName: String = "Pack.pack"
    @State private var isExporting = false
    
    @State private var selectedPackID: UUID?
    
    var body: some View {
        SectionView {
            Text("Installed Packs")
        } content: {
            List {
                if manager.installedPacks.isEmpty {
                    HStack {
                        Spacer()
                        ContentUnavailableView(
                            "No Packs Installed",
                            systemImage: "shippingbox",
                            description: Text("Install a pack from a file or create a new mock pack to get started.")
                        )
                        Spacer()
                    }
                } else {
                    // Iterate directly over the manager's installedPacks property.
                    ForEach(manager.installedPacks) { pack in
                        packRow(for: pack)
                            .onTapGesture {
                                selectedPackID = pack.id
                            }
                    }
                }
            }
        } footer: {
            HStack(spacing: 12) {
                Button("Install Pack…") { isPickingFile = true }
                
                Menu("New Mock Pack") {
                    ForEach(MockDataGenerator.ComponentType.allCases, id: \.self) { type in
                        Button("New \(type.rawValue) Pack") {
                            let packTitle = "\(type.rawValue)s" // e.g. "Resistors"
                            manager.addMockPack(title: packTitle, readOnly: true) { context in
                                try? MockDataGenerator.generate(context: context, type: type, items: 10)
                            }
                        }
                    }
                }
                Spacer()
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                manager.installPack(from: url)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: documentToExport,
            contentType: .folder,
            defaultFilename: exportSuggestedName
        ) { result in
            if case .failure(let error) = result {
                print("Export failed: \(error.localizedDescription)")
            }
        }
        .sheet(item: $selectedPackID.toBinding()) { packID in
            PackItemsView()
                .filterContainer(for: .pack(id: packID))
        }
    }
    
    /// A view builder function to create a row for a single pack.
    @ViewBuilder
    private func packRow(for pack: InstalledPack) -> some View {
        HStack {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading) {
                Text(pack.metadata.title)
                    .fontWeight(.medium)
                Text(pack.directoryURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Export…", systemImage: "square.and.arrow.up") {
                exportPack(id: pack.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Export Pack")
            
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await manager.removePack(id: pack.id) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(.red)
            .help("Remove Pack")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPackID = pack.id
        }
    }
    
    private func exportPack(id: UUID) {
        do {
            let (doc, name) = try manager.packDirectoryDocument(for: id)
            documentToExport = doc
            exportSuggestedName = name
            isExporting = true
        } catch {
            print("Export prep failed: \(error.localizedDescription)")
        }
    }
}

