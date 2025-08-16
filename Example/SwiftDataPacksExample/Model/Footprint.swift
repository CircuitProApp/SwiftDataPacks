//
//  Footprint.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftData
import Foundation

@Model
final class Footprint {

    @Attribute(.unique)
    var id: UUID

    var name: String

    var component: Component?

    init(name: String, component: Component? = nil) {
        self.id = UUID()
        self.name = name
        self.component = component
    }
}
