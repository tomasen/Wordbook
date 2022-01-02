//
//  ContentView.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI
import CoreData

struct MasterView: View {
    @StateObject var icloud = iCloudState.shared
    @State private var tabSelection = 1
    @State private var popSearchView = false
    
    var body: some View {
        NavigationView {
            VStack{
                switch tabSelection {
                case 2:
                    WordListView()
                default:
                    DefaultView()
                }
                
                Divider()
                HStack{
                    Spacer()
                    VStack{
                        Image(systemName: "play.rectangle")
                            .padding(3)
                        Text("Today")
                            .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .regular)
                    }
                    .foregroundColor(tabSelection == 1 ? Color("fontLink") : Color("fontBody"))
                    .onTapGesture {
                        tabSelection = 1
                    }
                    
                    Spacer()
                    VStack{
                        Image(systemName: "book")
                            .padding(3)
                        Text("Lexicon")
                            .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .regular)
                    }
                    .foregroundColor(tabSelection == 2 ? Color("fontLink") : Color("fontBody"))
                    .onTapGesture {
                        tabSelection = 2
                    }
                    Spacer()
                }
            }
            .navigationBarTitle("Wordbook", displayMode:NavigationBarItem.TitleDisplayMode.inline)
            .navigationBarItems(leading: leadingBarItem(),
                                trailing:              trailingBarItem())
            
            EmptyView()
        }
        .navigationViewStyle(.stack)
    }
    
    func leadingBarItem() -> some View {
        HStack{
            Image(systemName: icloud.enabled ? "icloud" : "icloud.slash")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .padding(5)
            Spacer()
        }
        .foregroundColor(Color("fontBody"))
    }
    
    func trailingBarItem() -> some View {
        HStack{
            Spacer()
            
            Button( action:{
                popSearchView.toggle()
            } ) {
                Image(systemName: "magnifyingglass")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                    .padding(5)
            }
            
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "ellipsis")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20)
                    .rotationEffect(.degrees(-90))
                    .padding(5)
            }
        }
        .sheet(isPresented: $popSearchView ) {
            SearchView(closeMyself: $popSearchView)
                .environment(\.colorScheme, .dark)
        }
        .foregroundColor(Color("fontLink"))
    }
}

class MasterViewModel: ObservableObject {
    @Published var totalWords: Int = 0
    @Published var totalLearningDays: Int = 0
    
    private let moc = CoreDataManager.shared.container.viewContext
    
    func update() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "category >= 0")
        totalWords = try! moc.count(for: req)
        
        totalLearningDays = CoreDataManager.shared.countBy("Engagement", pred: NSPredicate(format: "checked = true"))
    }
}

struct DefaultView: View {
    @StateObject var viewModel = MasterViewModel()
    @StateObject var app = AppStoreManager.shared
    
    var body: some View {
        VStack{
            NavigationLink(destination: SharingView()) {
                TodayStatusView()
            }
            
            OverallStatusView()
                .onAppear{
                    viewModel.update()
                }
            
            Spacer()
            HStack{
                Spacer()
                NavigationLink(destination: CardView()) {
                    Text("Start")
                        .customFont(name: "AvenirNext-Regular", style: .largeTitle)
                        .foregroundColor(Color("fontLink"))
                }
                Spacer()
            }
            Spacer()
            if !app.isProUser {
                Divider()
                Button(action: {
                    app.subscribe()
                }) {
                    Text("Upgrade")
                        .font(.callout)
                }
                .customFont(name: "AvenirNext-Medium", style: .body, weight: .medium)
                .buttonStyle(ChoiceButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 12+25, leading: 25, bottom: 12, trailing: 25))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func OverallStatusView() -> some View {
        VStack{
            HStack {
                VStack(alignment: .leading){
                    Text("Total")
                        .foregroundColor(Color("fontGray"))
                        .padding(.bottom, 4)
                    HStack (alignment: .firstTextBaseline) {
                        Text("\(viewModel.totalWords)")
                            .customFont(name: "Avenir-Medium", style: .title3)
                        Text("words")
                            .customFont(name: "AvenirNext-Regular", style: .footnote)
                        Spacer()
                    }
                }
                Spacer()
                VStack(alignment: .trailing){
                    Text("Ring Closed")
                        .foregroundColor(Color("fontGray"))
                        .padding(.bottom, 4)
                    HStack (alignment: .firstTextBaseline) {
                        Spacer()
                        Text("\(viewModel.totalLearningDays)")
                            .customFont(name: "Avenir-Medium", style: .title3)
                        Text("days")
                            .customFont(name: "AvenirNext-Regular", style: .footnote)
                    }
                }
            }
            .foregroundColor(Color("fontBody"))
            .padding(20)
        }
    }
}


struct DefaultView_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            DefaultView()
        }
    }
}

