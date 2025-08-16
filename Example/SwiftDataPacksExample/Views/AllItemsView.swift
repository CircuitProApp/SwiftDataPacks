//
//  AllItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData
import SwiftDataPacks

struct AllItemsView: View {
    
    @Query private var allComponents: [Component]
    @PackManager private var manager
    
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
                    addNewComponent()
                }
                
            
                
                Spacer()
            }

        }
    }
    
    private func addNewComponent() {
        do {
            // This is it. This is the clean, robust API.
            try manager.performWrite { context in
                let newComponent = Component(name: "New User Component")
                context.insert(newComponent)
            }
        } catch {
            print("Failed to save new component: \(error)")
        }
    }
}
