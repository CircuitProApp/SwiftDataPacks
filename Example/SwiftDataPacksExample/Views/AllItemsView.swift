//
//  AllItemsView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftDataPacks

struct AllItemsView: View {
    
    @Query private var allComponents: [Component]
    @PackManager private var manager
    @UserContext private var userContext
    @State private var newComponentName: String = ""
    
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
                TextField("New Component Name", text: $newComponentName)
                    .textFieldStyle(.roundedBorder)
                Button("Add New Component") {
                    addNewComponent()
                }
                Spacer()
            }
        }
    }

    private func addNewComponent() {
        let newComponent = Component(name: newComponentName)
        userContext.insert(newComponent)
      
    }
}
