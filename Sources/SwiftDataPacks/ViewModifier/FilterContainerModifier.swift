//
//  FilterContainerModifier.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
private enum ContainerLoadState {
    case available(ModelContainer)
    case unavailable
    case failed(source: ContainerSource, error: Error)

    struct PackNotFoundError: LocalizedError {
        var errorDescription: String? = "The pack's data files could not be found on disk."
    }
}

public struct FilterContainerModifier: ViewModifier {
    @Environment(SwiftDataPackManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    
    let sources: [ContainerSource]
    
    private var containerState: ContainerLoadState {
        guard !sources.isEmpty else {
            return .unavailable
        }

        if sources.count == 1 {
            let source = sources[0]
            
            guard let config = manager.configuration(for: source) else {
                return .failed(source: source, error: ContainerLoadState.PackNotFoundError())
            }
            
            do {
                let container = try ModelContainer(for: manager.schema, configurations: [config])
                return .available(container)
            } catch {
                return .failed(source: source, error: error)
            }
        }

        var allPossibleSources: [ContainerSource] = [.mainStore]
        allPossibleSources.append(contentsOf: manager.installedPacks.map { .pack(id: $0.id) })
        if Set(sources) == Set(allPossibleSources) {
            return .available(manager.mainContainer)
        }

        let configurations = sources.compactMap { manager.configuration(for: $0) }
        guard !configurations.isEmpty else { return .unavailable }
        
        if let container = try? ModelContainer(for: manager.schema, configurations: configurations) {
            return .available(container)
        } else {
            return .failed(source: .mainStore, error: PackManagerError.buildError("One or more data sources could not be loaded."))
        }
    }


    public func body(content: Content) -> some View {
        switch containerState {
        case .available(let container):
            content
                .modelContainer(container)

        case .unavailable:
            ContentUnavailableView(
                "No Data Source",
                systemImage: "questionmark.folder",
                description: Text("No valid data sources were specified.")
            )

        case .failed(let source, let error):
            if case .pack(let packID) = source, let pack = manager.installedPacks.first(where: { $0.id == packID }) {
                ContentUnavailableView {
                    Label("Failed to Load Pack", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text("The pack \"\(pack.metadata.title)\" could not be loaded.\n\(error.localizedDescription)")
                } actions: {
                    Button("Show Packs Directory", systemImage: "folder") {
                        showPacksDirectory()
                    }
                    
                    Button("Delete This Pack", role: .destructive) {
                        manager.removePack(id: packID)
                        dismiss()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Loading Failed",
                    systemImage: "xmark.octagon",
                    description: Text(error.localizedDescription)
                )
            }
        }
    }
    
    /// A helper function to open the parent "Packs" directory using the
    /// appropriate platform-specific API.
    private func showPacksDirectory() {
        let url = manager.packsDirectoryURL
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #else
        print("Packs directory location: \(url.path)")
        #endif
    }
}


extension View {
    public func filterContainer(for sources: [ContainerSource]) -> some View {
        self.modifier(FilterContainerModifier(sources: sources))
    }

    public func filterContainer(for source: ContainerSource) -> some View {
        self.modifier(FilterContainerModifier(sources: [source]))
    }

    public func filterContainer(for sources: ContainerSource...) -> some View {
        self.modifier(FilterContainerModifier(sources: sources))
    }
}
