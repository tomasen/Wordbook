//
//  WordlistView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI

struct WordListView: View {
    @StateObject private var WordListVM = WordListViewModel()
    
    private var didSave =  NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
    
    var body: some View {
        VStack {
            List {
                if !WordListVM.Learned.isEmpty {
                    Section(header: HStack{
                        Text("Recently Learned")
                        Spacer()
                        Button(action: {
                            UIPasteboard.general.string = WordListVM.Learned.joined(separator: " ")
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                    }.padding(.vertical)) {
                        ForEach(WordListVM.Learned, id: \.self)  {word in
                            NavigationLink(destination: CardView(word: word)){
                                HStack (alignment: .firstTextBaseline){
                                    Text("\(word)")
                                    Spacer()
                                    Text("review again")
                                        .font(.caption)
                                        .foregroundColor(Color("fontGray"))
                                }
                            }
                            
                        }
                    }
                }
            }
            .onAppear{
                WordListVM.Update()
            }
            .onReceive(self.didSave) { _ in
                WordListVM.Update()
            }
        }
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}

struct WordListView_Previews: PreviewProvider {
    static var previews: some View {
        WordListView()
    }
}
