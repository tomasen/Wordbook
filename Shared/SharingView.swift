//
//  SharingView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI

struct SharingView: View {
    @StateObject var viewModel = SharingViewModel()
        
    var body: some View {
        VStack{
            Text("2008 - 10 - 2")
                .foregroundColor(Color("fontTitle"))
                .customFont(name: "Baskerville-SemiBold", style: .largeTitle, weight: .heavy)
            Text("Wordbook's Review")
                .customFont(name: "AvenirNext-DemiBold", style: .caption2, weight: .semibold)
            
            WordCloudView()
            
            HStack{
                VStack{
                    HStack{
                        Text("12 Words")
                        Spacer()
                        Text("3 min.")
                    }
                    .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 0))
                    .customFont(name: "AvenirNext-DemiBold", style: .footnote, weight: .semibold)
                    
                    Spacer()
                    
                    Text("Wordbook - Grab Words Anytime")
                        .customFont(name: "AvenirNext-DemiBold", style: .subheadline, weight: .semibold)
                    
                    Link("https://wordbook.cool/", destination: URL(string: "https://www.wordbook.cool/")!)
                        .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .semibold)
                }
                .frame(height: 90)
                Spacer()
                Image("qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                
            }
            
            Spacer()
                .padding()
                
            Divider()
            
            NextButtons()
        }
        .foregroundColor(Color("fontBody"))
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func NextButtons() -> some View {
        HStack{
            NavigationLink(destination: CardView()){
                Text("NEXT")
                    .fixedSize()
            }
            .buttonStyle(ChoiceButtonStyle(true))
            Divider()
            Button(action: {
                let window = UIApplication.shared.connectedScenes
                    .filter { $0.activationState == .foregroundActive }
                    .map { $0 as? UIWindowScene }
                    .compactMap { $0 }
                    .first?.windows
                    .filter { $0.isKeyWindow }
                    .first
                let nvc = window?.rootViewController?.children.first as? UINavigationController
                nvc?.popToRootViewController(animated: true)
            }) {
                Text("CLOSE")
            }
            .buttonStyle(ChoiceButtonStyle(true))
        }
        .modifier(FootViewStyle())
    }
}


struct SizeGetter: View {
    @Binding var sizeArray: [CGSize]
    var idx: Int = 0

    init(_ sizeArray: Binding<[CGSize]>, _ index: Int) {
        _sizeArray = sizeArray
        idx = index
    }
    
    var body: some View {
        GeometryReader { proxy in
            self.createView(proxy: proxy)
        }
    }

    func createView(proxy: GeometryProxy) -> some View {
        DispatchQueue.main.async {
            sizeArray[idx] = proxy.frame(in: .global).size
        }

        return Rectangle().fill(Color.clear)
    }
}

struct SharingView_Previews: PreviewProvider {
    static var previews: some View {
        SharingView()
    }
}
