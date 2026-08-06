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
                
                switch viewModel.explanationState {
                case .ready(let explanation):
                    VStack(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(explanation.partOfSpeech).")
                            VStack(alignment: .leading) {
                                Text(explanation.meaning)
                                    .multilineTextAlignment(.leading)
                                    .padding(.bottom, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !explanation.synonyms.isEmpty {
                                    Text("Similar: \(explanation.synonyms.joined(separator: ", "))")
                                }
                                HStack(alignment: .top) {
                                    Text("·")
                                    Text("\"\(explanation.example)\"")
                                        .italic()
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        if !explanation.memoryAid.isEmpty {
                            Divider()
                            Text(explanation.memoryAidText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                        Spacer()
                    }
                    .font(.caption2)
                    .lineSpacing(2)

                case .idle, .loading:
                    EmptyView()

                case .unavailable(let message):
                    VStack{
                        Spacer()
                        Text(message)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                }

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
