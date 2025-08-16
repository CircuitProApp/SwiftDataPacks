//
//  SwiftDataPackManagerConfiguration.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

public struct SwiftDataPackManagerConfiguration {
    public let mainStoreName: String

    public init(mainStoreName: String = "default") {
        self.mainStoreName = mainStoreName
    }
}
