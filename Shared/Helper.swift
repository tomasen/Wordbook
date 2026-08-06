//
//  Helper.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/30/21.
//

import Foundation
import AVFoundation
import Combine

#if WORDBOOK_NATURAL_VOICE
import FluidAudio
#if canImport(UIKit)
import UIKit
#endif
#endif

@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    @Published private(set) var naturalVoiceError: String?
    @Published private(set) var isNaturalVoiceReady = false

    private var soundPlayer: AVAudioPlayer?
    private var speechTask: Task<Void, Never>?
    private var activeSpeechRequest = UUID()

    #if WORDBOOK_NATURAL_VOICE
    private var memoryWarningCancellable: AnyCancellable?
    private let generatedSpeechCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private var naturalVoice: KokoroAneManager?
    private var naturalVoicePreparationTask: Task<KokoroAneManager, Error>?
    #endif

    private init() {
        #if WORDBOOK_NATURAL_VOICE && canImport(UIKit)
        memoryWarningCancellable = NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.speechTask?.cancel()
                self.activeSpeechRequest = UUID()
                self.generatedSpeechCache.removeAllObjects()
            }
        }
        #endif
    }

    private func prepareAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.allowBluetoothA2DP, .mixWithOthers]
        )
        try? audioSession.setActive(true)
        #endif
    }

    /// Starts loading the bundled model as soon as the app's root view
    /// appears. The normal interface remains gated on `isNaturalVoiceReady`.
    func prepareNaturalVoice() {
        #if WORDBOOK_NATURAL_VOICE
        guard naturalVoice == nil, naturalVoicePreparationTask == nil else { return }

        Task { [weak self] in
            do {
                _ = try await self?.loadNaturalVoice()
            } catch {
                // `loadNaturalVoice()` publishes the user-facing failure.
            }
        }
        #else
        naturalVoiceError = "Natural voice is unavailable on this target."
        #endif
    }

    func retryNaturalVoicePreparation() {
        naturalVoiceError = nil
        prepareNaturalVoice()
    }

    #if WORDBOOK_NATURAL_VOICE
    private func loadNaturalVoice() async throws -> KokoroAneManager {
        if let naturalVoice = naturalVoice {
            return naturalVoice
        }
        if let naturalVoicePreparationTask = naturalVoicePreparationTask {
            return try await naturalVoicePreparationTask.value
        }

        naturalVoiceError = nil

        let preparationTask = Task<KokoroAneManager, Error> {
            let modelRoot = try await BundledNaturalVoiceAssets.shared.prepare()
            let voice = KokoroAneManager(
                variant: .english,
                defaultVoice: "af_heart",
                directory: modelRoot
            )
            try await voice.initialize()
            return voice
        }
        naturalVoicePreparationTask = preparationTask

        do {
            let voice = try await preparationTask.value
            naturalVoice = voice
            naturalVoicePreparationTask = nil
            isNaturalVoiceReady = true
            return voice
        } catch {
            naturalVoicePreparationTask = nil
            isNaturalVoiceReady = false
            naturalVoiceError = error.localizedDescription
            throw error
        }
    }
    #endif

    /// Speaks a word with the on-device Kokoro neural voice.
    ///
    /// Passing `phonemes` bypasses grapheme-to-phoneme conversion and is the
    /// authoritative path for words that need a curated Misaki-style IPA
    /// pronunciation. The normal path uses Kokoro's English lexicon first and
    /// its Core ML G2P model for out-of-vocabulary words.
    func playTTS(_ word: String, phonemes: String? = nil) {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        speechTask?.cancel()
        soundPlayer?.stop()
        let request = UUID()
        activeSpeechRequest = request
        naturalVoiceError = nil

        #if WORDBOOK_NATURAL_VOICE
        let pronunciationInput = phonemes.map { "phonemes:\($0)" } ?? "text:\(text)"
        let cacheKey = NSString(
            string: "\(BundledNaturalVoiceAssets.version)|af_heart|0.9|\(pronunciationInput)"
        )
        if let cachedAudio = generatedSpeechCache.object(forKey: cacheKey) {
            do {
                prepareAudioSession()
                soundPlayer = try AVAudioPlayer(
                    data: cachedAudio as Data,
                    fileTypeHint: AVFileType.wav.rawValue
                )
                soundPlayer?.prepareToPlay()
                soundPlayer?.play()
                return
            } catch {
                generatedSpeechCache.removeObject(forKey: cacheKey)
            }
        }

        speechTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let voice = try await loadNaturalVoice()
                guard !Task.isCancelled, activeSpeechRequest == request else { return }

                let audio: Data
                if let phonemes = phonemes, !phonemes.isEmpty {
                    audio = try await voice.synthesizeFromPhonemes(
                        phonemes,
                        speed: 0.9
                    )
                } else {
                    // Terminal punctuation gives isolated dictionary words a
                    // natural stopping contour without changing pronunciation.
                    let alreadyTerminated = text.last.map { ".!?".contains($0) } ?? false
                    audio = try await voice.synthesize(
                        text: alreadyTerminated ? text : text + ".",
                        speed: 0.9
                    )
                }
                guard !Task.isCancelled, activeSpeechRequest == request else { return }

                generatedSpeechCache.setObject(
                    audio as NSData,
                    forKey: cacheKey,
                    cost: audio.count
                )
                prepareAudioSession()
                soundPlayer = try AVAudioPlayer(
                    data: audio,
                    fileTypeHint: AVFileType.wav.rawValue
                )
                soundPlayer?.prepareToPlay()
                soundPlayer?.play()
            } catch is CancellationError {
                return
            } catch {
                guard activeSpeechRequest == request else { return }
                if !Task.isCancelled {
                    naturalVoiceError = error.localizedDescription
                }
            }
        }
        #else
        naturalVoiceError = "Natural voice is unavailable on this target."
        #endif
    }

    func dismissNaturalVoiceError() {
        naturalVoiceError = nil
    }
}

public extension CGFloat {

    /// Returns a random floating point number between 0.0 and 1.0, inclusive.
    static var random: CGFloat {
        return CGFloat(Float.random(in: 0...1))
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

    func urlencode() -> String {
        return self.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
    }
}
