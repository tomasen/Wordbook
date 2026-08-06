//
//  WordcardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import Introspect

struct CardView: View {
    @ObservedObject private var soundManager = SoundManager.shared

    @State var showDefinition: Bool = false
    @State var disableFlip: Bool = false
    @State var enableGoodButton: Bool = false

    @StateObject private var viewModel = CardViewModel()

    @State private var editing = false
    @State private var popContextpMenu = false

    private var defaultWord = ""

    private var canAnswerAfterReveal: Bool {
        showDefinition && viewModel.isExplanationSettled
    }

    init(_ word: String = "",
         _ showDefinition: Bool = false,
         _ disableFlip: Bool = false) {
        _showDefinition = State(initialValue: showDefinition)
        _disableFlip = State(initialValue: disableFlip)
        defaultWord = word
    }

    var body: some View {
        VStack {
            FlipView(
                VStack {
                    Text(viewModel.word)
                        .customFont(
                            name: "AvenirNext-Medium",
                            style: .largeTitle,
                            weight: .medium
                        )
                        .foregroundColor(Color("fontTitle"))
                },
                VStack {
                    Spacer()
                    ScrollView(.vertical) {
                        VStack {
                            if editing {
                                TextField(
                                    viewModel.word,
                                    text: $viewModel.word,
                                    onCommit: {
                                        editing.toggle()
                                        viewModel.fetchExplain()
                                    }
                                )
                                .onChange(of: viewModel.word) {
                                    // `onAppear` assigns the card word, which also
                                    // triggers this callback. Only user edits should
                                    // cancel and invalidate an explanation request.
                                    viewModel.reset()
                                }
                                .textContentType(.none)
                                .autocapitalization(.none)
                                .keyboardType(.alphabet)
                                .multilineTextAlignment(.center)
                                .customFont(
                                    name: "AvenirNext-Medium",
                                    style: .largeTitle,
                                    weight: .medium
                                )
                                .foregroundColor(Color("fontTitle"))
                                .introspectTextField { textField in
                                    textField.becomeFirstResponder()
                                }
                            } else {
                                Button {
                                    soundManager.playTTS(viewModel.word)
                                } label: {
                                    Text(viewModel.word)
                                        .frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .customFont(
                                    name: "AvenirNext-Medium",
                                    style: .largeTitle,
                                    weight: .medium
                                )
                                .foregroundColor(Color("fontTitle"))
                                .accessibilityLabel("Pronounce \(viewModel.word)")
                                .accessibilityHint("Plays the natural voice pronunciation")
                            }

                            if let alsoKnownAs = viewModel.alsoKnownAs {
                                Text("as. \(alsoKnownAs)")
                                    .customFont(
                                        name: "AvenirNext-Regular",
                                        style: .caption2,
                                        weight: .regular
                                    )
                                    .foregroundColor(Color("fontGray"))
                            }
                        }
                        .padding(.bottom, 17.6)
                        .padding(.top, 30)

                        DefinitionView(viewModel: viewModel)
                    }
                },
                tap: {
                    SoundManager.shared.playTTS(viewModel.word)
                },
                flipped: $showDefinition,
                disabled: $editing || $disableFlip
            )

            Divider()

            ReviewButtons()
                .padding()
        }
        .onAppear {
            if !defaultWord.isEmpty {
                viewModel.word = defaultWord
            }
            viewModel.validate()
            viewModel.fetchExplain()

            PausableTimer.shared.restart()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                enableGoodButton = true
            }
        }
        .onDisappear {
            viewModel.cancelExplanation()
        }
        .navigationBarItems(trailing: trailingBarItem())
        .background(Color("Background").edgesIgnoringSafeArea(.all))
        .alert(isPresented: Binding(
            get: { soundManager.naturalVoiceError != nil },
            set: { isPresented in
                if !isPresented {
                    soundManager.dismissNaturalVoiceError()
                }
            }
        )) {
            Alert(
                title: Text("Natural Voice"),
                message: Text(soundManager.naturalVoiceError ?? "Unable to generate speech."),
                dismissButton: .default(Text("OK")) {
                    soundManager.dismissNaturalVoiceError()
                }
            )
        }
    }

