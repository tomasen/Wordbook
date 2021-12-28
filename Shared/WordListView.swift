//
//  WordlistView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import CoreData

struct WordListView: View {
    @StateObject private var WordListVM = WordListViewModel()
    
    var body: some View {
        VStack {
            List{
                if WordListVM.Learned.count > 0 {
                    Text("learned")
                }
                Text("default")
            }
        }
        .foregroundColor(Color("fontBody"))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
                
    }
}

struct WordListView_Previews: PreviewProvider {
    static var previews: some View {
        WordListView()
            .environment(\.colorScheme, .dark)
    }
}
