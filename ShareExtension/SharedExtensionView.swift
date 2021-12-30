//
//  SLComposerView.swift
//  Memorable
//
//  Created by tomasen on 3/13/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import SwiftUI

class SharedExtensionViewModel: ObservableObject {
    @Published var contentText: String = "" {
        didSet {
            words = WordFilter.shared.filter(from: contentText)
        }
    }
    @Published var words = [String]()
    
    func setContent(_ text: String) {
        contentText = WordFilter.shared.filter(from: text).joined(separator: ", ")
    }
}

struct SharedExtensionView : View {
    @ObservedObject var viewModel: SharedExtensionViewModel
    
    var body: some View {
        VStack (alignment: .leading, spacing: 12) {
            TextField("words you want to memorize", text: $viewModel.contentText)
                .textContentType(.none)
                .textFieldStyle(CustomTextFieldStyle())
                .padding(.top, 9)
            
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DICTIONARY")
                        .padding(.leading, 18)
                        .foregroundColor(Color("fontGray"))
                    
                    VStack(spacing: 0) {
                        ForEach(viewModel.words, id: \.self) { word in
                            VStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack{
                                        Text("\(word)")
                                            .padding(.bottom, 0)
                                            .customFont(name: "AvenirNext-DemiBold", style: .headline, weight: .semibold)
                                        Spacer()
                                    }
                                    ForEach(explain(word), id: \.self) { expl in
                                        HStack(alignment: .firstTextBaseline, spacing: 3){
                                            Text("·")
                                            Text("\(expl)").lineSpacing(0)
                                        }
                                        .padding(.bottom, 3)
                                        .foregroundColor(Color("fontGray"))
                                    }
                                }
                                .padding(.init(top: 9, leading: 19, bottom: 12, trailing: 19))
                                
                                if word != viewModel.words.last {
                                    Divider()
                                        .padding(.init(top: 0, leading: 19, bottom: 0, trailing: 19))
                                }
                                
                            }
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(15)
                }
                .font(.footnote)
            }
            .padding(.top, 9)
        }
        .padding(.init(top: 25, leading: 20, bottom: 9, trailing: 20))
        .background(Color(UIColor.tertiarySystemGroupedBackground).edgesIgnoringSafeArea(.all))
        .customFont(name: "Avenir-Book", style: .callout, weight: .medium)
        .environment(\.colorScheme, .dark)
    }
    
    public struct CustomTextFieldStyle : TextFieldStyle {
        public func _body(configuration: TextField<Self._Label>) -> some View {
            configuration
                .customFont(name: "AvenirNext-Regular", style: .body)
                // Set the inner Text Field Padding
                .padding(.init(top: 5, leading: 10, bottom: 4, trailing: 10))
                .background(Color("textFieldBackground").cornerRadius(8))
        }
    }
    
    func explain(_ word: String) -> [String] {
        var ret = WordDatabaseLocal.shared.explainExact(word)
        if ret.count == 0 {
            ret = WordDatabaseLocal.shared.explainAlias(word)
        }
        if ret.count == 0 {
            ret = ["word not found (determiners, prepositions, pronouns, conjunctions, and particles are exclude from our dictionary)"]
        }
        return ret
    }
}

struct SLComposerView_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            SharedExtensionView(viewModel: SharedExtensionViewModel())
                .environment(\.colorScheme, .dark)
        }
    }
}