    func trailingBarItem() -> some View {
        HStack {
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
                ActionSheet(
                    title: Text("Wordbook"),
                    buttons: [
                        .default(Text("EDIT"), action: {
                            editing.toggle()
                        }),
                        .destructive(Text("BURY"), action: {
                            viewModel.bury()
                            NavigationUtil.popToRootView()
                        }),
                        .cancel(),
                    ]
                )
            }
        }
        .foregroundColor(Color("fontLink"))
    }

    func ReviewButtons() -> some View {
        HStack {
            Spacer()
            NavigationLink(destination: SharingView()) {
                Text("GOOD")
                    .fixedSize()
            }
            .simultaneousGesture(TapGesture().onEnded {
                viewModel.answer(.WELLKNOWN)
            })
            .disabled(!enableGoodButton && !showDefinition)
            .buttonStyle(ChoiceButtonStyle(enableGoodButton || showDefinition))

            Divider()

            NavigationLink(destination: SharingView()) {
                Text("VAGUE")
                    .fixedSize()
            }
            .isDetailLink(false)
            .simultaneousGesture(TapGesture().onEnded {
                viewModel.answer(.VAGUE)
            })
            .disabled(!canAnswerAfterReveal)
            .buttonStyle(ChoiceButtonStyle(canAnswerAfterReveal))

            Divider()

            NavigationLink(destination: SharingView()) {
                Text("NOIDEA")
                    .fixedSize()
            }
            .isDetailLink(false)
            .simultaneousGesture(TapGesture().onEnded {
                viewModel.answer(.NOIDEA)
            })
            .disabled(!canAnswerAfterReveal)
            .buttonStyle(ChoiceButtonStyle(canAnswerAfterReveal))
            Spacer()
        }
        .modifier(FootViewStyle())
    }
}

struct MemoryAidView: View {
    let text: String

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .padding(.bottom, 2.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(3)
        .customFont(
            name: "AvenirNext-Regular",
            style: .callout,
            weight: .medium
        )
    }
}

struct DefinitionView: View {
    @ObservedObject var viewModel: CardViewModel
    @State private var popSheetWord = ""
    @State private var popWebPage = ""

    var body: some View {
        VStack(alignment: .leading) {
            switch viewModel.explanationState {
            case .idle, .loading:
                ExplanationPlaceholderView()

            case .ready(let explanation):
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .trailing) {
                            Text("\(explanation.partOfSpeech).")
                        }

                        VStack(alignment: .leading) {
                            Text(explanation.meaning)
                                .multilineTextAlignment(.leading)
                                .padding(.bottom, 2.5)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !explanation.synonyms.isEmpty {
                                synonymView(explanation.synonyms)
                                    .padding(.bottom, 2.5)
                            }

                            HStack(alignment: .top) {
                                Text("·")
                                Text("\"\(explanation.example)\"")
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .customFont(
                                name: "AvenirNext-Italic",
                                style: .footnote,
                                weight: .regular
                            )
                            .padding(.bottom, 2.5)
                        }
                    }
                    .customFont(
                        name: "AvenirNext-Regular",
                        style: .callout,
                        weight: .medium
                    )
                    .padding(.horizontal, 10)

                    if !explanation.memoryAid.isEmpty {
                        Divider()
                        MemoryAidView(text: explanation.memoryAidText)
                    }
                }

            case .unavailable(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .multilineTextAlignment(.leading)
                    Button("Try again") {
                        viewModel.retryExplanation()
                    }
                    .foregroundColor(Color("fontLink"))
                }
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .callout,
                    weight: .medium
                )
                .padding(.horizontal, 10)
            }

            if let summary = viewModel.wikipediaSummary {
                WikipediaSummaryCard(summary: summary)
                    .padding(.top, 25)
            }

            Spacer()
                .padding(5)

            HStack {
                Button("news") {
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us&tbm=nws"
                }
                Button("images") {
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us&tbm=isch"
                }
                Button("web") {
                    popWebPage = "https://www.google.com/search?q=\(viewModel.word.urlencode())&hl=en-us"
                }
                Button("translate") {
                    popWebPage = "https://www.deepl.com/en/translator#en/\(viewModel.translationLanguageCode)/\(viewModel.word.urlencode())"
                }
            }
            .buttonStyle(DefinitionLinkButtonStyle())
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .foregroundColor(Color("fontBody"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onOpenURL { url in
            if popSheetWord.isEmpty {
                popSheetWord = url.lastPathComponent
            }
        }
        .sheet(isPresented: $popSheetWord.toBool()) {
            SimpleWordView(word: popSheetWord, closeMyself: $popSheetWord.toBool())
                .environment(\.colorScheme, .dark)
        }
        .sheet(isPresented: $popWebPage.toBool()) {
            if let url = URL(string: popWebPage) {
                WebPageView(url: url)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    @ViewBuilder
    private func synonymView(_ synonyms: [String]) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            let links = synonyms.map {
                "[\($0)](wordbook://pop/\($0.urlencode()))"
            }
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
            let attributed = (try? AttributedString(
                markdown: links.joined(separator: " "),
                options: options
            )) ?? AttributedString(synonyms.joined(separator: " "))

            HStack(alignment: .firstTextBaseline) {
                Text("Similar:")
                    .fixedSize()
                Text(attributed)
                    .accentColor(Color("fontLink"))
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Similar:")
                    .fixedSize()
                ForEach(synonyms, id: \.self) { synonym in
                    Button(synonym) {
                        popSheetWord = synonym
                    }
                    .foregroundColor(Color("fontLink"))
                }
            }
        }
    }
}

private struct ExplanationPlaceholderView: View {
    private struct Row: Identifiable {
        let id: Int
        let partOfSpeech: String
        let meaning: String
        let example: String?
    }

    private let rows = [
        Row(
            id: 0,
            partOfSpeech: "▩.",
            meaning: "▩▩▩▩ ▩▩▩ ▩▩ ▩▩▩ ▩▩▩▩",
            example: nil
        ),
        Row(
            id: 1,
            partOfSpeech: "▩.",
            meaning: "▩▩▩▩▩ ▩▩▩▩▩▩\n▩▩▩▩▩ ▩▩▩▩",
            example: "▩▩▩▩▩▩, ▩▩▩▩▩▩"
        ),
        Row(
            id: 2,
            partOfSpeech: "▩.",
            meaning: "▩▩▩▩▩ ▩▩▩▩▩▩ ▩▩▩▩ ▩▩ ▩▩▩▩ ▩▩▩▩▩ ▩▩▩▩",
            example: nil
        ),
    ]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(row.partOfSpeech).")

                    VStack(alignment: .leading) {
                        Text(row.meaning)
                            .multilineTextAlignment(.leading)
                            .padding(.bottom, 2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let example = row.example {
                            HStack(alignment: .top) {
                                Text("·")
                                Text("\"\(example)\"")
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .customFont(
                                name: "AvenirNext-Italic",
                                style: .footnote,
                                weight: .regular
                            )
                            .padding(.bottom, 2.5)
                        }
                    }
                }
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .callout,
                    weight: .medium
                )
                .padding(.horizontal, 10)
            }
        }
        .accessibilityHidden(true)
    }
}

