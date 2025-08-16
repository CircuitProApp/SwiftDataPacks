//
//  PackManager.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI

/// A property wrapper that provides convenient access to the `SwiftDataPackManager`
/// from the SwiftUI environment.
///
/// Instead of writing `@Environment(SwiftDataPackManager.self)`, you can simply
/// use `@PackManager` for a cleaner, more domain-specific declaration.
@propertyWrapper
public struct PackManager: DynamicProperty {
    @Environment(SwiftDataPackManager.self) private var manager

    /// The wrapped value, which is the `SwiftDataPackManager` instance.
    public var wrappedValue: SwiftDataPackManager {
        manager
    }

    /// Initializes the property wrapper.
    public init() {}
}
