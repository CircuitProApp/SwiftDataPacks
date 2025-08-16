//
//  AllItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

struct AllItemsView: View {
    
    @Query private var allComponents: [Component]
    @Environment(\.modelContext) private var modelContext
    
    @Binding var showEditable: Bool
    
    var body: some View {
        SectionView {
            HStack {
                Text("All Components")
                Spacer()
                Button {
                    showEditable.toggle()
                } label: {
                    Text("Show Editable")
                }

            }
        } content: {
            List(allComponents, id: \.id) { component in
                Text(component.name)
            }
        } footer: {
            HStack(spacing: 12) {
                Button("Add New Component") {
                    let newComponent = Component(name: "New component")
                    modelContext.insert(newComponent)
                    do {
                        try modelContext.save()
                    } catch {
                        // Handle the save error, e.g., by logging it
                        print("Failed to save new component: \(error)")
                    }
                }
                
            
                
                Spacer()
            }

        }
    }
}
