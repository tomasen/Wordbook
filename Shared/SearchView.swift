//
//  SearchView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/2/22.
//

import SwiftUI

class SearchViewModel: ObservableObject {
    @Published var keyword = ""
    
    var searchHints: [String]? {
        WordManager.shared.searchHints(keyword)
    }
    
    func addToWordbook() {
        _ = WordManager.shared.addWordCard(keyword)
        keyword = ""
    }
    
    func isWordAlreadyExistInWordbook() -> Bool {
        WordManager.shared.IsWordCardExist(keyword)
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
                VStack{
                    Text("\(viewModel.keyword)")
                        .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                        .foregroundColor(Color("fontTitle"))
                        .padding(17.6)
                    
                    Spacer()
                    
                    // TODO: DefinitionView()
                    
                    HStack{
                        Spacer()
                        Button(action: {
                            viewModel.addToWordbook()
                            closeMyself.toggle()
                        }) {
                            Text( viewModel.isWordAlreadyExistInWordbook() ? "BUMP" : "ADD")
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
                .onAppear{
                    
                }
                
            } else if let hints = viewModel.searchHints {
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
            } else {
                Text("type in the word that you want to add")
                    .foregroundColor(Color("fontGray"))
            }
        }
        .customFont(name: "AvenirNext-Regular", style: .body)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: Alignment.topLeading)
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView(closeMyself: .constant(false))
    }
}
