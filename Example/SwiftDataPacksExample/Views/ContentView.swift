//
//  ContentView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    
    @State private var showEditable: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            AllItemsView(showEditable: $showEditable)
                .if(showEditable) {
                    $0.filterContainer(for: .mainStore)
                }
             
            Divider()
            PacksView()
        }
    }
}



#Preview {
    ContentView()
}
