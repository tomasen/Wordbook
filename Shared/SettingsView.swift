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
                    NavigationLink(destination: TextView(text: String.getContentOfFile("about", "txt")).onTapGesture(count: 5) {
                        InAppPurchaseManager.shared.toggleProFeatures()
                    }
                    ){
                        Text("About")
                    }
                    NavigationLink(destination: TextView(text: String.getContentOfFile("privacy", "txt")).onTapGesture(count: 5) {
                        InAppPurchaseManager.shared.toggleSuperUser()
                    }){
                        Text("Privacy Policy")
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
