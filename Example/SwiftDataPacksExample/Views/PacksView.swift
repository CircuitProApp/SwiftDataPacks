import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import SwiftDataPacks

private struct PackSelection: Identifiable, Hashable {
    let id: UUID
}

struct PacksView: View {
    @Environment(SwiftDataPackManager.self) private var hub
    @State private var picking = false

    @State private var exportDirDoc: PackDirectoryDocument?
    @State private var exportSuggestedName: String = "Pack.pack"
    @State private var exporting = false

    @State private var selection: PackSelection?
    
    // This query now correctly shows ALL components from ALL packs.
    @Query private var allComponents: [Component]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed Packs").font(.headline)

            List {
//                ForEach(hub.installedPacks, id: \.id) { pack in
//                    HStack {
//                        Text(pack.title)
//                        Spacer()
//                        Text(pack.fileURL.lastPathComponent)
//                            .foregroundStyle(.secondary)
//
//                        Button("Export…") {
//                            do {
////                                let (doc, name) = try hub.packDirectoryDocument(id: pack.id)
////                                exportDirDoc = doc
////                                exportSuggestedName = name
////                                exporting = true
//                            } catch {
//                                print("Export prep failed: \(error)")
//                            }
//                        }
//                        .buttonStyle(.borderless)
//
//                        Button("Remove") {
//                            Task { await hub.removePack(id: pack.id) }
//                        }
//                        .buttonStyle(.borderless)
//                    }
//                    .contentShape(Rectangle())
//                    .onTapGesture {
//                        selection = .init(id: pack.id)
//                    }
//                }
            }
            // A simple way to see that the main container is updating.
            .onAppear {
                print("Total components in main container: \(allComponents.count)")
            }

            HStack(spacing: 12) {
                Button("Install Pack…") { picking = true }
                    .fileImporter(
                        isPresented: $picking,
                        allowedContentTypes: [UTType.folder, UTType.package, UTType.data],
                        allowsMultipleSelection: false
                    ) { result in
//                        if case .success(let urls) = result, let url = urls.first {
//                            let id = "\(hub.config.appBundleID).pack.\(UUID().uuidString)"
//                            hub.installPack(from: url, id: id, title: url.deletingPathExtension().lastPathComponent)
//                        }
                    }

                // --- REPLACEMENT: Use a Menu for creating themed packs ---
                Menu("New Mock Pack") {
                    ForEach(MockDataGenerator.ComponentType.allCases, id: \.self) { type in
                        Button("New \(type.rawValue) Pack") {
                            // The title of the pack is now themed.
                            let packTitle = "\(type.rawValue) Pack"
                            hub.addMockPack(title: packTitle, readOnly: true) { context in
                                // Generate themed data for this pack.
                                try MockDataGenerator.generate(context: context, type: type, items: 8)
                            }
                        }
                    }
                }
                
                Spacer()
            }
        }
        .padding()
        .fileExporter(
            isPresented: $exporting,
            document: exportDirDoc,
            contentType: .folder,
            defaultFilename: exportSuggestedName
        ) { result in
            if case .failure(let error) = result {
                print("Export failed: \(error)")
            }
        }
        .sheet(item: $selection, onDismiss: { selection = nil }) { sel in
            // Your filter container modifier works perfectly here.
            PackItemsView()
                .filterContainer(for: .pack(id: sel.id))
        }
    }
}
