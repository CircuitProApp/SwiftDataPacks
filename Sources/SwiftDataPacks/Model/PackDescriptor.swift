//
//  PackDescriptor.swift
//  Test
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import Foundation

struct PackDescriptor: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var fileURL: URL
    var allowsSave: Bool = false
}
