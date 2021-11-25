//
//  WordcardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI

struct CardView: View {
    public var word: String = ""
    @StateObject private var cardVM = CardViewModel()
    
    var body: some View {
        Text("\(cardVM.word)")
            .onAppear{
                cardVM.UpdateWord(word)
            }
    }
}

struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        CardView()
    }
}
