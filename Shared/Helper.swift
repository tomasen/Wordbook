//
//  Helper.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/30/21.
//

import Foundation
import AVFoundation

struct SoundManager {
    static var shared = SoundManager()
    
    var SoundPlayer: AVAudioPlayer!
    
    init() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default, options: .allowBluetoothA2DP)
        try? audioSession.setActive(true)
    }
    
    
    mutating func PlaySound(_ sound: Data) {
        do {
            SoundPlayer = try AVAudioPlayer(data: sound, fileTypeHint: AVFileType.mp3.rawValue)
            SoundPlayer.prepareToPlay()
            SoundPlayer.play()
        } catch let error {
            print(error.localizedDescription)
        }
    }

    func PlayTTS(_ word: String) {
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
        
        let synthesizer = AVSpeechSynthesizer()
        // synthesizer.outputChannels
        synthesizer.speak(utterance)
    }
}

public extension CGFloat {

    /// Returns a random floating point number between 0.0 and 1.0, inclusive.
    static var random: CGFloat {
        return CGFloat(arc4random()) / 0xFFFFFFFF
    }
}

public extension String {
    static func getContentOfFile(_ name: String, _ type: String) -> String {
        if let filepath = Bundle.main.path(forResource: name, ofType: type) {
            do {
                return try String(contentsOfFile: filepath)
            } catch {
                print("fail to read content from \(name)")
            }
        }
        return ""
    }
}
