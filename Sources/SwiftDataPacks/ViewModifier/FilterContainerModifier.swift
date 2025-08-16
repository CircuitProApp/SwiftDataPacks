//
//  FilterContainerModifier.swift
//  Test
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

public struct FilterContainerModifier: ViewModifier {
    @Environment(SwiftDataPackManager.self) private var manager
    
    let sources: [ContainerSource]
    
    // By moving the logic into a computed property, we resolve the container
    // or the error *before* the body's ViewBuilder is invoked.
    private var containerResult: Result<ModelContainer, Error>? {
        let configurations = sources.compactMap { manager.configuration(for: $0) }
        
        // If there are no valid configurations, return nil to represent this state.
        guard !configurations.isEmpty else { return nil }

        do {
            // Try to create the container and return a success result.
            let container = try ModelContainer(for: manager.schema, configurations: configurations)
            return .success(container)
        } catch {
            // If it fails, return a failure result.
            return .failure(error)
        }
    }

    public func body(content: Content) -> some View {
        // Now, the body's logic is simple control flow that the ViewBuilder understands.
        if let result = containerResult {
            switch result {
            case .success(let composedContainer):
                // On success, inject the container.
                content
                    .modelContainer(composedContainer)
                
            case .failure:
                // On failure, show an error view.
                ContentUnavailableView("Error Loading Data",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("The specified data stores could not be loaded."))
            }
        } else {
            // If there were no sources to begin with, show the "no source" view.
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
