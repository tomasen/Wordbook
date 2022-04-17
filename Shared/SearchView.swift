//
//  SearchView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/2/22.
//

import SwiftUI
import Combine

class SearchViewModel: ObservableObject {
    private var cancellable: AnyCancellable? = nil
    @Published var keyword = "" {
        didSet {
            checkHints()
        }
    }
    
    @Published var hints: [String] = []
    
    func checkHints() {
        hints = WordManager.shared.searchHints(keyword) ?? []
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
            } else if viewModel.hints.count == 0 {
                Text("type in the word that you want to add")
                    .foregroundColor(Color("fontGray"))
            } else if viewModel.hints.count == 1 {
                SimpleWordView(word: viewModel.hints.first!, closeMyself: $closeMyself)
            } else {
                List {
                    ForEach(viewModel.hints, id: \.self) { word in
                        Text("\(word)")
                            .onTapGesture {
                                // Show Card View
                                viewModel.keyword = word
                                showExplain = true
                            }
                    }
                }
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

