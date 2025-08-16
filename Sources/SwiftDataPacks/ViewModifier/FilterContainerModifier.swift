//
//  FilterContainerModifier.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

public struct FilterContainerModifier: ViewModifier {
    @Environment(SwiftDataPackManager.self) private var manager
    
    let sources: [ContainerSource]
    
    private var containerToShow: ModelContainer? {
        // Optimization: If only one source is requested, use a pre-built container.
        if sources.count == 1 {
            switch sources[0] {
            case .mainStore:
                return manager.userContainer
            case .pack:
                // For a single pack, we still build temporarily.
                break
            }
        }
        
        // --- FIX IS HERE ---
        // Build the `allPossibleSources` array in two steps to help the type checker.
        var allPossibleSources: [ContainerSource] = [.mainStore]
        allPossibleSources.append(contentsOf: manager.installedPacks.map { .pack(id: $0.id) })

        // Optimization: If all sources are selected, we can use the main container.
        if Set(sources) == Set(allPossibleSources) {
            return manager.mainContainer
        }
        // --- END FIX ---

        // Fallback to the original dynamic building logic if not optimized
        let configurations = sources.compactMap { manager.configuration(for: $0) }
        guard !configurations.isEmpty else { return nil }
        return try? ModelContainer(for: manager.schema, configurations: configurations)
    }

    public func body(content: Content) -> some View {
        if let container = containerToShow {
            content.modelContainer(container)
        } else {
            ContentUnavailableView("No Data Source",
                                   systemImage: "questionmark.folder",
                                   description: Text("No valid data sources were specified."))
        }
    }
}

extension View {
    /// Filters the SwiftData environment to use a specific ModelContainer
    /// composed from one or more data sources.
    ///
    /// - Parameter sources: An array of `ContainerSource` items to include.
    /// - Returns: A view configured with the specified composed container.
    public func filterContainer(for sources: [ContainerSource]) -> some View {
        self.modifier(FilterContainerModifier(sources: sources))
    }

    /// Convenience modifier to filter the SwiftData environment for a single data source.
    public func filterContainer(for source: ContainerSource) -> some View {
        self.modifier(FilterContainerModifier(sources: [source]))
    }

    /// Convenience modifier to filter the SwiftData environment for a variadic list of data sources.
    public func filterContainer(for sources: ContainerSource...) -> some View {
        self.modifier(FilterContainerModifier(sources: sources))
    }
}
