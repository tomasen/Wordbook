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
    @Published private(set) var naturalVoicePreparationStatus = "Checking pronunciation resources…"

    private var soundPlayer: AVAudioPlayer?
    private var playingSpeechCacheKey: String?

    #if WORDBOOK_NATURAL_VOICE
    private enum SpeechRequestPurpose: Sendable {
        case playback
        case prefetch
    }

    private struct SpeechPreparationKey: Hashable, Sendable {
        let cacheKey: String
        let cacheRevision: Int
    }

    private struct SpeechRequest: Sendable {
        let id: UUID
        let text: String
        let phonemes: String?
        let cacheKey: String
        let cacheRevision: Int
        let purpose: SpeechRequestPurpose
        let isForegroundPrefetch: Bool

        var preparationKey: SpeechPreparationKey {
            SpeechPreparationKey(
                cacheKey: cacheKey,
                cacheRevision: cacheRevision
            )
        }
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
    private var pendingSpeechPrefetchRequest: SpeechRequest?
    private var activeSpeechRequest: SpeechRequest?
    private var currentSpeechRequest: SpeechRequest?
    private var speechPreparationWaiters: [
        SpeechPreparationKey: [UUID: CheckedContinuation<Bool, Never>]
    ] = [:]
    private var abandonedSpeechRequestIDs: Set<UUID> = []
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
                let interruptedWaiters = self.speechPreparationWaiters.values
                    .flatMap { $0.values }
                let currentRequestID = self.currentSpeechRequest?.id
                // Do not cancel a Core ML prediction that may still be
                // executing inside E5RT/BNNS. Invalidate playback and let the
                // serialized synthesis task finish before releasing buffers.
                self.speechCacheRevision &+= 1
                self.activeSpeechRequest = nil
                self.pendingSpeechRequest = nil
                self.pendingSpeechPrefetchRequest = nil
                self.soundPlayer?.stop()
                self.soundPlayer = nil
                self.playingSpeechCacheKey = nil
                self.generatedSpeechCache.removeAllObjects()
                self.speechPreparationWaiters.removeAll()
                self.abandonedSpeechRequestIDs.removeAll()
                if let currentRequestID {
                    // If this request is still waiting for the inference gate,
                    // skip it. If Core ML has already started, it may finish
                    // safely, but its old-revision result will be discarded.
                    self.abandonedSpeechRequestIDs.insert(currentRequestID)
                }
                for waiter in interruptedWaiters {
                    waiter.resume(returning: false)
                }
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
                return "Pronunciation audio couldn’t be started."
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

    private func startPlayback(_ audio: Data, cacheKey: String) throws {
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
            playingSpeechCacheKey = nil
            throw SpeechPlaybackError.playbackFailed
        }
        playingSpeechCacheKey = cacheKey
    }

    /// Starts loading and warming the bundled model as soon as the app's root
    /// view appears. The app remains at preparation until this succeeds.
    func prepareNaturalVoice() {
        #if WORDBOOK_NATURAL_VOICE
        guard naturalVoice == nil, naturalVoicePreparationTask == nil else { return }
        naturalVoicePreparationStatus = "Checking pronunciation resources…"

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
            naturalVoicePreparationStatus = "Loading pronunciation…"
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
            naturalVoicePreparationStatus = "Getting pronunciation ready…"
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
            naturalVoicePreparationStatus = "Pronunciation ready"
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
        playingSpeechCacheKey = nil
        naturalVoiceError = nil

        #if WORDBOOK_NATURAL_VOICE
        let request = makeSpeechRequest(
            text: text,
            phonemes: phonemes,
            purpose: .playback
        )

        activeSpeechRequest = request

        if let cachedAudio = cachedSpeech(for: request.cacheKey) {
            if let supersededRequest = pendingSpeechRequest {
                pendingSpeechRequest = nil
                if supersededRequest.preparationKey != request.preparationKey {
                    finishSpeechPreparationIfIdle(
                        for: supersededRequest
                    )
                }
            }
            if pendingSpeechPrefetchRequest?.preparationKey
                == request.preparationKey {
                pendingSpeechPrefetchRequest = nil
            }
            finishSpeechPreparation(for: request)
            do {
                try startPlayback(cachedAudio, cacheKey: request.cacheKey)
            } catch {
                if shouldDiscardSpeechAudio(after: error) {
                    generatedSpeechCache.removeObject(
                        forKey: request.cacheKey as NSString
                    )
                    pendingSpeechRequest = request
                    startSpeechWorkerIfNeeded()
                } else {
                    naturalVoiceError = error.localizedDescription
                }
            }
            return
        }

        if let supersededRequest = pendingSpeechRequest,
           supersededRequest.preparationKey != request.preparationKey {
            pendingSpeechRequest = nil
            finishSpeechPreparationIfIdle(for: supersededRequest)
        }
        if pendingSpeechPrefetchRequest?.preparationKey
            == request.preparationKey {
            // The explicit tap upgrades the silent request. If that request is
            // already running, its completed audio will satisfy this new
            // playback intent without a second synthesis.
            pendingSpeechPrefetchRequest = nil
        }
        pendingSpeechRequest = request
        startSpeechWorkerIfNeeded()
        #else
        naturalVoiceError = "Natural voice is unavailable on this target."
        #endif
    }

    /// Silently generates and caches a word's audio. Awaiting this method lets
    /// callers start the slower explanation model only after pronunciation has
    /// had first use of the shared on-device inference pipeline.
    func preparePronunciation(
        _ word: String,
        phonemes: String? = nil,
        foreground: Bool = false
    ) async -> Bool {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        #if WORDBOOK_NATURAL_VOICE
        let request = makeSpeechRequest(
            text: text,
            phonemes: phonemes,
            purpose: .prefetch,
            isForegroundPrefetch: foreground
        )
        guard cachedSpeech(for: request.cacheKey) == nil else { return true }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if cachedSpeech(for: request.cacheKey) != nil {
                    continuation.resume(returning: true)
                    return
                }
                speechPreparationWaiters[
                    request.preparationKey,
                    default: [:]
                ][waiterID] = continuation
                enqueueSpeechPrefetch(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSpeechPreparationWaiter(
                    waiterID,
                    for: request.preparationKey
                )
            }
        }
        #else
        return true
        #endif
    }

    /// Stops playback intent for one word without cancelling a Core ML call
    /// that may already be executing. In-flight work may safely finish and be
    /// cached, but it can no longer speak after the user leaves the card.
    func stopPronunciation(for word: String, phonemes: String? = nil) {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        #if WORDBOOK_NATURAL_VOICE
        let request = makeSpeechRequest(
            text: text,
            phonemes: phonemes,
            purpose: .prefetch
        )
        let cacheKey = request.cacheKey

        if activeSpeechRequest?.cacheKey == cacheKey {
            activeSpeechRequest = nil
        }
        if let pendingRequest = pendingSpeechRequest,
           pendingRequest.cacheKey == cacheKey {
            pendingSpeechRequest = nil
            finishSpeechPreparationIfIdle(
                for: pendingRequest,
                shouldContinue: false
            )
        }
        if playingSpeechCacheKey == cacheKey {
            soundPlayer?.stop()
            soundPlayer = nil
            playingSpeechCacheKey = nil
        }
        #else
        soundPlayer?.stop()
        soundPlayer = nil
        playingSpeechCacheKey = nil
        #endif
    }

    #if WORDBOOK_NATURAL_VOICE
    private func makeSpeechRequest(
        text: String,
        phonemes: String?,
        purpose: SpeechRequestPurpose,
        isForegroundPrefetch: Bool = false
    ) -> SpeechRequest {
        let trimmedPhonemes = phonemes?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedPhonemes = trimmedPhonemes.flatMap { value in
            value.isEmpty ? nil : value
        }
        let pronunciationInput = normalizedPhonemes.map { "phonemes:\($0)" }
            ?? "text:\(text)"
        let cacheKey = "\(BundledNaturalVoiceAssets.version)|af_heart|0.9|\(pronunciationInput)"
        return SpeechRequest(
            id: UUID(),
            text: text,
            phonemes: normalizedPhonemes,
            cacheKey: cacheKey,
            cacheRevision: speechCacheRevision,
            purpose: purpose,
            isForegroundPrefetch: isForegroundPrefetch
        )
    }

    private func enqueueSpeechPrefetch(_ request: SpeechRequest) {
        guard cachedSpeech(for: request.cacheKey) == nil else {
            finishSpeechPreparation(for: request)
            return
        }
        if let currentRequest = currentSpeechRequest,
           currentRequest.preparationKey == request.preparationKey {
            abandonedSpeechRequestIDs.remove(currentRequest.id)
            if request.isForegroundPrefetch
                && !currentRequest.isForegroundPrefetch {
                if let supersededRequest = pendingSpeechPrefetchRequest,
                   supersededRequest.preparationKey
                    != request.preparationKey {
                    pendingSpeechPrefetchRequest = nil
                    finishSpeechPreparationIfIdle(for: supersededRequest)
                }
                // Upgrade work that is still waiting for the inference gate.
                // `takeRequestForSynthesis` will select this foreground copy
                // without duplicating synthesis or its shared waiters.
                pendingSpeechPrefetchRequest = request
            }
            startSpeechWorkerIfNeeded()
            return
        }
        if pendingSpeechRequest?.preparationKey == request.preparationKey {
            startSpeechWorkerIfNeeded()
            return
        }
        if let pendingPrefetch = pendingSpeechPrefetchRequest,
           pendingPrefetch.preparationKey == request.preparationKey {
            if request.isForegroundPrefetch
                && !pendingPrefetch.isForegroundPrefetch {
                pendingSpeechPrefetchRequest = request
            }
            startSpeechWorkerIfNeeded()
            return
        }

        if let supersededRequest = pendingSpeechPrefetchRequest {
            if supersededRequest.isForegroundPrefetch
                && !request.isForegroundPrefetch {
                // A background reservation must not displace the word that is
                // already on screen and waiting for responsive pronunciation.
                finishSpeechPreparation(
                    for: request,
                    shouldContinue: false
                )
                return
            }
            pendingSpeechPrefetchRequest = nil
            finishSpeechPreparationIfIdle(for: supersededRequest)
        }
        pendingSpeechPrefetchRequest = request
        startSpeechWorkerIfNeeded()
    }

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
            if pendingSpeechRequest != nil
                || pendingSpeechPrefetchRequest != nil {
                startSpeechWorkerIfNeeded()
            }
        }

        while let queuedRequest = dequeueNextSpeechRequest() {

            let voice: KokoroAneManager
            do {
                voice = try await loadNaturalVoice()
            } catch {
                currentSpeechRequest = nil
                let abandonedRequests = [
                    queuedRequest,
                    pendingSpeechRequest,
                    pendingSpeechPrefetchRequest,
                ].compactMap { $0 }
                pendingSpeechRequest = nil
                pendingSpeechPrefetchRequest = nil
                for request in abandonedRequests {
                    finishSpeechPreparation(for: request)
                }
                if activeSpeechRequest?.preparationKey
                    == queuedRequest.preparationKey {
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

    private func dequeueNextSpeechRequest() -> SpeechRequest? {
        if let request = pendingSpeechRequest {
            pendingSpeechRequest = nil
            currentSpeechRequest = request
            return request
        }
        if let request = pendingSpeechPrefetchRequest {
            pendingSpeechPrefetchRequest = nil
            currentSpeechRequest = request
            return request
        }
        currentSpeechRequest = nil
        return nil
    }

    private func takeRequestForSynthesis(
        fallback: SpeechRequest
    ) -> SpeechRequest? {
        let fallbackWasAbandoned = abandonedSpeechRequestIDs.remove(
            fallback.id
        ) != nil

        if let latestRequest = pendingSpeechRequest {
            pendingSpeechRequest = nil
            if fallback.purpose == .prefetch && fallbackWasAbandoned {
                finishSpeechPreparation(
                    for: fallback,
                    shouldContinue: false
                )
            } else if fallback.purpose == .prefetch {
                if pendingSpeechPrefetchRequest == nil {
                    // A tap arrived while a silent request was waiting for the
                    // inference gate. Preserve the prefetch for the next loop,
                    // but let the tap go first.
                    pendingSpeechPrefetchRequest = fallback
                } else if let waitingPrefetch = pendingSpeechPrefetchRequest,
                          waitingPrefetch.preparationKey
                            != fallback.preparationKey {
                    if fallback.isForegroundPrefetch
                        && !waitingPrefetch.isForegroundPrefetch {
                        pendingSpeechPrefetchRequest = fallback
                        finishSpeechPreparation(
                            for: waitingPrefetch,
                            shouldContinue: false
                        )
                    } else {
                        finishSpeechPreparation(
                            for: fallback,
                            shouldContinue: false
                        )
                    }
                }
            } else if fallback.preparationKey
                        != latestRequest.preparationKey {
                if pendingSpeechPrefetchRequest?.preparationKey
                    != fallback.preparationKey {
                    finishSpeechPreparation(
                        for: fallback,
                        shouldContinue: false
                    )
                }
            }
            currentSpeechRequest = latestRequest
            return latestRequest
        }

        if fallbackWasAbandoned {
            finishSpeechPreparation(
                for: fallback,
                shouldContinue: false
            )
            if let prefetchRequest = pendingSpeechPrefetchRequest {
                pendingSpeechPrefetchRequest = nil
                currentSpeechRequest = prefetchRequest
                return prefetchRequest
            }
            currentSpeechRequest = nil
            return nil
        }

        switch fallback.purpose {
        case .playback:
            guard activeSpeechRequest?.id == fallback.id else {
                if let prefetchRequest = pendingSpeechPrefetchRequest {
                    pendingSpeechPrefetchRequest = nil
                    if prefetchRequest.preparationKey
                        != fallback.preparationKey {
                        finishSpeechPreparation(
                            for: fallback,
                            shouldContinue: false
                        )
                    }
                    currentSpeechRequest = prefetchRequest
                    return prefetchRequest
                }
                finishSpeechPreparation(
                    for: fallback,
                    shouldContinue: false
                )
                currentSpeechRequest = nil
                return nil
            }

        case .prefetch:
            if let latestPrefetch = pendingSpeechPrefetchRequest {
                if fallback.isForegroundPrefetch
                    && !latestPrefetch.isForegroundPrefetch {
                    // Finish the visible word first. The background request
                    // remains queued for the following worker iteration.
                    currentSpeechRequest = fallback
                    return fallback
                }
                pendingSpeechPrefetchRequest = nil
                if latestPrefetch.preparationKey
                    != fallback.preparationKey {
                    finishSpeechPreparation(
                        for: fallback,
                        shouldContinue: false
                    )
                }
                currentSpeechRequest = latestPrefetch
                return latestPrefetch
            }
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
                finishSpeechPreparation(
                    for: completed.request,
                    shouldContinue: false
                )
                return
            }
            generatedSpeechCache.setObject(
                completed.audio as NSData,
                forKey: completed.request.cacheKey as NSString,
                cost: completed.audio.count
            )

            // A repeated tap for the same key is satisfied by the synthesis
            // that was already in progress; do not enqueue it a second time.
            if pendingSpeechRequest?.preparationKey
                == completed.request.preparationKey {
                pendingSpeechRequest = nil
            }
            if pendingSpeechPrefetchRequest?.preparationKey
                == completed.request.preparationKey {
                pendingSpeechPrefetchRequest = nil
            }
            finishSpeechPreparation(for: completed.request)

            guard activeSpeechRequest?.preparationKey
                    == completed.request.preparationKey else {
                return
            }
            do {
                try startPlayback(
                    completed.audio,
                    cacheKey: completed.request.cacheKey
                )
            } catch {
                if shouldDiscardSpeechAudio(after: error) {
                    generatedSpeechCache.removeObject(
                        forKey: completed.request.cacheKey as NSString
                    )
                }
                naturalVoiceError = error.localizedDescription
            }

        case .failed(let request, let message):
            finishSpeechPreparation(for: request)
            guard request.cacheRevision == speechCacheRevision else {
                return
            }
            if pendingSpeechRequest?.preparationKey
                == request.preparationKey {
                pendingSpeechRequest = nil
            }
            if pendingSpeechPrefetchRequest?.preparationKey
                == request.preparationKey {
                pendingSpeechPrefetchRequest = nil
            }
            if activeSpeechRequest?.preparationKey == request.preparationKey {
                naturalVoiceError = message
            }
        }
    }

    private func finishSpeechPreparation(
        for request: SpeechRequest,
        shouldContinue: Bool = true
    ) {
        abandonedSpeechRequestIDs.remove(request.id)
        let waiters = speechPreparationWaiters.removeValue(
            forKey: request.preparationKey
        ) ?? [:]
        for waiter in waiters.values {
            waiter.resume(returning: shouldContinue)
        }
    }

    private func finishSpeechPreparationIfIdle(
        for request: SpeechRequest,
        shouldContinue: Bool = false
    ) {
        let preparationKey = request.preparationKey
        guard currentSpeechRequest?.preparationKey != preparationKey,
              pendingSpeechRequest?.preparationKey != preparationKey,
              pendingSpeechPrefetchRequest?.preparationKey
                != preparationKey else {
            return
        }
        finishSpeechPreparation(
            for: request,
            shouldContinue: shouldContinue
        )
    }

    private func cancelSpeechPreparationWaiter(
        _ waiterID: UUID,
        for preparationKey: SpeechPreparationKey
    ) {
        guard var waiters = speechPreparationWaiters[preparationKey],
              let waiter = waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.resume(returning: false)

        guard waiters.isEmpty else {
            speechPreparationWaiters[preparationKey] = waiters
            return
        }
        speechPreparationWaiters.removeValue(forKey: preparationKey)

        if let pendingPrefetch = pendingSpeechPrefetchRequest,
           pendingPrefetch.preparationKey == preparationKey {
            pendingSpeechPrefetchRequest = nil
        }
        if let currentRequest = currentSpeechRequest,
           currentRequest.purpose == .prefetch,
           currentRequest.preparationKey == preparationKey {
            // `takeRequestForSynthesis` checks this after it acquires the gate.
            // If Core ML has already started, the request simply finishes into
            // cache and playback remains disabled.
            abandonedSpeechRequestIDs.insert(currentRequest.id)
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
