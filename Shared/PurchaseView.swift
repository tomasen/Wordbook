//
//  PurchaseView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/4/22.
//

import SwiftUI

struct PurchaseView: View {
    @Binding var closeMyself: Bool
    
    @StateObject var appStore = AppStoreManager.shared
    
    struct Feature: Identifiable {
        var imageName: String
        var color: Color
        var headline: String
        var content: String
        
        var id: String { headline }
    }
    
    let features: [Feature] = [Feature(imageName: "graduationcap",
                                       color: Color.orange,
                                       headline: "Better Explanation",
                                       content: "extremely learner friendly, without any loss in its thoroughness"),
                               Feature(imageName: "graduationcap",
                                       color: Color.pink,
                                       headline: "Extra Explain",
                                       content: "extremely learner friendly, without any loss in its thoroughness"),
                               Feature(imageName: "graduationcap",
                                       color: Color.pink,
                                       headline: "Web Explain",
                                       content: "extremely learner friendly, without any loss in its thoroughness"),
                               Feature(imageName: "graduationcap",
                                       color: Color.pink,
                                       headline: "Translation",
                                       content: "extremely learner friendly, without any loss in its thoroughness"),
                               Feature(imageName: "graduationcap",
                                       color: Color.pink,
                                       headline: "Extra Wiki",
                                       content: "extremely learner friendly, without any loss in its thoroughness")]
    
    var body: some View {
        VStack{
            VStack(alignment: .leading){
                HStack{
                    Text("Upgrade to Pro")
                        .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                        .foregroundColor(Color("fontTitle"))
                        .padding(.top, 20)
                    Spacer()
                    Button(action: {
                        closeMyself.toggle()
                    }) {
                        Image(systemName: "xmark")
                            .imageScale(.large)
                            .foregroundColor(Color("fontLink"))
                    }
                }
                
                HStack{
                    Button(action: {
                        appStore.validate()
                    }) {
                        Text("Restore Purchase")
                            .font(.caption)
                            .foregroundColor(Color("fontLink"))
                    }
                    Spacer()
                }
                
                ForEach(features) { feature in
                    HStack{
                        Image(systemName: feature.imageName)
                            .font(.largeTitle)
                            .foregroundColor(feature.color)
                        
                        VStack(alignment: .leading){
                            Text(feature.headline)
                                .font(.headline)
                            Text(feature.content)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top)
                }
                
                Spacer()
                
                Divider()
                    .background(Color("fontGray"))
                
                HStack{
                    Spacer()
                    VStack(alignment: .center, spacing: 2) {
                        Text("Uplock all features above.")
                            .font(.caption)
                        
                        Button(action: {
                            appStore.subscribe()
                        }) {
                            Text("Upgrade Now")
                                .font(.title)
                                .foregroundColor(Color("fontLink"))
                        }
                        
                        Text("for only $4.99/m.")
                            .font(.caption)
                        
                    }
                    Spacer()
                }
                
            }
            .customFont(name: "AvenirNext-Regular", style: .body)
        }
        .foregroundColor(Color("fontBody"))
        .padding(10)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}

struct PurchaseView_Previews: PreviewProvider {
    static var previews: some View {
        PurchaseView(closeMyself: .constant(true))
    }
}
