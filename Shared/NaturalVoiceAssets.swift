//
//  NaturalVoiceAssets.swift
//  Wordbook
//
//  Keeps Kokoro's large acoustic models in the signed app bundle and seeds
//  FluidAudio's hard-coded English G2P cache from bundled resources.
//

#if WORDBOOK_NATURAL_VOICE

import Foundation
import FluidAudio

actor BundledNaturalVoiceAssets {
    static let shared = BundledNaturalVoiceAssets()

    static let version = "fluid-0.15.5-kokoro-ane-en-v1"

    private static let resourceDirectoryName = "NaturalVoiceModels"
    private static let acousticModelDirectory = "kokoro-82m-coreml/ANE"
    private static let frontendDirectory = "kokoro"

    private static let acousticModelFiles = [
        "KokoroAlbert.mlmodelc",
        "KokoroPostAlbert.mlmodelc",
        "KokoroAlignment.mlmodelc",
        "KokoroProsody.mlmodelc",
        "KokoroNoise_v2.mlmodelc",
        "KokoroVocoder.mlmodelc",
        "KokoroTail.mlmodelc",
        "vocab.json",
        "af_heart.bin",
    ]

    private static let frontendFiles = [
        "G2PEncoder.mlmodelc",
        "G2PDecoder.mlmodelc",
        "g2p_vocab.json",
        "us_lexicon_cache.json",
    ]

    private var preparedRoot: URL?

    /// Locates the signed resources and installs the small English
    /// pronunciation frontend into FluidAudio's required cache location. The
    /// much larger seven-stage acoustic model remains in the app bundle.
    func prepare() throws -> URL {
        // The app ships every required English asset. If a future build omits
        // one, fail visibly instead of silently reaching Hugging Face.
        ModelHub.offlineMode = true

        if let preparedRoot = preparedRoot {
            try Self.installFrontendAssets(from: preparedRoot)
            return preparedRoot
        }

        let bundledRoot = try Self.bundledRootURL()
        try Self.validateBundledAssets(at: bundledRoot)
        try Self.installFrontendAssets(from: bundledRoot)
        preparedRoot = bundledRoot

        return bundledRoot
    }

    private static func bundledRootURL() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw AssetError.resourcesUnavailable
        }

        let root = resources.appendingPathComponent(
            resourceDirectoryName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw AssetError.missingFiles([resourceDirectoryName])
        }
        return root
    }

    /// This is a packaging sanity check, not an integrity check. The app's
    /// code signature protects bundled resources, while Core ML validates the
    /// compiled models when loading them.
    private static func validateBundledAssets(at root: URL) throws {
        let modelRoot = root.appendingPathComponent(acousticModelDirectory)
        let frontendRoot = root.appendingPathComponent(frontendDirectory)

        let missingModels = acousticModelFiles.compactMap { filename -> String? in
            let url = modelRoot.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path)
                ? nil
                : "\(acousticModelDirectory)/\(filename)"
        }
        let missingFrontend = frontendFiles.compactMap { filename -> String? in
            let url = frontendRoot.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path)
                ? nil
                : "\(frontendDirectory)/\(filename)"
        }

        let missing = missingModels + missingFrontend
        guard missing.isEmpty else {
            throw AssetError.missingFiles(missing)
        }
    }

    private static func installFrontendAssets(from bundledRoot: URL) throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AssetError.applicationSupportUnavailable
        }

        let fluidAudioRoot = applicationSupport.appendingPathComponent(
            "fluidaudio",
            isDirectory: true
        )
        let modelsRoot = fluidAudioRoot.appendingPathComponent(
            "Models",
            isDirectory: true
        )
        let target = modelsRoot.appendingPathComponent(
            frontendDirectory,
            isDirectory: true
        )
        let source = bundledRoot.appendingPathComponent(
            frontendDirectory,
            isDirectory: true
        )
        let marker = target.appendingPathComponent(".wordbook-assets-version")

        try FileManager.default.createDirectory(
            at: modelsRoot,
            withIntermediateDirectories: true
        )

        let installedVersion = try? String(
            contentsOf: marker,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let installationComplete = frontendFiles.allSatisfy { filename in
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent(filename).path
            )
        }

        if installedVersion != version || !installationComplete {
            let staging = modelsRoot.appendingPathComponent(
                ".wordbook-kokoro-staging-\(UUID().uuidString)",
                isDirectory: true
            )

            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )

            do {
                for filename in frontendFiles {
                    try FileManager.default.copyItem(
                        at: source.appendingPathComponent(filename),
                        to: staging.appendingPathComponent(filename)
                    )
                }

                try version.write(
                    to: staging.appendingPathComponent(".wordbook-assets-version"),
                    atomically: true,
                    encoding: .utf8
                )

                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(
                        target,
                        withItemAt: staging
                    )
                } else {
                    try FileManager.default.moveItem(at: staging, to: target)
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }

        // Older Wordbook builds let FluidAudio download the complete Kokoro
        // repository into Application Support. The acoustic chain now lives
        // in the signed app bundle, so that duplicate cache is no longer used.
        let legacyAcousticCache = modelsRoot.appendingPathComponent(
            "kokoro-82m-coreml",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: legacyAcousticCache.path) {
            try? FileManager.default.removeItem(at: legacyAcousticCache)
        }

        var excludedRoot = fluidAudioRoot
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedRoot.setResourceValues(resourceValues)
    }
}

private extension BundledNaturalVoiceAssets {
    enum AssetError: LocalizedError {
        case resourcesUnavailable
        case applicationSupportUnavailable
        case missingFiles([String])

        var errorDescription: String? {
            switch self {
            case .resourcesUnavailable:
                return "The bundled natural voice resources are unavailable."
            case .applicationSupportUnavailable:
                return "The natural voice pronunciation cache could not be created."
            case .missingFiles(let files):
                return "The app is missing bundled natural voice data: \(files.joined(separator: ", "))."
            }
        }
    }
}

#endif
