//
//  SharingView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI

struct SharingView: View {
    @StateObject var viewModel = SharingViewModel()
    
    private let dateFormatter = DateFormatter()
    private let durationFormatter = DateComponentsFormatter()
    
    init() {
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        durationFormatter.allowedUnits = [.minute, .second]
    }
    
    var body: some View {
        VStack{
            Text(dateFormatter.string(from: viewModel.todayDate))
                .foregroundColor(Color("fontTitle"))
                .customFont(name: "Baskerville-SemiBold", style: .largeTitle, weight: .heavy)
            Text("Wordbook's Review")
                .customFont(name: "AvenirNext-DemiBold", style: .caption2, weight: .semibold)
            
            WordCloudView(viewModel.wordsOfToday)
                .frame(height: viewModel.minCanvasHeight)
            
            HStack{
                VStack{
                    HStack{
                        Text("\(viewModel.todayWordsTotal) Words")
                        Spacer()
                        Text("\(durationFormatter.string(from:  viewModel.todayStudyTimeInSeconds) ?? "0") min.")
                    }
                    .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 0))
                    .customFont(name: "AvenirNext-DemiBold", style: .footnote, weight: .semibold)
                    
                    Spacer()
                    
                    Text("Wordbook - Grab Words Anytime")
                        .customFont(name: "AvenirNext-DemiBold", style: .subheadline, weight: .semibold)
                    
                    Link("https://wordbook.cool/", destination: URL(string: "https://www.wordbook.cool/")!)
                        .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .semibold)
                }
                Spacer()
                Image("qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                
            }
            .frame(height: 90)
            
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
                NavigationUtil.popToRootView()
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

struct NavigationUtil {
    static func popToRootView() {
        findNavigationController(viewController: UIApplication.shared.windows.filter { $0.isKeyWindow }.first?.rootViewController)?
            .popToRootViewController(animated: true)
    }
    
    static func findNavigationController(viewController: UIViewController?) -> UINavigationController? {
        guard let viewController = viewController else {
            return nil
        }
        
        if let navigationController = viewController as? UINavigationController {
            return navigationController
        }
        
        for childViewController in viewController.children {
            return findNavigationController(viewController: childViewController)
        }
        
        return nil
    }
}

struct SharingView_Previews: PreviewProvider {
    static var previews: some View {
        SharingView()
    }
}
