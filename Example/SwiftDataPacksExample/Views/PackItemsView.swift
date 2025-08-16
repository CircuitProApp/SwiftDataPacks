//
//  PackItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import SwiftUI
import SwiftData

struct PackItemsView: View {
    @Query(sort: \Component.name) private var components: [Component]
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack {
            List(components) { component in
                VStack(alignment: .leading) {
                    Text(component.name)
                    ForEach(component.footprints) { footprint in
                        Text("• \(footprint.name)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    let newComponent = Component(name: "Some Component")
                    modelContext.insert(newComponent)
                } label: {
                    Text("Try to add a new component")
                }

            }
        }
        .navigationTitle("Pack Items")
        .frame(minWidth: 400, minHeight: 300)
    }
}
