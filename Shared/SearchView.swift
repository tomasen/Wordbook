//
//  SearchView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/2/22.
//

import SwiftUI

class SearchViewModel: ObservableObject {
    @Published var keyword = "" {
        didSet{
            checkHints()
        }
    }
    @Published var hints: [String]?
    
    func checkHints() {
        hints = WordManager.shared.searchHints(keyword)
    }
    
    func addToWordbook() {
        _ = WordManager.shared.addWordCard(keyword)
        keyword = ""
    }
    
}

struct SearchView: View {
    @Binding var closeMyself: Bool
    
    @StateObject private var viewModel = SearchViewModel()
    
    @State private var showExplain = false
    
    var body: some View {
        VStack {
            if !showExplain {
                // search input box
                HStack{
                    Spacer()
                    // TODO: change keyboard's return key to add
                    TextField("add new word", text: $viewModel.keyword)
                        .introspectTextField { textField in
                            textField.becomeFirstResponder()
                        }
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .keyboardType(.alphabet)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Spacer()
                    
                    HStack{
                        Button(action: {
                            viewModel.addToWordbook()
                        }) {
                            Text("Add")
                        }
                        
                        Button(action: {
                            closeMyself.toggle()
                        }) {
                            Text("Cancel")
                        }
                    }.padding()
                }
            }
            if showExplain {
                SimpleWordView(word: viewModel.keyword, closeMyself: $closeMyself)                
            } else if let hints = viewModel.hints {
                if hints.count == 1 {
                    SimpleWordView(word: hints.first!, closeMyself: $closeMyself)
                } else {
                    List {
                        ForEach(hints, id: \.self) { word in
                            Text("\(word)")
                                .onTapGesture {
                                    // Show Card View
                                    viewModel.keyword = word
                                    showExplain = true
                                }
                        }
                    }
                }
            } else {
                Text("type in the word that you want to add")
                    .foregroundColor(Color("fontGray"))
            }
        }
        .customFont(name: "AvenirNext-Regular", style: .body)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Color("fontBody"))
        .background(Color(UIColor.secondarySystemBackground).edgesIgnoringSafeArea(.all))
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView(closeMyself: .constant(false))
    }
}
