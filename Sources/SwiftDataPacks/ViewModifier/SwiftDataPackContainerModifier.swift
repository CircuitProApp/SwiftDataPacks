import SwiftUI
import SwiftData

public struct SwiftDataPackContainerModifier: ViewModifier {
    // We now use @State to hold the result of the failable initializer.
    @State private var result: Result<SwiftDataPackManager, Error>

    public init(models: [any PersistentModel.Type], configuration: SwiftDataPackManagerConfiguration) {
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
            content
                // Set up the default environment with the main, unified container
                .modelContainer(manager.mainContainer)
                // Also provide the manager itself to the environment for writes and pack management
                .environment(manager)
        case .failure(let error):
            // Show a critical, app-level error if the manager fails to initialize
            ContentUnavailableView {
                Label("Initialization Failed", systemImage: "xmark.octagon.fill")
            } description: {
                Text(error.localizedDescription)
            }
        }
    }
}

// Extension remains the same
public extension View {
    func packContainer(for models: [any PersistentModel.Type],
                              configuration: SwiftDataPackManagerConfiguration = .init()) -> some View {
        self.modifier(SwiftDataPackContainerModifier(models: models, configuration: configuration))
    }
}
