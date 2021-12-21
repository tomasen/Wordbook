//
//  ContentView.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI
import CoreData

struct MasterView: View {    
    var body: some View {
        NavigationView {
            TabView{
                DefaultView()
                    .tabItem {
                        VStack{
                            Image(systemName: "play.rectangle")
                            Text("Today")
                        }
                    }
                    .tag(1)
                
                WordListView()
                    .tabItem {
                        VStack{
                            Image(systemName: "book")
                            Text("Wordbook")
                        }
                    }
                    .tag(2)
                
            }
            .navigationBarTitle("Wordbook", displayMode:NavigationBarItem.TitleDisplayMode.inline)
            
            EmptyView()
        }
        .navigationViewStyle(.stack)
        
    }
}


struct DefaultView: View {
    var body: some View {
        VStack(){
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

