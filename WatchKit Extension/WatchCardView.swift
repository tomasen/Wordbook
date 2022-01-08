//
//  WatchCardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

struct WatchCardView: View {
    @StateObject private var viewModel: CardViewModel
    @Binding private var closeMyself: Bool
    
    init(_ word: String = "") {
        _viewModel = StateObject(wrappedValue: CardViewModel(word))
        _closeMyself = .constant(false)
    }
    
    init(_ word: String = "", closeMyself: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: CardViewModel(word))
        _closeMyself = closeMyself
        // self.adding = true
    }
    
    var body: some View {
        VStack{
            ScrollView{
                Text("\(viewModel.word)")
                    .font(.title3)
                    .foregroundColor(Color("WatchListItemTitle"))
                
                Spacer()
                
                if let mnemonic = viewModel.mnemonic {
                    VStack(alignment: .leading){
                        Text("\(mnemonic)")
                    }
                    .padding(3)
                }
                
                if viewModel.senses.count > 0 {
                    VStack(alignment: .leading) {
                        ForEach(viewModel.senses) { ss in
                            VStack(alignment: .leading){
                                Text("\(ss.gloss).")
                                    .multilineTextAlignment(.leading)
                                    .padding(.bottom, 2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        
                        Spacer()
                    }
                    .font(.caption2)
                    .lineSpacing(2)
                    
                    if closeMyself {
                        Spacer()
                        Button(action: {
                            _ = WordManager.shared.addWordCard(viewModel.word)
                            closeMyself.toggle()
                        }) {
                            Text("Add")
                                .foregroundColor(Color("fontBody"))
                        }
                    }
                } else {
                    VStack{
                        Spacer()
                        Text("word not found")
                        Spacer()
                    }
                }
            }
        }
        .foregroundColor(Color("WatchListItemContent"))
        .onAppear{
            viewModel.validate()
            viewModel.fetchExplain()
        }
    }
}

struct WatchCardView_Previews: PreviewProvider {
    static var previews: some View {
        WatchCardView()
    }
}
