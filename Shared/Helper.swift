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

/// Serializes the app's large on-device inference pipelines. Core ML's
/// Kokoro graphs and MLX can otherwise execute simultaneously on shared
/// accelerator resources; pronunciation gets priority once the active job
/// reaches a safe completion boundary.
actor OnDeviceInferenceGate {
    enum Priority: Sendable {
        case pronunciation
        case tutor
    }

    static let shared = OnDeviceInferenceGate()

    private var isLocked = false
    private var pronunciationWaiters: [CheckedContinuation<Void, Never>] = []
    private var tutorWaiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<Result: Sendable>(
        priority: Priority,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire(priority: priority)
        defer { release() }
        return try await operation()
    }

    private func acquire(priority: Priority) async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .pronunciation:
                pronunciationWaiters.append(continuation)
            case .tutor:
                tutorWaiters.append(continuation)
            }
        }
    }

    private func release() {
        if !pronunciationWaiters.isEmpty {
            pronunciationWaiters.removeFirst().resume()
        } else if !tutorWaiters.isEmpty {
            tutorWaiters.removeFirst().resume()
        } else {
            isLocked = false
        }
    }
}

@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    @Published private(set) var naturalVoiceError: String?
    @Published private(set) var isNaturalVoiceReady = false
    @Published private(set) var naturalVoicePreparationStatus = "Checking speech resources…"

    private var soundPlayer: AVAudioPlayer?

    #if WORDBOOK_NATURAL_VOICE
    private struct SpeechRequest: Sendable {
        let id: UUID
        let text: String
        let phonemes: String?
        let cacheKey: String
        let cacheRevision: Int
    }

    private struct CompletedSpeechSynthesis: Sendable {
        let request: SpeechRequest
        let audio: Data
    }

    private enum SpeechSynthesisOutcome: Sendable {
        case skipped
        case completed(CompletedSpeechSynthesis)
        case failed(request: SpeechRequest, message: String)
    }

    private var speechWorkerTask: Task<Void, Never>?
    private var pendingSpeechRequest: SpeechRequest?
    private var activeSpeechRequest: SpeechRequest?
    private var currentSpeechRequest: SpeechRequest?
    private var speechCacheRevision = 0
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
                let currentRequestIsActive: Bool
                if let currentRequest = self.currentSpeechRequest,
                   let activeRequest = self.activeSpeechRequest {
                    currentRequestIsActive = currentRequest.id == activeRequest.id
                } else {
                    currentRequestIsActive = false
                }
                let interruptedSpeech = self.pendingSpeechRequest != nil
                    || currentRequestIsActive
                    || self.soundPlayer?.isPlaying == true
                // Do not cancel a Core ML prediction that may still be
                // executing inside E5RT/BNNS. Invalidate playback and let the
                // serialized synthesis task finish before releasing buffers.
                self.speechCacheRevision &+= 1
                self.activeSpeechRequest = nil
                self.pendingSpeechRequest = nil
                self.soundPlayer?.stop()
                self.soundPlayer = nil
                self.generatedSpeechCache.removeAllObjects()
                if interruptedSpeech {
                    self.naturalVoiceError = "Pronunciation was interrupted because the device needed memory. Tap the word to try again."
                }
            }
        }
        #endif
    }

    private enum SpeechPlaybackError: LocalizedError {
        case audioSessionFailed(String)
        case invalidAudio
        case preparationFailed
        case playbackFailed

        var errorDescription: String? {
            switch self {
            case .audioSessionFailed(let message):
                return "The natural voice audio output is unavailable: \(message)"
            case .invalidAudio:
                return "The natural voice produced invalid audio."
            case .preparationFailed:
                return "The natural voice audio could not be prepared."
            case .playbackFailed:
                return "The natural voice audio could not be played."
            }
        }

        var shouldDiscardAudio: Bool {
            switch self {
            case .invalidAudio, .preparationFailed:
                return true
            case .audioSessionFailed, .playbackFailed:
                return false
            }
        }
    }

    private func startPlayback(_ audio: Data) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                // Playback is output-only, so A2DP routing is already implicit.
                // Passing `.allowBluetoothA2DP` here attempts to change a fixed
                // category behavior and returns `paramErr` (-50) on iOS 26.
                options: [.mixWithOthers]
            )
        } catch {
            throw SpeechPlaybackError.audioSessionFailed(
                "Audio session configuration failed: \(error.localizedDescription)"
            )
        }
        do {
            try audioSession.setActive(true)
        } catch {
            throw SpeechPlaybackError.audioSessionFailed(
                "Audio session activation failed: \(error.localizedDescription)"
            )
        }
        #endif

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(
                data: audio,
                fileTypeHint: AVFileType.wav.rawValue
            )
        } catch {
            throw SpeechPlaybackError.invalidAudio
        }
        guard player.prepareToPlay() else {
            throw SpeechPlaybackError.preparationFailed
        }

        soundPlayer = player
        guard player.play() else {
            soundPlayer = nil
            throw SpeechPlaybackError.playbackFailed
        }
    }

    /// Starts loading and warming the bundled model as soon as the app's root
    /// view appears. The app remains at preparation until this succeeds.
    func prepareNaturalVoice() {
        #if WORDBOOK_NATURAL_VOICE
        guard naturalVoice == nil, naturalVoicePreparationTask == nil else { return }
        naturalVoicePreparationStatus = "Checking speech resources…"

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
            naturalVoicePreparationStatus = "Loading speech models…"
            let voice = KokoroAneManager(
                variant: .english,
                defaultVoice: "af_heart",
                directory: modelRoot
            )
            try await voice.initialize()

            // Core ML defers part of its graph compilation until the first
            // prediction. Exercise the same text-to-audio path used by a
            // normal card before opening the app. Keep this word in the
            // bundled lexicon: an invented OOV warm-up token needlessly runs
            // the much heavier fallback G2P model and has crashed inside
            // Apple's BNNS runtime on otherwise supported devices.
            naturalVoicePreparationStatus = "Warming pronunciation…"
            _ = try await OnDeviceInferenceGate.shared.withExclusiveAccess(
                priority: .pronunciation
            ) {
                try Task.checkCancellation()
                return try await voice.synthesize(
                    text: "ready.",
                    speed: 0.9
                )
            }
            return voice
        }
        naturalVoicePreparationTask = preparationTask

        do {
            let voice = try await preparationTask.value
            naturalVoice = voice
            naturalVoicePreparationTask = nil
            isNaturalVoiceReady = true
            naturalVoicePreparationStatus = "Natural voice ready"
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

        soundPlayer?.stop()
        soundPlayer = nil
        naturalVoiceError = nil

        #if WORDBOOK_NATURAL_VOICE
        let trimmedPhonemes = phonemes?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedPhonemes = trimmedPhonemes.flatMap { value in
            value.isEmpty ? nil : value
        }
        let pronunciationInput = normalizedPhonemes.map { "phonemes:\($0)" }
            ?? "text:\(text)"
        let cacheKey = "\(BundledNaturalVoiceAssets.version)|af_heart|0.9|\(pronunciationInput)"
        let request = SpeechRequest(
            id: UUID(),
            text: text,
            phonemes: normalizedPhonemes,
            cacheKey: cacheKey,
            cacheRevision: speechCacheRevision
        )

        activeSpeechRequest = request
        pendingSpeechRequest = nil

        if let cachedAudio = cachedSpeech(for: cacheKey) {
            do {
                try startPlayback(cachedAudio)
            } catch {
                if shouldDiscardSpeechAudio(after: error) {
                    generatedSpeechCache.removeObject(forKey: cacheKey as NSString)
                    pendingSpeechRequest = request
                    startSpeechWorkerIfNeeded()
                } else {
                    naturalVoiceError = error.localizedDescription
                }
            }
            return
        }

        pendingSpeechRequest = request
        startSpeechWorkerIfNeeded()
        #else
        naturalVoiceError = "Natural voice is unavailable on this target."
        #endif
    }

    #if WORDBOOK_NATURAL_VOICE
    private func cachedSpeech(for cacheKey: String) -> Data? {
        guard let cachedAudio = generatedSpeechCache.object(
            forKey: cacheKey as NSString
        ) else {
            return nil
        }
        return cachedAudio as Data
    }

    private func shouldDiscardSpeechAudio(after error: Error) -> Bool {
        (error as? SpeechPlaybackError)?.shouldDiscardAudio == true
    }

    private func startSpeechWorkerIfNeeded() {
        guard speechWorkerTask == nil else { return }

        speechWorkerTask = Task { [weak self] in
            guard let self else { return }
            await self.runSpeechWorker()
        }
    }

    private func runSpeechWorker() async {
        defer {
            currentSpeechRequest = nil
            speechWorkerTask = nil
            if pendingSpeechRequest != nil {
                startSpeechWorkerIfNeeded()
            }
        }

        while let queuedRequest = pendingSpeechRequest {
            pendingSpeechRequest = nil
            currentSpeechRequest = queuedRequest

            let voice: KokoroAneManager
            do {
                voice = try await loadNaturalVoice()
            } catch {
                currentSpeechRequest = nil
                pendingSpeechRequest = nil
                if activeSpeechRequest?.cacheKey == queuedRequest.cacheKey {
                    naturalVoiceError = error.localizedDescription
                }
                break
            }

            let outcome = await OnDeviceInferenceGate.shared.withExclusiveAccess(
                priority: .pronunciation
            ) {
                // Do not commit to the request that originally woke the worker
                // until the inference gate is actually available. A newer tap
                // can replace it while a tutor or pronunciation holds the gate.
                guard let request = await MainActor.run(body: {
                    self.takeRequestForSynthesis(fallback: queuedRequest)
                }) else {
                    return SpeechSynthesisOutcome.skipped
                }

                if let cachedAudio = await MainActor.run(body: {
                    self.cachedSpeech(for: request.cacheKey)
                }) {
                    return .completed(
                        CompletedSpeechSynthesis(
                            request: request,
                            audio: cachedAudio
                        )
                    )
                }

                do {
                    let audio: Data
                    if let phonemes = request.phonemes {
                        audio = try await voice.synthesizeFromPhonemes(
                            phonemes,
                            speed: 0.9
                        )
                    } else {
                        // Terminal punctuation gives isolated dictionary words
                        // a natural stopping contour without changing pronunciation.
                        let alreadyTerminated = request.text.last.map {
                            ".!?".contains($0)
                        } ?? false
                        let synthesisText = alreadyTerminated
                            ? request.text
                            : request.text + "."
                        audio = try await voice.synthesize(
                            text: synthesisText,
                            speed: 0.9
                        )
                    }
                    return .completed(
                        CompletedSpeechSynthesis(
                            request: request,
                            audio: audio
                        )
                    )
                } catch {
                    return .failed(
                        request: request,
                        message: error.localizedDescription
                    )
                }
            }

            handleSpeechSynthesisOutcome(outcome)
        }
    }

    private func takeRequestForSynthesis(
        fallback: SpeechRequest
    ) -> SpeechRequest? {
        if let latestRequest = pendingSpeechRequest {
            pendingSpeechRequest = nil
            currentSpeechRequest = latestRequest
            return latestRequest
        }

        guard activeSpeechRequest?.id == fallback.id else {
            currentSpeechRequest = nil
            return nil
        }
        currentSpeechRequest = fallback
        return fallback
    }

    private func handleSpeechSynthesisOutcome(_ outcome: SpeechSynthesisOutcome) {
        defer { currentSpeechRequest = nil }
        switch outcome {
        case .skipped:
            return

        case .completed(let completed):
            guard completed.request.cacheRevision == speechCacheRevision else {
                return
            }
            generatedSpeechCache.setObject(
                completed.audio as NSData,
                forKey: completed.request.cacheKey as NSString,
                cost: completed.audio.count
            )

            // A repeated tap for the same key is satisfied by the synthesis
            // that was already in progress; do not enqueue it a second time.
            if pendingSpeechRequest?.cacheKey == completed.request.cacheKey {
                pendingSpeechRequest = nil
            }

            guard activeSpeechRequest?.cacheKey == completed.request.cacheKey else {
                return
            }
            do {
                try startPlayback(completed.audio)
            } catch {
                if shouldDiscardSpeechAudio(after: error) {
                    generatedSpeechCache.removeObject(
                        forKey: completed.request.cacheKey as NSString
                    )
                }
                naturalVoiceError = error.localizedDescription
            }

        case .failed(let request, let message):
            guard request.cacheRevision == speechCacheRevision else {
                return
            }
            if pendingSpeechRequest?.cacheKey == request.cacheKey {
                pendingSpeechRequest = nil
            }
            if activeSpeechRequest?.cacheKey == request.cacheKey {
                naturalVoiceError = message
            }
        }
    }
    #endif

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
