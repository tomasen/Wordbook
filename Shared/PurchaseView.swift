//
//  PurchaseView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/4/22.
//

import SwiftUI

struct PurchaseView: View {
    @Binding var closeMyself: Bool
    
    @StateObject var iapManager = InAppPurchaseManager.shared
    
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
                                       content: "extremely learner-friendly dictionary, without any loss in its thoroughness."),
                               Feature(imageName: "scroll",
                                       color: Color.red,
                                       headline: "Realworld Shortcuts",
                                       content: "checking out real-world usage from the world wide web within the App with just one click."),
                               Feature(imageName: "photo.on.rectangle.angled",
                                       color: Color("fontLink"),
                                       headline: "Graphic Reference",
                                       content: "gets the visual idea of the word by listing all the images related within App."),
                               Feature(imageName: "globe.badge.chevron.backward",
                                       color: Color.green,
                                       headline: "Extra Explanation",
                                       content: "showing a brief summary of the Wikipedia article of the word for extended reading."),
                               Feature(imageName: "ipad.and.iphone",
                                       color: Color.yellow,
                                       headline: "Sync Across Devices",
                                       content: "keep up with the progress across iPad, iPhone, and Apple Watch by turning on iCloud sync."),
                               Feature(imageName: "books.vertical",
                                       color: Color("progressGood"),
                                       headline: "Translation",
                                       content: "translate to your native language of choice for quick understanding.")]
    
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
                        iapManager.restore()
                    }) {
                        Text("Restore Purchase")
                            .font(.caption)
                            .foregroundColor(Color("fontLink"))
                    }
                    Spacer()
                }
                
                ForEach(features) { feature in
                    HStack{
                        if "ipad.and.iphone" == feature.imageName {
                            ZStack{
                                Image(systemName: feature.imageName)
                                    .font(.largeTitle)
                                Image(systemName: "applewatch")
                                    .font(.body)
                                    .offset(x: -9, y: -1)
                            }
                            .gradientForeground(colors: [Color("fontGray"), feature.color])
                            .frame(width: 50)
                        } else {
                            Image(systemName: feature.imageName)
                                .font(.largeTitle)
                                .gradientForeground(colors: [Color("fontGray"), feature.color])
                                .frame(width: 50)
                        }
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
                            iapManager.subscribe()
                        }) {
                            Text("Upgrade Now")
                                .font(.title)
                                .foregroundColor(Color("fontLink"))
                        }
                        
                        if let price = iapManager.localizedPrice {
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
