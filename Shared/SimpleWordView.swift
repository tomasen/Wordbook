//
//  SimpleWordView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/7/22.
//

import SwiftUI

class SimpleWordViewModel: ObservableObject {
    func addToWordbook(_ word: String) {
        _ = WordManager.shared.addWordCard(word)
    }
    
    func isWordAlreadyExistInWordbook(_ word: String) -> Bool {
        WordManager.shared.IsWordCardExist(word)
    }
}

struct SimpleWordView: View {
    let word: String
    
    @Binding var closeMyself: Bool
    
    private let viewModel = SimpleWordViewModel()
    
    var body: some View {
        VStack{
            Text("\(word)")
                .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                .foregroundColor(Color("fontTitle"))
                .padding(17.6)
            
            ScrollView(.vertical) {
                DefinitionView(viewModel: CardViewModel(word))
            }
            Divider()
            HStack{
                Spacer()
                Button(action: {
                    viewModel.addToWordbook(word)
                    closeMyself.toggle()
                }) {
                    Text( viewModel.isWordAlreadyExistInWordbook(word) ? "BUMP" : "ADD")
                }
                Spacer()
                Divider()
                Spacer()
                Button(action: {
                    closeMyself.toggle()
                }) {
                    Text("CLOSE")
                }
                Spacer()
            }
            .modifier(FootViewStyle())
        }
        .padding(EdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .foregroundColor(Color("fontBody"))
        .background(Color(UIColor.secondarySystemBackground).edgesIgnoringSafeArea(.all))
    }
}

struct SimpleWordView_Previews: PreviewProvider {
    static var previews: some View {
        SimpleWordView(word: "line", closeMyself: .constant(true))
    }
}
