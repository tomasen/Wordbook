//
//  ContentView.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI
import CoreData

struct ContentView: View {    
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
                
                List {
                    
                }
                .tabItem {
                    VStack{
                        Image(systemName: "book")
                        Text("Lexicon")
                    }
                }
                .tag(2)
                
            }
            Text("Select an item")
        }
    }
}


struct DefaultView: View {
    var body: some View {
        NavigationLink(destination: CardView()) {
            Text("Start")
        }
    }
}

