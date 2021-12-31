//
//  WatchContentView.swift
//  Wordbook WatchKit Extension
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

struct WatchMasterView: View {
    @StateObject var icloud = iCloudState.shared
    
    var body: some View {
        VStack{
            Spacer()
            NavigationLink(destination: WatchCardView()) {
                HStack{
                    Spacer()
                    VStack{
                        Spacer()
                        Text("Today")
                        Spacer()
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .frame(height: 100)
            .background(LinearGradient(gradient: Gradient(colors: [.orange, .brown]), startPoint: .topLeading, endPoint: .trailing))
            .mask(RoundedRectangle(cornerRadius: 24))
            
            Spacer()
            HStack{
                Spacer()
                Image(systemName: icloud.enabled ? "icloud" : "icloud.slash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, alignment: .bottomTrailing)
                    .padding()
            }
            .foregroundColor(Color("fontGray"))
            .scenePadding()
        }
        .navigationTitle(Text("Wordbook").font(.caption))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchMasterView()
    }
}
