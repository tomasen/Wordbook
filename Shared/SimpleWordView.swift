//
//  SimpleWordView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/7/22.
//

import SwiftUI

class SimpleWordViewModel: ObservableObject {
    func addToWordbook(_ word: String) {
        _ = WordManager.shared.addWordCard(word)
    }
    
    func isWordAlreadyExistInWordbook(_ word: String) -> Bool {
        WordManager.shared.IsWordCardExist(word)
    }
}

struct SimpleWordView: View {
    @ObservedObject private var soundManager = SoundManager.shared

    @State var word: String
    
    @Binding var closeMyself: Bool
    
    private let viewModel = SimpleWordViewModel()
    @StateObject private var explanationViewModel = CardViewModel()
    
    var body: some View {
        VStack{
            Button {
                soundManager.playTTS(word)
            } label: {
                Text(word)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .customFont(name: "AvenirNext-Medium", style: .largeTitle, weight: .medium)
            .foregroundColor(Color("fontTitle"))
            .padding(17.6)
            .accessibilityLabel("Pronounce \(word)")
            .accessibilityHint("Plays the natural voice pronunciation")
            
            ScrollView(.vertical) {
                DefinitionView(viewModel: explanationViewModel)
            }
            Divider()
            HStack{
                Spacer()
                Button(action: {
                    viewModel.addToWordbook(word)
                    closeMyself.toggle()
                }) {
                    Text( viewModel.isWordAlreadyExistInWordbook(word) ? "BUMP" : "ADD")
                }
                Spacer()
                Divider()
                Spacer()
                Button(action: {
                    closeMyself.toggle()
                }) {
                    Text("CLOSE")
                }
                Spacer()
            }
            .modifier(FootViewStyle())
        }
        .padding(EdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .foregroundColor(Color("fontBody"))
        .background(Color(UIColor.secondarySystemBackground).edgesIgnoringSafeArea(.all))
        .onAppear {
            explanationViewModel.word = word
            explanationViewModel.fetchExplain()
        }
        .onDisappear {
            explanationViewModel.cancelExplanation()
        }
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
}

struct SimpleWordView_Previews: PreviewProvider {
    static var previews: some View {
        SimpleWordView(word: "line", closeMyself: .constant(true))
    }
}
