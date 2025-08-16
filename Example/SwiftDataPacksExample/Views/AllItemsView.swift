//
//  AllItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftDataPacks

struct AllItemsView: View {
    
    @Query private var allComponents: [Component]
    @PackManager private var manager
    @UserContext private var userContext
    @State private var newComponentName: String = ""
    
    // State for the file exporter
    @State private var isExporterPresented = false
    @State private var documentToExport: PackDirectoryDocument?
    @State private var suggestedExportName: String = ""
    
    @Binding var showEditable: Bool
    
    var body: some View {
        SectionView {
            HStack {
                Text("All Components")
                Spacer()
                Button {
                    showEditable.toggle()
                } label: {
                    Text(showEditable ? "Show All" : "Show User")
                }
                
            }
        } content: {
            List {
                if allComponents.isEmpty {
                    HStack {
                        Spacer()
                        ContentUnavailableView(
                            "No Items To Show",
                            systemImage: "tray",
                            description: Text("Create component below or install/create a pack.")
                        )
                        Spacer()
                    }
                } else {
                    ForEach(allComponents, id: \.id) { component in
                        Text(component.name)
                    }
                }
            }
        } footer: {
            HStack(spacing: 12) {
                TextField("New Component Name", text: $newComponentName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addNewComponent()
                }
                Spacer()
                Button("Export User as Pack") {
                    exportUserStore()
                }
                Button("Delete User") {
                    Task { await manager.DEBUG_deleteUserContainer() }
                }
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: documentToExport,
            contentType: .folder,
            defaultFilename: suggestedExportName
        ) { result in
            switch result {
            case .success(let url):
                print("Saved to \(url)")
            case .failure(let error):
                print("Save failed: \(error.localizedDescription)")
            }
        }
    }

    private func addNewComponent() {
        guard !newComponentName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let newComponent = Component(name: newComponentName)
        userContext.insert(newComponent)
        newComponentName = ""
    }
    
    private func exportUserStore() {
        do {
            // For this example, we'll use a timestamped name.
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH.mm"
            let packTitle = "User Backup \(dateFormatter.string(from: .now))"
            
            let (doc, name) = try manager.exportMainStoreAsPack(title: packTitle, version: 1)
            
            self.documentToExport = doc
            self.suggestedExportName = name
            self.isExporterPresented = true
            
        } catch {
            print("Export failed: \(error.localizedDescription)")
        }
    }
}