struct WikipediaSummaryCard: View {
    let summary: WikipediaSummary
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Wikipedia")
                .customFont(
                    name: "AvenirNext-Bold",
                    style: .title3,
                    weight: .bold
                )
            Text(summary.extract)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showDetail) {
            WikipediaDetailView(summary: summary, closeMyself: $showDetail)
                .environment(\.colorScheme, .dark)
        }
        .padding(.init(top: 9, leading: 15, bottom: 9, trailing: 15))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color("fontGray"), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showDetail = true
        }
        .customFont(name: "AvenirNext-Regular", style: .body)
        .padding(3)
    }
}

struct WikipediaDetailView: View {
    let summary: WikipediaSummary
    @Binding var closeMyself: Bool
    @State private var showWebPage = false

    var body: some View {
        NavigationView {
            VStack {
                Text(summary.title)
                    .customFont(
                        name: "AvenirNext-Medium",
                        style: .largeTitle,
                        weight: .medium
                    )
                    .foregroundColor(Color("fontTitle"))
                    .padding(.bottom, 17.6)
                    .padding(.top, 30)

                ScrollView {
                    Text(summary.extract)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Button("MORE") {
                    showWebPage = true
                }
                .modifier(FootViewStyle())
            }
            .customFont(name: "AvenirNext-Regular", style: .body)
            .padding(.init(top: 11, leading: 25, bottom: 11, trailing: 25))
            .navigationBarTitle("Wikipedia", displayMode: .inline)
            .navigationBarItems(trailing: Button("Close") {
                closeMyself = false
            })
        }
        .sheet(isPresented: $showWebPage) {
            WebPageView(url: summary.url)
                .environment(\.colorScheme, .dark)
        }
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
}

struct DefinitionLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color("fontGray"))
            .padding(.init(top: 3, leading: 10, bottom: 3, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color("todayBackground"))
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                CardView("jibe", true)
                    .navigationBarTitle("", displayMode: .inline)
            }
        }
    }
}
