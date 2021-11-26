//
//  WordcardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI

struct CardView: View {
    @State var titleWord: String = ""
    @StateObject private var cardVM = CardViewModel()
    
    init(_ word: String = "") {
        _titleWord = State(initialValue: word)
    }
    
    var body: some View {
        VStack {
            Text("\(titleWord)")
                .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                .foregroundColor(Color("fontTitle"))
        }
        .onAppear{
            cardVM.UpdateWord(titleWord)
        }
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}

struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        CardView("word")
    }
}
