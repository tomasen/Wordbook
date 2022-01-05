//
//  ContentView.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI
import CoreData

struct MasterView: View {
    @ObservedObject var icloud = iCloudState.shared
    @State private var tabSelection = 1
    @State private var popSearchView = false
    
    var body: some View {
        NavigationView {
            VStack{
                switch tabSelection {
                case 2:
                    WordListView()
                default:
                    TodaysView()
                }
                
                Divider()
                HStack{
                    Spacer()
                    VStack{
                        Image(systemName: "play.rectangle")
                        Text("Today")
                            .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .regular)
                            .padding(.top, 1)
                    }
                    .foregroundColor(tabSelection == 1 ? Color("fontLink") : Color("fontBody"))
                    .onTapGesture {
                        tabSelection = 1
                    }
                    
                    Spacer()
                    VStack{
                        Image(systemName: "book")
                        Text("Lexicon")
                            .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .regular)
                            .padding(.top, 1)
                    }
                    .foregroundColor(tabSelection == 2 ? Color("fontLink") : Color("fontBody"))
                    .onTapGesture {
                        tabSelection = 2
                    }
                    Spacer()
                }
                .padding(.top, 5)
            }
            .navigationBarTitle("Wordbook", displayMode:NavigationBarItem.TitleDisplayMode.inline)
            .navigationBarItems(leading: leadingBarItem(),
                                trailing: trailingBarItem())
            
            EmptyView()
        }
        .navigationViewStyle(.stack)
    }
    
    func leadingBarItem() -> some View {
        HStack{
            Image(systemName: icloud.enabled ? "icloud" : "icloud.slash")
                .imageScale(.medium)
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
                    .imageScale(.medium)
                    .padding(5)
            }
            
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "ellipsis")
                    .imageScale(.medium)
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

struct DefaultView_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            TodaysView()
        }
    }
}
