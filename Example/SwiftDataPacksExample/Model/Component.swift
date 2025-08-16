//
//  Component.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftData
import Foundation

@Model
final class Component {

    @Attribute(.unique)
    var id: UUID

    var name: String

    @Relationship(deleteRule: .cascade, inverse: \Footprint.component)
    var footprints: [Footprint] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
    }
}
