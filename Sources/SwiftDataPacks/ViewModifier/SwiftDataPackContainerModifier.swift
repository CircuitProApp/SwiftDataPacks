//
//  SwiftDataPackContainerModifier.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

public struct SwiftDataPackContainerModifier: ViewModifier {

    @State private var result: Result<SwiftDataPackManager, Error>
    let defaultSources: [ContainerSource]?

    public init(models: [any PersistentModel.Type], defaultSources: [ContainerSource]?) {
        self.defaultSources = defaultSources
        do {
            let manager = try SwiftDataPackManager(for: models)
            _result = State(wrappedValue: .success(manager))
        } catch {
            _result = State(wrappedValue: .failure(error))
        }
    }
    
    public init(manager: SwiftDataPackManager, defaultSources: [ContainerSource]?) {
        self.defaultSources = defaultSources
        // It doesn't need to do any work, just store the successful result.
        _result = State(wrappedValue: .success(manager))
    }

    public func body(content: Content) -> some View {
        switch result {
        case .success(let manager):
            Group {
                if let sources = defaultSources {
                    content
                        .filterContainer(for: sources)
                } else {
                    content
                        .modelContainer(manager.mainContainer)
                }
            }
            .environment(manager)
        case .failure(let error):
            ContentUnavailableView {
                Label("Initialization Failed", systemImage: "xmark.octagon.fill")
            } description: {
                Text(error.localizedDescription)
            }
        }
    }
}

public extension View {
    func packContainer(
        for models: [any PersistentModel.Type],
        defaultFilter sources: [ContainerSource]? = nil
    ) -> some View {
        self.modifier(SwiftDataPackContainerModifier(models: models, defaultSources: sources))
    }
}

public extension View {
    func packContainer(
        _ manager: SwiftDataPackManager,
        defaultFilter sources: [ContainerSource]? = nil
    ) -> some View {
        self.modifier(SwiftDataPackContainerModifier(manager: manager, defaultSources: sources))
    }
}
