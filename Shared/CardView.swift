//
//  WordcardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import Introspect

struct CardView: View {
    @State var showDefinition: Bool = false
    @State var disableFlip: Bool = false
    @State var enableGoodButton: Bool = false
    
    @StateObject private var viewModel = CardViewModel()
    
    @State private var editing = false
    @State private var popSheetWord = ""
    
    private var defaultWord = ""
    
    init(_ word: String = "",
         _ showDefinition: Bool = false,
         _ disableFlip: Bool = false) {
        _showDefinition = State(initialValue: showDefinition)
        _disableFlip = State(initialValue: disableFlip)
        defaultWord = word
    }
    
    var body: some View {
        VStack{
            FlipView(
                VStack {
                    VStack {
                        Text("\(viewModel.word)")
                            .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                            .foregroundColor(Color("fontTitle"))
                    }
                },
                VStack {
                    Spacer()
                    VStack{
                        TextField("\(viewModel.word)", text: $viewModel.word)
                            .disabled(!self.editing)
                            .textContentType(.none)
                            .autocapitalization(.none)
                            .keyboardType(.alphabet)
                            .multilineTextAlignment(.center)
                            .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                            .foregroundColor(Color("fontTitle"))
                            .introspectTextField { textField in
                                if self.editing {
                                    textField.becomeFirstResponder()
                                }
                            }
                        
                        
                        if (self.viewModel.pronunciation != nil) {
                            Text("\(self.viewModel.pronunciation!)")
                                .customFont(name: "AvenirNext-Regular", style: .caption1, weight: .regular)
                                .foregroundColor(Color("fontBody"))
                        }
                    }
                    .padding(.bottom, 17.6)
                    .padding(.top, 30)
                    Spacer()
                    if viewModel.mnemonic != nil {
                        HStack(alignment: .firstTextBaseline){
                            VStack(alignment: .trailing) {
                                Text("m.")
                            }
                            VStack(alignment: .leading){
                                Text("\(viewModel.mnemonic!)")
                                    .multilineTextAlignment(.leading)
                                    .padding(.bottom, 2.5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(3)
                        .customFont(name: "AvenirNext-Regular", style: .callout, weight: .medium)
                        Divider()
                    }
                    
                    if #available(iOS 15.0, *) {
                        DefinitionView(viewModel: viewModel)
                            .foregroundColor(Color("fontBody"))
                    } else {
                        // Fallback on earlier versions
                        DefinitionView(viewModel: viewModel)
                            .foregroundColor(Color("fontBody"))
                    }
                },
                tap: {
                    if let sound = self.viewModel.sound {
                        SoundManager.shared.PlaySound(sound)
                    } else {
                        SoundManager.shared.PlayTTS(self.viewModel.word)
                    }
                },
                flipped: $showDefinition,
                disabled: self.$editing || $disableFlip
            )
            
            Divider()
            
            ReviewButtons()
                .padding()
        }
        .onAppear{
            if defaultWord != "" {
                viewModel.word = defaultWord
            }
            viewModel.validate()
            
            PausableTimer.shared.restart()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.enableGoodButton.toggle()
            }
        }
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func ReviewButtons() -> some View {
        HStack{
            Spacer()
            NavigationLink(
                destination: SharingView(),
                label: {
                    Text("GOOD")
                        .fixedSize()
                })
                .simultaneousGesture(TapGesture().onEnded{
                    viewModel.answer(.WELLKNOWN)
                })
            .disabled(!self.enableGoodButton && !self.showDefinition)
            .buttonStyle(ChoiceButtonStyle(self.enableGoodButton || self.showDefinition))
            Divider()
            NavigationLink(
                destination: SharingView(),
                label: {
                    Text("VAGUE")
                        .fixedSize()
                })
                .isDetailLink(false)
                .simultaneousGesture(TapGesture().onEnded{
                    viewModel.answer(.VAGUE)
                })
            .disabled(!self.showDefinition)
            .buttonStyle(ChoiceButtonStyle(self.showDefinition))
            Divider()
            NavigationLink(
                destination: SharingView(),
                label: {
                    Text("NOIDEA")
                        .fixedSize()
                })
                .isDetailLink(false)
                .simultaneousGesture(TapGesture().onEnded{
                    viewModel.answer(.NOIDEA)
                })
            .disabled(!self.showDefinition)
            .buttonStyle(ChoiceButtonStyle(self.showDefinition))
            Spacer()
        }
        .modifier(FootViewStyle())
    }
}

struct DefinitionView: View {
    @ObservedObject var viewModel: CardViewModel
    @State private var popSheetWord = ""
    
    var body: some View {
        VStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading) {
                    ForEach(viewModel.senses) { ss in
                        GlossView(ss: ss)
                    }
                    
                    if viewModel.extras.count > 0 {
                        VStack (spacing: 9) {
                            ForEach(viewModel.extras) { extra in
                                ExtraExplainSummeryView(simpleExpl: extra)
                            }
                        }
                        .padding(.top, 25)
                    }
                }
            }
            Spacer()
        }
        .foregroundColor(Color("fontBody"))
        .onAppear{
            viewModel.fetchExplain()
        }
    }
    
    func GlossView(ss : Sense) -> some View {
        HStack(alignment: .firstTextBaseline){
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(ss.pos).")
            }
            VStack(alignment: .leading){
                Text("\(ss.gloss)")
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if ss.synonyms.count > 0 {
                    SynonymView(synonyms: ss.synonyms)
                        .padding(.bottom, 2.5)
                }
                if ss.examples.count > 0 {
                    ExampleView(examples: ss.examples)
                        .padding(.bottom, 2.5)
                }
            }
            Spacer()
        }
        .padding(3)
        .customFont(name: "AvenirNext-Regular", style: .callout, weight: .medium)
    }
    
    // TODO: try https://swiftuirecipes.com/blog/flow-layout-in-swiftui
    func SynonymView(synonyms: [String]) -> some View {
        var syns = [[String]]()
        var chars = 0
        var line = 0
        let maxChar = 20
        
        synonyms.forEach{ sy in
            if !syns.indices.contains(line) {
                syns.append([String]())
            }
            syns[line].append(sy)
            chars += sy.count
            // make sure the line wrap if has more then 20 chars
            if chars > maxChar {
                line += 1
                chars = 0
            }
        }
        
        return HStack(alignment: .firstTextBaseline){
            Text("Similar:")
                .fixedSize()
            VStack(alignment: .leading){
                ForEach(syns, id: \.self)  { sys in
                    HStack{
                        ForEach(sys, id: \.self)  { sy in
                            Button(action: {
                                self.popSheetWord = sy
                            }) {
                                Text("\(sy)")
                                    .fixedSize()
                                    .foregroundColor(Color("fontLink"))
                            }
                        }
                    }
                }
            }
        }
    }
    
    func ExampleView(examples: [String]) -> some View {
        VStack(alignment: .leading){
            ForEach(examples, id: \.self) { ex in
                HStack(alignment: .top){
                    Text("·")
                    
                    Text("\"\(ex)\"")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                }
                .customFont(name: "AvenirNext-Italic", style: .footnote, weight: .regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExtraExplainSummeryView: View {
    let simpleExpl: ExtraExplain
    @State private var popFullExpl = false
    
    var body: some View {
        VStack{
            VStack(alignment: .leading) {
                Text(simpleExpl.source.desc)
                    .customFont(name: "AvenirNext-Bold", style: .title3, weight: .bold)
                Text("\(simpleExpl.expl)")
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
            }
            .sheet(isPresented: $popFullExpl) {
                ExtraExplainDetailView(extraExpl: simpleExpl, closeMyself: $popFullExpl)
                    .environment(\.colorScheme, .dark)
            }
            .padding(.init(top: 9, leading: 15, bottom: 9, trailing: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color("fontGray"), lineWidth: 1)
            )
            .onTapGesture{
                self.popFullExpl.toggle()
            }
        }
        .padding(3)
    }
}

struct ExtraExplainDetailView: View {
    let extraExpl: ExtraExplain
    @Binding var closeMyself: Bool
    @State private var popWebLink: Bool = false
    
    var body: some View {
        NavigationView {
            VStack {
                Text("\(extraExpl.title)")
                    .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
                    .foregroundColor(Color("fontTitle"))
                    .padding(.bottom, 17.6)
                    .padding(.top, 30)
                    
                Text("\(extraExpl.expl)")
                
                Spacer()
                
                if extraExpl.url != nil {
                    Divider()
                    
                    Button(action: {
                        self.popWebLink.toggle()
                    }) {
                        Text("MORE")
                    }.modifier(FootViewStyle())
                }
            }
            .customFont(name: "AvenirNext-Regular", style: .body)
            .padding(EdgeInsets(top: 11, leading: 25, bottom: 11, trailing: 25))
            .navigationBarTitle(Text("\(extraExpl.title) - \(extraExpl.source.desc)"), displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                    closeMyself.toggle()
                }) {
                    Text("Close")
                })
        }
        .sheet(isPresented: $popWebLink) {
            if let url = extraExpl.url {
                WebPageView(url: url)
                    .environment(\.colorScheme, .dark)
            } else {
                // TODO: toast error
            }
        }
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}


struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView{
                CardView("line", true)
                    .navigationBarTitle("", displayMode: .inline)
            }
        }
    }
}
