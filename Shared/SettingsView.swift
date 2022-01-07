//
//  SwiftUIView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/23/21.
//

import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var perf = UserPreferences.shared
}

struct SettingsView: View {
    let iap = InAppPurchaseManager.shared
    
    @StateObject var viewModel = SettingsViewModel()
    
    var body: some View {
        VStack{
            Spacer()
            List{
                Section() {
                    Picker("Daily Goal", selection: $viewModel.perf.dailyGoal) {
                        ForEach(Array(stride(from: 5, through: 100, by: 5)), id: \.self) { v in
                            Text("\(v) words").tag(v)
                        }
                    }
                
                    Picker("Translation Language", selection: $viewModel.perf.translationLanguageCode) {
                        ForEach(Array(viewModel.perf.translationLanguageManifest.keys.sorted()), id: \.self) { key in
                            Text(viewModel.perf.translationLanguageManifest[key]!).tag(key)
                        }
                    }
                
                    Picker("Test Prep Book", selection: $viewModel.perf.testPrepBook) {
                        ForEach(Array(viewModel.perf.testPrepBooks.enumerated()), id: \.offset) { idx, book in
                            Text(book).tag(idx)
                        }
                    }
                }
                Section() {
                    NavigationLink(destination: TextView(text: String.getContentOfFile("privacy", "txt")).onTapGesture(count: 5) {
                        #if DEBUG
                        InAppPurchaseManager.shared.toggleSuperUser()
                        #endif
                    }){
                        Text("Privacy Policy")
                    }
                    NavigationLink(destination: TextView(text: String.getContentOfFile("about", "txt")).onTapGesture(count: 5) {
                        #if DEBUG
                        InAppPurchaseManager.shared.toggleProFeatures()
                        #endif
                    }
                    ){
                        Text("About")
                    }
                    HStack{
                        Text(iap.isProSubscriber ? "Pro Subscriber" : "Free User")
                        Spacer()
                        if iap.isSuperUser {
                            Text("Super User")
                        }
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
