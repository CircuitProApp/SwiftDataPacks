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

    public init(models: [any PersistentModel.Type], configuration: SwiftDataPackManagerConfiguration, defaultSources: [ContainerSource]?) {
        self.defaultSources = defaultSources
        do {
            let manager = try SwiftDataPackManager(for: models, config: configuration)
            _result = State(wrappedValue: .success(manager))
        } catch {
            _result = State(wrappedValue: .failure(error))
        }
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
        configuration: SwiftDataPackManagerConfiguration = .init(),
        defaultFilter sources: [ContainerSource]? = nil
    ) -> some View {
        self.modifier(SwiftDataPackContainerModifier(models: models, configuration: configuration, defaultSources: sources))
    }
}
