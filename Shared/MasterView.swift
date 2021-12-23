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
    
    var body: some View {
        NavigationView {
            TabView{
                DefaultView()
                    .tabItem {
                        VStack{
                            Image(systemName: "play.rectangle")
                            Text("Today")
                        }
                        .foregroundColor(Color("fontLink"))
                    }
                    .tag(1)
                
                WordListView()
                    .tabItem {
                        VStack{
                            Image(systemName: "book")
                            Text("Wordbook")
                        }
                        .foregroundColor(Color("fontLink"))
                    }
                    .tag(2)
                
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
                .padding()
        }
        .foregroundColor(Color("fontBody"))
    }
    
    func trailingBarItem() -> some View {
        HStack{
            Button( action:{
                //self.showingSearchSheet.toggle()
            } ) {
                Image(systemName: "magnifyingglass")
                    .padding()
            }
            
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(-90))
                    .padding()
            }
        }
        .foregroundColor(Color("fontLink"))
    }
}


struct DefaultView: View {
    var body: some View {
        VStack{
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
            NavigationLink(destination: SharingView()) {
                Text("WordCloud")
                    .foregroundColor(Color("fontLink"))
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 12+25, leading: 25, bottom: 12, trailing: 25))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}


struct DefaultView_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            DefaultView()
        }
    }
}

