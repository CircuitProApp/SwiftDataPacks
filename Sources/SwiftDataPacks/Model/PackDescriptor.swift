//
//  PackDescriptor.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import Foundation

public struct PackDescriptor: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var fileURL: URL
    public var allowsSave: Bool = false
}
