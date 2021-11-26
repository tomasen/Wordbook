//
//  WordlistView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import CoreData

struct WordListView: View {
    @StateObject private var WordListVM = WordListViewModel()
    @FetchRequest var RecentAdded: FetchedResults<WordCard>
    
    private var didSave =  NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
    
    init() {
        let req = NSFetchRequest<WordCard>(entityName: "WordCard")
        req.predicate = NSPredicate(format:  "category >= %d",
                                    CardCategory.NEW.rawValue)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.createdAt, ascending: false)]
        req.fetchLimit = 10
        _RecentAdded = FetchRequest(fetchRequest: req)
    }
    
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
                            NavigationLink(destination: CardView(word)){
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
                
                if !RecentAdded.isEmpty {
                    Section(header: HStack{
                        Text("Recently Added")
                        Spacer()
                    }.padding(.vertical)) {
                        ForEach(RecentAdded, id: \.self)  { it in
                            NavigationLink(destination: CardView(it.word!)){
                                HStack (alignment: .firstTextBaseline){
                                    Text("\(it.word!)")
                                    Spacer()
                                    Text("review now")
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
