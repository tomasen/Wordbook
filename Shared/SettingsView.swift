//
//  SwiftUIView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/23/21.
//

import SwiftUI

struct SettingsView: View {
    init() {
//       UITableView.appearance().separatorStyle = .none
//       UITableViewCell.appearance().backgroundColor = .none
//       UITableView.appearance().backgroundColor = .none
    }
    
    var body: some View {
        VStack{
            Spacer()
            List{
                Section() {
                    HStack{
                        Text("Language")
                        Spacer()
                        Text("CN")
                    }
                }
                Section() {
                    NavigationLink(destination: EmptyView()){
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
