//
//  SwiftDataPacksExampleApp.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftDataPacks

@main
struct SwiftDataPacksExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
                .packContainer(for: [Component.self, Footprint.self])
        }
    }
}
