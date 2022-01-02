//
//  WordlistView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import CoreData

struct WordListView: View {
    @StateObject private var viewModel = WordListViewModel()
    private let formatter = RelativeDateTimeFormatter()
    
    var body: some View {
        VStack {
            List{
                if viewModel.recentLearned.count > 0 {
                    SectionListView(name: "Recently Learned",
                                    list: viewModel.recentLearned,
                                    withCopy: true,
                                    actionMore: {viewModel.recentLearned.increaseLimit()})
                }
                
                if viewModel.recentAdded.count > 0 {
                    SectionListView(name: "Recently Added",
                                    list: viewModel.recentAdded,
                                    withCopy: true,
                                    actionMore: {viewModel.recentAdded.increaseLimit()})
                }
                
                if viewModel.queueWords.count > 0 {
                    SectionListView(name: "Queue",
                                    list: viewModel.queueWords,
                                    actionMore: {viewModel.recentAdded.increaseLimit()})
                }
            }
            .onAppear{
                viewModel.update()
            }
        }
        .foregroundColor(Color("fontBody"))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func SectionListView(name: String,
                         list: WordEntryList,
                         withCopy: Bool = false,
                         actionMore: @escaping ()->()) -> some View {
        Section(
            header:
                HStack{
                    Text(name)
                    Spacer()
                    if withCopy {
                        Button(action: {
                            UIPasteboard.general.string = list.words.array().joined(separator: " ")
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
                .padding(.vertical)
        ) {
            ForEach(list.words) { word in
                NavigationLink(destination: CardView(word.text)){
                    HStack (alignment: .firstTextBaseline){
                        Text("\(word.text)")
                        Spacer()
                        Text("review \((word.dueDate != nil && word.dueDate! > Date()) ? formatter.localizedString(for: word.dueDate!, relativeTo: Date()) : "now")")
                            .font(.caption)
                            .foregroundColor(Color("fontGray"))
                    }
                }
            }
            .onDelete { indices in
                for idx in indices {
                    viewModel.delete(word: list.words[idx].text)
                }
            }
            
            if list.total < 0 || list.count < list.total {
                Button(action: {
                    actionMore()
                }) {
                    Text("more")
                }
            }
        }
    }
}

struct WordListView_Previews: PreviewProvider {
    static var previews: some View {
        WordListView()
            .environment(\.colorScheme, .dark)
    }
}
