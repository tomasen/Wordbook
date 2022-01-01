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
                .sheet(isPresented: $popSearchView ) {
                    SearchView(closeMyself: $popSearchView)
                }
                
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
        .foregroundColor(Color("fontLink"))
    }
}


struct DefaultView: View {
    @StateObject var app = AppStoreManager.shared
    
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
                Text("SharingView")
                    .foregroundColor(Color("fontLink"))
            }
            Spacer()
            if !app.isProUser {
                Divider()
                Button(action: {
                    app.subscribe()
                }) {
                    Text("Subscribe")
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
}


struct DefaultView_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            DefaultView()
        }
    }
}

