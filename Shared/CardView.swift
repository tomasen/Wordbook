//
//  WordcardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import SwiftUI
import Introspect

private struct PronunciationPreparationID: Hashable {
    let word: String
    let isEnabled: Bool
}

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
        showDefinition
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
                                    soundManager.playTTS(
                                        viewModel.word,
                                        phonemes: viewModel.preferredPronunciationPhonemes
                                    )
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
                                Text(alsoKnownAs)
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
                    SoundManager.shared.playTTS(
                        viewModel.word,
                        phonemes: viewModel.preferredPronunciationPhonemes
                    )
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
            // Explanation lookup is independent of pronunciation. A bundled
            // SQLite hit should be visible immediately instead of waiting for
            // the natural-voice pipeline.
            viewModel.fetchExplain()

            PausableTimer.shared.restart()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                enableGoodButton = true
            }
        }
        .task(id: PronunciationPreparationID(
            word: viewModel.word,
            isEnabled: !editing
        )) {
            let wordToPrepare = viewModel.word.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !editing, !wordToPrepare.isEmpty else { return }

            // Wait for the fast overlay/catalog-only lookup before starting
            // synthesis. Common words use their reviewed IPA; a true local
            // miss reaches Kokoro's bundled lexicon/G2P exactly once.
            let phonemes = await EntryExplanationRuntime.shared
                .preferredLocalPronunciationPhonemes(for: wordToPrepare)
            guard !Task.isCancelled,
                  !editing,
                  viewModel.word.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ) == wordToPrepare else { return }
            _ = await soundManager.preparePronunciation(
                wordToPrepare,
                phonemes: phonemes,
                foreground: true
            )
        }
        .onDisappear {
            soundManager.stopPronunciation(
                for: viewModel.word,
                phonemes: viewModel.preferredPronunciationPhonemes
            )
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

private struct ExplanationFeedbackButton: View {
    let title: String
    let systemImage: String
    let hint: String
    let state: ExplanationFeedbackControlState
    let anotherRequestIsInFlight: Bool
    let fillWidth: Bool
    let action: () -> Void

    private var isDisabled: Bool {
        state.isLocked || anotherRequestIsInFlight
    }

    private var accessibilityStatus: String {
        if state == .available, anotherRequestIsInFlight {
            return "Temporarily unavailable while another feedback request is in progress"
        }
        return state.accessibilityValue
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(
                    maxWidth: fillWidth ? .infinity : nil,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(Color("fontLink"))
        .customFont(
            name: "AvenirNext-Regular",
            style: .caption2,
            weight: .regular
        )
        .disabled(isDisabled)
        .opacity(isDisabled && !state.isSelected ? 0.58 : 1)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityStatus))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(state.isSelected ? .isSelected : [])
    }
}

private struct PrimaryExplanationFeedbackControls: View {
    @ObservedObject var viewModel: CardViewModel

    var body: some View {
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        helpfulButton(fillWidth: false)
                        meaningButton(fillWidth: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    verticalButtons
                }
            } else {
                verticalButtons
            }
        }
    }

    private var verticalButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpfulButton(fillWidth: true)
            meaningButton(fillWidth: true)
        }
    }

    private func helpfulButton(fillWidth: Bool) -> some View {
        ExplanationFeedbackButton(
            title: "Helpful",
            systemImage: viewModel.explanationWasLiked
                ? "hand.thumbsup.fill"
                : "hand.thumbsup",
            hint: "Marks this explanation as helpful.",
            state: viewModel.likeFeedbackState,
            anotherRequestIsInFlight: viewModel.explanationFeedbackInFlight,
            fillWidth: fillWidth,
            action: viewModel.likeExplanation
        )
    }

    private func meaningButton(fillWidth: Bool) -> some View {
        ExplanationFeedbackButton(
            title: "Explanation not helpful",
            systemImage: viewModel.meaningFeedbackState.isSelected
                ? "hand.thumbsdown.fill"
                : "hand.thumbsdown",
            hint: "Requests a different meaning for this explanation.",
            state: viewModel.meaningFeedbackState,
            anotherRequestIsInFlight: viewModel.explanationFeedbackInFlight,
            fillWidth: fillWidth
        ) {
            viewModel.requestBetterExplanation(for: .meaning)
        }
    }
}

struct DefinitionView: View {
    @ObservedObject var viewModel: CardViewModel
    @State private var popSheetWord = ""
    @State private var popWebPage = ""

    var body: some View {
        VStack(alignment: .leading) {
            switch viewModel.wordEntryState {
            case .idle, .loading, .pending:
                ExplanationPlaceholderView()

            case .ready:
                EntryLessonsView(viewModel: viewModel)

            case .localFallback(let explanation):
                localFallbackLesson(explanation)

            case .correctionRequired(let candidates):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check the spelling. Did you mean:")
                    ForEach(candidates, id: \.self) { candidate in
                        Button(candidate) {
                            viewModel.useSuggestedSpelling(candidate)
                        }
                        .foregroundColor(Color("fontLink"))
                    }
                    if viewModel.canConfirmRareSpelling {
                        Button("This spelling is correct") {
                            viewModel.confirmRareSpelling()
                        }
                        .foregroundColor(Color("fontLink"))
                        .accessibilityHint(
                            Text("Checks this exact spelling with the reviewed explanation service once.")
                        )
                    }
                }
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .callout,
                    weight: .medium
                )
                .padding(.horizontal, 10)

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
    private func localFallbackLesson(_ explanation: VocabularyExplanation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !explanation.partOfSpeech.isEmpty {
                    Text(explanation.partOfSpeech)
                        .fixedSize()
                }
                Text(explanation.meaning)
                    .multilineTextAlignment(.leading)
            }
            .customFont(
                name: "AvenirNext-Regular",
                style: .body,
                weight: .regular
            )

            if !explanation.synonyms.isEmpty {
                synonymView(explanation.synonyms)
            }

            if !explanation.example.isEmpty {
                Text("·  “\(explanation.example)”")
                    .italic()
                    .customFont(
                        name: "AvenirNext-Regular",
                        style: .footnote,
                        weight: .regular
                    )
            }

            if !explanation.memoryAidText.isEmpty {
                Divider()
                    .padding(.top, 2)
                Text(explanation.memoryAidText)
                    .customFont(
                        name: "AvenirNext-Regular",
                        style: .footnote,
                        weight: .regular
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
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

private struct EntryLessonsView: View {
    @ObservedObject var viewModel: CardViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.visibleEntryUsages.enumerated()), id: \.element.id) {
                index, usage in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 12)
                }
                lesson(usage)
            }

