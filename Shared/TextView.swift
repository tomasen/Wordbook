//
//  ArticleView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/24/21.
//

import SwiftUI

struct TextView: View {
    let text: String
    
    var body: some View {
        ScrollView {
            Text(text)
                .customFont(name: "AvenirNext-Regular", style: .body)
                .foregroundColor(Color("fontBody"))
                .padding(16)
        }
    }
}

struct ArticleView_Previews: PreviewProvider {
    static var previews: some View {
        TextView(text: "This is a text")
    }
}
