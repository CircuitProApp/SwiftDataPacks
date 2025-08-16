//
//  Extensions.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

extension Optional {
    func toBinding() -> Binding<Wrapped?> {
        Binding<Wrapped?>(
            get: { self },
            set: { _ in } // This binding is read-only for triggering the sheet
        )
    }
}

extension Binding where Value == UUID? {
    func toBinding() -> Binding<UUID?> {
        self
    }
}
