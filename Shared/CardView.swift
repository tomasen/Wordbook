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
    @State private var popContextpMenu = false
    
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
                    ScrollView(.vertical) {
                        VStack{
                            TextField("\(viewModel.word)",
                                      text: $viewModel.word,
                                      onCommit:{ editing.toggle() })
                                .disabled(!self.editing)
                                .onChange(of: viewModel.word) { _ in
                                    print("MSG: change \(viewModel.word)")
                                    viewModel.reset()
                                    viewModel.fetchExplain()
                                }
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
                            
                            if let alsoKnownAs = viewModel.alsoKnownAs {
                                Text("as. \(alsoKnownAs)")
                                    .customFont(name: "AvenirNext-Regular", style: .caption2, weight: .regular)
                                    .foregroundColor(Color("fontGray"))
                            }
                            
                            if let pronunciation = viewModel.pronunciation {
                                Text("\(pronunciation)")
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
        .navigationBarItems(trailing: trailingBarItem())
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func trailingBarItem() -> some View {
        HStack{
            Spacer()
            Button(action: {
                popContextpMenu.toggle()
            }) {
                Image(systemName: "ellipsis")
                    .imageScale(.medium)
                    .rotationEffect(.degrees(-90))
                    .padding(5)
            }
            .actionSheet(isPresented: $popContextpMenu) {
                ActionSheet(title: Text("Wordbook"),
                            buttons: [
                                .default(
                                    Text("EDIT"),
                                    action: {
                                        editing.toggle()
                                    }),
                                .destructive(
                                    Text("BURY"),
                                    action: {
                                        viewModel.bury()
                                        NavigationUtil.popToRootView()
                                    }),
                                .cancel()])
            }
        }
        .foregroundColor(Color("fontLink"))
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
    @State private var popWebPage = ""
    
    private let iapManager = InAppPurchaseManager.shared
    
    var body: some View {
        VStack{
            VStack(alignment: .leading) {
                ForEach(viewModel.senses) { sense in
                    GlossView(sense: sense)
                        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                }
                
                if viewModel.extras.count > 0 {
                    VStack (spacing: 9) {
                        ForEach(Array(viewModel.extras.keys), id: \.self) { key in
                            ExtraExplainSummeryView(simpleExpl: viewModel.extras[key]!)
                        }
                    }
                    .padding(.top, 25)
                }
            }
            .onOpenURL{ url in
                if popSheetWord.count == 0 {
                    popSheetWord = url.lastPathComponent
                }
            }
            .sheet(isPresented: $popSheetWord.toBool()) {
                SimpleWordView(word: popSheetWord, closeMyself: $popSheetWord.toBool())
                    .environment(\.colorScheme, .dark)
            }
            .foregroundColor(Color("fontBody"))
            .onAppear{
                viewModel.fetchExplain()
            }
            
            Spacer()
                .padding(5)
            
            HStack {
                Button(action:{
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us&tbm=nws"
                }) {
                    Text("news")
                }
                
                Button(action:{
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us&tbm=isch"
                }) {
                    Text("images")
                }
                
                Button(action:{
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us"
                }) {
                    Text("web")
                }
                
                Button(action:{
                    popWebPage = "https://www.deepl.com/en/translator#en/\(viewModel.translationLanguageCode)/\(viewModel.word.urlencode())"
                }) {
                    Text("translate")
                }
            }
            .buttonStyle(LinkButtonStyle())
            .sheet(isPresented: $popWebPage.toBool()) {
                if iapManager.isProSubscriber {
                    WebPageView(url: URL(string: popWebPage)!)
                        .environment(\.colorScheme, .dark)
                } else {
                    PurchaseView(closeMyself: $popWebPage.toBool())
                        .environment(\.colorScheme, .dark)
                }
            }
        }
    }
    
    func GlossView(sense : Sense) -> some View {
        HStack(alignment: .firstTextBaseline){
            VStack(alignment: .trailing) {
                Text("\(sense.pos).")
            }
            VStack(alignment: .leading){
                Text("\(sense.gloss)")
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(alignment: .leading)
                
                if sense.synonyms.count > 0 {
                    if #available(iOS 15.0, *) {
                        SynonymView15(syns: sense.synonyms)
                            .padding(.bottom, 2.5)
                    } else {
                        SynonymView(syns: sense.synonyms, popWord: $popSheetWord)
                            .padding(.bottom, 2.5)
                    }
                }
                if sense.examples.count > 0 {
                    ExampleView(examples: sense.examples)
                        .padding(.bottom, 2.5)
                }
            }
        }
        .customFont(name: "AvenirNext-Regular", style: .callout, weight: .medium)
    }
    
    @available(iOS 15.0, *)
    func SynonymView15(syns: [String]) -> some View {
        var texts = [String]()
        for syn in syns {
            if syn.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                texts.append("[\(syn)](wordbook://pop/\(syn.urlencode()))")
            }
        }
        let markdownText: AttributedString = try! AttributedString(markdown: texts.joined(separator: " "), options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        
        return HStack(alignment: .firstTextBaseline){
            Text("Similar:")
                .fixedSize()
            VStack(alignment: .leading){
                Text(markdownText)
                    .accentColor(Color("fontLink"))
            }
        }
    }
    
    func ExampleView(examples: [String]) -> some View {
        VStack(alignment: .leading){
            ForEach(examples, id: \.self) { ex in
                HStack(alignment: .top){
                    Text("·")
                    
                    Text("\"\(ex.trimmingCharacters(in: .whitespacesAndNewlines))\"")
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

struct SynonymView: View {
    class WordCloudPositionCache {
        var maxWidth: CGFloat = 0
        var wordSizes = [CGSize]()
        var synss: [SynonymItemGroup] = []
    }
    
    @Binding var popSheetWord: String
    
    @State private var wordSizes: [CGSize]
    private var maxWidth: CGFloat {
        UIScreen.main.bounds.size.width - 200
    }
    
    private var synonyms = [String]()
    private var cache = WordCloudPositionCache()
    
    init(syns: [String], popWord: Binding<String>) {
        for w in syns {
            if w.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                synonyms.append(w)
            }
        }
        _wordSizes = State(initialValue:[CGSize](repeating: CGSize.zero, count: synonyms.count))
        _popSheetWord = popWord
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline){
            Text("Similar:")
                .fixedSize()
            VStack(alignment: .leading){
                ForEach(calcPosition(maxWidth))  { syns in
                    HStack{
                        ForEach(syns.syns)  { syn in
                            Button(action: {
                                popSheetWord = syn.word
                            }) {
                                Text("\(syn.word)")
                                    .fixedSize()
                                    .foregroundColor(Color("fontLink"))
                            }
                            .background(WordSizeGetter($wordSizes, syn.id))
                        }
                    }
                }
            }
        }
    }
    
    func calcPosition(_ maxWidth: CGFloat) -> [SynonymItemGroup] {
        var syns: [SynonymItemGroup] = []
        var lineNo = 0
        if wordSizes.count == 0 {
            return syns
        }
        
        if wordSizes[0] == CGSize.zero {
            var charCount = 0
            for (idx, sy) in synonyms.enumerated() {
                if syns.count == lineNo {
                    syns.append(SynonymItemGroup(syns: [SynonymItem](), id: lineNo))
                }
                syns[lineNo].syns.append(SynonymItem(word: sy, id: idx))
                charCount += sy.count
                // make sure the line wrap if has more then 20 chars
                if charCount > 10 {
                    lineNo += 1
                    charCount = 0
                }
            }
            return syns
        }
        
        if cache.maxWidth == maxWidth
            && cache.wordSizes.count == wordSizes.count {
            return cache.synss
        }
        defer {
            cache.maxWidth = maxWidth
            cache.wordSizes = wordSizes
            cache.synss = syns
        }
        
        syns.append(SynonymItemGroup(syns: [SynonymItem](), id: lineNo))
        var lineWidth: CGFloat = 0
        for (idx, sy) in synonyms.enumerated() {
            lineWidth += wordSizes[idx].width + 6
            if lineWidth > maxWidth {
                lineNo += 1
                lineWidth = 0
                syns.append(SynonymItemGroup(syns: [SynonymItem](), id: lineNo))
            }
            syns[lineNo].syns.append(SynonymItem(word: sy, id: idx))
        }
        
#if DEBUG
        print("MSG: \(maxWidth)")
        print("MSG: \(syns)")
#endif
        
        return syns
    }
}

struct SynonymItemGroup: Identifiable {
    var syns: [SynonymItem]
    var id: Int
}

struct SynonymItem: Identifiable {
    var word: String
    var id: Int
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
                if InAppPurchaseManager.shared.isProSubscriber {
                    ExtraExplainDetailView(extraExpl: simpleExpl, closeMyself: $popFullExpl)
                        .environment(\.colorScheme, .dark)
                } else {
                    PurchaseView(closeMyself: $popFullExpl)
                }
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
        .customFont(name: "AvenirNext-Regular", style: .body)
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

struct LinkButtonStyle: ButtonStyle {
    private let isEnabled: Bool
    init(_ isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
    
    public func makeBody(configuration: ChoiceButtonStyle.Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? Color("fontGray") : Color("textFieldBackground"))
            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color("todayBackground")))
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView{
                CardView("jibe", true)
                    .navigationBarTitle("", displayMode: .inline)
            }
        }
    }
}
