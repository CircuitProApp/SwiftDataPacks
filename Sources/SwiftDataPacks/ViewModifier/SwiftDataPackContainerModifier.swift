import SwiftUI
import SwiftData

public struct SwiftDataPackContainerModifier: ViewModifier {
    @State private var manager: SwiftDataPackManager

    public init(models: [any PersistentModel.Type], configuration: SwiftDataPackManagerConfiguration) {
        _manager = State(wrappedValue: SwiftDataPackManager(for: models, config: configuration))
    }

    public func body(content: Content) -> some View {
        content
            .modelContainer(manager.container)
            .environment(manager)
    }
}

public extension View {
    func packContainer(for models: [any PersistentModel.Type],
                              configuration: SwiftDataPackManagerConfiguration = .init()) -> some View {
        self.modifier(SwiftDataPackContainerModifier(models: models, configuration: configuration))
    }
}