            if viewModel.canRevealMoreUsages {
                Button("Show more uses") {
                    viewModel.revealAllEntryUsages()
                }
                .foregroundColor(Color("fontLink"))
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .footnote,
                    weight: .medium
                )
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func lesson(_ usage: UsageLesson) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if usage.learnerLabel != nil
                || usage.partOfSpeechLabel != nil
                || usage.formRelationLabel != nil {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let partOfSpeech = usage.partOfSpeechLabel {
                        Text(partOfSpeech)
                    }
                    if let learnerLabel = usage.learnerLabel {
                        Text(learnerLabel)
                    }
                    if let formRelation = usage.formRelationLabel {
                        Text("· \(formRelation)")
                    }
                }
                .foregroundColor(Color("fontGray"))
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .caption2,
                    weight: .regular
                )
            }

            Text(usage.content.directExplanation)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .customFont(
                    name: "AvenirNext-Regular",
                    style: .callout,
                    weight: .medium
                )

            HStack(alignment: .top, spacing: 7) {
                Text("·")
                Text("\"\(usage.content.example)\"")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .customFont(
                name: "AvenirNext-Italic",
                style: .footnote,
                weight: .regular
            )

            if !usage.content.synonyms.isEmpty {
                synonymView(usage.content.synonyms)
            }

            if let memoryCue = usage.content.memoryCue {
                memoryCueText(memoryCue)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .customFont(
                        name: "AvenirNext-Regular",
                        style: .footnote,
                        weight: .regular
                    )
            }

            feedbackControls(for: usage)

            if let message = viewModel.entryFeedbackMessage(
                for: usage.entryUsageID
            ) {
                Text(message)
                    .foregroundColor(Color("fontGray"))
                    .customFont(
                        name: "AvenirNext-Regular",
                        style: .caption2,
                        weight: .regular
                    )
                    .accessibilityLabel(Text("Feedback status: \(message)"))
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func feedbackControls(for usage: UsageLesson) -> some View {
        let helpfulState = viewModel.entryFeedbackState(
            for: usage.entryUsageID,
            component: .wholeLesson
        )
        let explanationState = viewModel.entryFeedbackState(
            for: usage.entryUsageID,
            component: .explanation
        )

        VStack(alignment: .leading, spacing: 0) {
            ExplanationFeedbackButton(
                title: "Helpful",
                systemImage: helpfulState.isSelected
                    ? "hand.thumbsup.fill" : "hand.thumbsup",
                hint: "Marks this lesson as helpful.",
                state: helpfulState,
                anotherRequestIsInFlight: viewModel.explanationFeedbackInFlight,
                fillWidth: true
            ) {
                viewModel.likeExplanation(entryUsageID: usage.entryUsageID)
            }
            ExplanationFeedbackButton(
                title: "Explanation not helpful",
                systemImage: explanationState.isSelected
                    ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                hint: "Requests another reviewed lesson for this use.",
                state: explanationState,
                anotherRequestIsInFlight: viewModel.explanationFeedbackInFlight,
                fillWidth: true
            ) {
                viewModel.requestBetterExplanation(
                    entryUsageID: usage.entryUsageID,
                    component: .explanation
                )
            }
            if usage.content.memoryCue != nil {
                let memoryState = viewModel.entryFeedbackState(
                    for: usage.entryUsageID,
                    component: .memoryCue
                )
                ExplanationFeedbackButton(
                    title: "Memory tip not helpful",
                    systemImage: memoryState.isSelected
                        ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    hint: "Requests another reviewed lesson with a better memory tip.",
                    state: memoryState,
                    anotherRequestIsInFlight: viewModel.explanationFeedbackInFlight,
                    fillWidth: true
                ) {
                    viewModel.requestBetterExplanation(
                        entryUsageID: usage.entryUsageID,
                        component: .memoryCue
                    )
                }
            }
        }
        .padding(.top, 2)
    }

    private func memoryCueText(_ cue: MemoryCue) -> Text {
        cue.segments.reduce(Text("")) { partial, segment in
            partial + Text(segment.text).fontWeight(
                segment.emphasized ? .semibold : .regular
            )
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
                Text("Similar:").fixedSize()
                Text(attributed).accentColor(Color("fontLink"))
            }
            .customFont(
                name: "AvenirNext-Regular",
                style: .footnote,
                weight: .regular
            )
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Similar:").fixedSize()
                ForEach(synonyms, id: \.self) { synonym in
                    Button(synonym) {
                        guard let url = URL(
                            string: "wordbook://pop/\(synonym.urlencode())"
                        ) else { return }
                        openURL(url)
                    }
                    .foregroundColor(Color("fontLink"))
                }
            }
            .customFont(
                name: "AvenirNext-Regular",
                style: .footnote,
                weight: .regular
            )
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
