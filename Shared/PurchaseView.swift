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
                                       headline: "Friendly Dictionary",
                                       content: "extremely learner friendly dictionary, without any loss in its thoroughness."),
                               Feature(imageName: "scroll",
                                       color: Color.red,
                                       headline: "Realworld Shortcuts",
                                       content: "checking out real world usage from world wide web within the App by just one click."),
                               Feature(imageName: "photo.on.rectangle.angled",
                                       color: Color.blue,
                                       headline: "Graphic Reference",
                                       content: "get the visual idea of the word by listing all the images related within App."),
                               Feature(imageName: "books.vertical",
                                       color: Color.green,
                                       headline: "Translation",
                                       content: "translate to your native language of choice for quick understanding."),
                               Feature(imageName: "globe.badge.chevron.backward",
                                       color: Color.yellow,
                                       headline: "Extra Explanation",
                                       content: "showing a breif summary of the Wikipedia article of the word for extended reading.")]
    
    var body: some View {
        VStack{
            VStack(alignment: .leading){
                HStack{
                    Text("Upgrade to Pro")
                        .customFont(name: "AvenirNext-Bold", style: .largeTitle, weight: .semibold)
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
                        appStore.restore()
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
                            .gradientForeground(colors: [Color("fontGray"), feature.color])
                            .frame(width: 50)
                        
                        VStack(alignment: .leading){
                            Text(feature.headline)
                                .font(.headline)
                            Text(feature.content)
                                .font(.callout)
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
                        
                        if let price = appStore.localizedPrice {
                            Text("for only \(price)/m.")
                                .font(.caption)
                        }
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

extension View {
    public func gradientForeground(colors: [Color]) -> some View {
        self.overlay(LinearGradient(gradient: .init(colors: colors),
                                    startPoint: .topTrailing,
                                    endPoint: .bottomTrailing))
            .mask(self)
    }
}

struct PurchaseView_Previews: PreviewProvider {
    static var previews: some View {
        PurchaseView(closeMyself: .constant(true))
    }
}
