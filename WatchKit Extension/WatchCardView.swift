//
//  WatchCardView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

struct WatchCardView: View {
    @StateObject private var viewModel: CardViewModel
    @Binding private var closeMyself: Bool
    
    init(_ word: String = "") {
        _viewModel = StateObject(wrappedValue: CardViewModel(word))
        _closeMyself = .constant(false)
    }
    
    init(_ word: String = "", closeMyself: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: CardViewModel(word))
        _closeMyself = closeMyself
        // self.adding = true
    }
    
    var body: some View {
        VStack{
            ScrollView{
                Text("\(viewModel.word)")
                    .font(.title3)
                    .foregroundColor(Color("WatchListItemTitle"))
                
                Spacer()
                
                switch viewModel.wordEntryState {
                case .ready(let entry):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.usages) { usage in
                            usageView(usage)
                            if usage.entryUsageID != entry.usages.last?.entryUsageID {
                                Divider()
                            }
                        }
                        Spacer()
                    }
                    .font(.caption2)
                    .lineSpacing(2)

                case .localFallback(let explanation):
                    VStack(alignment: .leading, spacing: 6) {
                        if !explanation.partOfSpeech.isEmpty {
                            Text(explanation.partOfSpeech)
                                .foregroundColor(Color("fontGray"))
                        }
                        Text(explanation.meaning)
                        if !explanation.example.isEmpty {
                            Text("“\(explanation.example)”")
                                .italic()
                        }
                    }
                    .font(.caption2)
                    .lineSpacing(2)

                case .idle, .loading, .pending:
                    Text("Reviewed lesson")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .redacted(reason: .placeholder)
                        .accessibilityLabel("Opening reviewed lesson")

                case .correctionRequired(let candidates):
                    VStack(spacing: 6) {
                        Text("Check the spelling on your iPhone.")
                        if let suggestion = candidates.first {
                            Text("Suggested: \(suggestion)")
                        }
                    }
                    .multilineTextAlignment(.center)

                case .unavailable(let message):
                    VStack{
                        Spacer()
                        Text(message)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                }

                if closeMyself {
                    Spacer()
                    Button(action: {
                        _ = WordManager.shared.addWordCard(viewModel.word)
                        closeMyself.toggle()
                    }) {
                        Text("Add")
                            .foregroundColor(Color("fontBody"))
                    }
                }
            }
        }
        .foregroundColor(Color("WatchListItemContent"))
        .onAppear{
            viewModel.validate()
            viewModel.fetchExplain()
        }
    }

    @ViewBuilder
    private func usageView(_ usage: UsageLesson) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if usage.learnerLabel != nil || usage.partOfSpeechLabel != nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let label = usage.learnerLabel {
                        Text(label)
                            .fontWeight(.semibold)
                    }
                    if let partOfSpeech = usage.partOfSpeechLabel {
                        Text(partOfSpeech)
                            .foregroundColor(Color("fontGray"))
                    }
                }
            }
            if let relation = usage.formRelationLabel {
                Text(relation)
                    .foregroundColor(Color("fontGray"))
            }
            if let pronunciation = usage.pronunciations.first {
                Text(pronunciation.ipa)
                    .foregroundColor(Color("fontGray"))
            }

            Text(usage.content.directExplanation)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !usage.content.synonyms.isEmpty {
                Text("Similar: \(usage.content.synonyms.joined(separator: ", "))")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 4) {
                Text("·")
                Text("\"\(usage.content.example)\"")
                    .italic()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let memoryCue = usage.content.memoryCue {
                Divider()
                Text(memoryCue.plainText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }
}

struct WatchCardView_Previews: PreviewProvider {
    static var previews: some View {
        WatchCardView()
    }
}
