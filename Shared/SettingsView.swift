//
//  SwiftUIView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/23/21.
//

import SwiftUI

struct SettingsView: View {
    
    var body: some View {
        VStack{
            Spacer()
            List{
                Section() {
                    HStack{
                        Text("Preferred Vocab")
                        Spacer()
                        Text("SAT")
                    }
                    HStack{
                        Text("Language")
                        Spacer()
                        Text("CN")
                    }
                }
                Section() {
                    NavigationLink(destination: TextView(text: String.getContentOfFile("about", "txt"))
                                    .onTapGesture(count: 5) {
                        AppStoreManager.shared.enableProFeatures(true)
                    }
                    ){
                        Text("About")
                    }
                    NavigationLink(destination: EmptyView()){
                        Text("Disclaim")
                    }
                }
            }
            Spacer()
        }
        .foregroundColor(Color("fontBody"))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}

struct SwiftUIView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}