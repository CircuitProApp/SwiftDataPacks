//
//  SectionView.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import SwiftUI

struct SectionView<Header: View, Content: View, Footer: View>: View {
    
    @ViewBuilder
    var header: Header
    
    @ViewBuilder
    var content: Content
    
    @ViewBuilder
    var footer: Footer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            content
            
            footer
                .padding()
                .background(.bar)
        }
    }
}
