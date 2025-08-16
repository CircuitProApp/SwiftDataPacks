//
//  PackItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import SwiftUI
import SwiftData

struct PackItemsView: View {

    @Environment(\.modelContext)
    private var modelContext
    
    @Query(sort: \Component.name) private var components: [Component]

    var body: some View {
        VStack {
            List(components, id: \.id) { component in
                VStack(alignment: .leading) {
                    Text(component.name)
                    ForEach(component.footprints) { footprint in
                        Text("• \(footprint.name)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Pack Items")
        .frame(minWidth: 400, minHeight: 300)
    }
}
