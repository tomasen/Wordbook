import Foundation

/// Errors emitted by the KokoroAne TTS chain.
public enum KokoroAneError: Error, LocalizedError {
    case modelNotLoaded(String)
    case nativeStageHasNoCoreMLModel(String)
    case downloadFailed(String)
    case vocabMissing(URL)
    case vocabParseFailed(URL, String)
    case voicePackMissing(URL)
    case invalidVoicePack(String)
    case phonemeSequenceTooLong(Int)
    case inputProcessingFailed(String)
    case acousticFramesExceedCap(have: Int, cap: Int)
    case predictionFailed(stage: String, underlying: Error)
    case unexpectedOutputShape(stage: String, expected: String, got: String)
    case nonFiniteModelOutput(stage: String, output: String)
    case audioConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let name):
            return "KokoroAne model '\(name)' not loaded. Call initialize() first."
        case .nativeStageHasNoCoreMLModel(let name):
            return "KokoroAne stage '\(name)' runs natively and has no loaded Core ML model."
        case .downloadFailed(let detail):
            return "KokoroAne download failed: \(detail)"
        case .vocabMissing(let url):
            return "KokoroAne vocab.json not found at \(url.path)."
        case .vocabParseFailed(let url, let detail):
            return "KokoroAne vocab.json at \(url.path) is malformed: \(detail)"
        case .voicePackMissing(let url):
            return "KokoroAne voice pack not found at \(url.path)."
        case .invalidVoicePack(let detail):
            return "KokoroAne voice pack is invalid: \(detail)"
        case .phonemeSequenceTooLong(let n):
            return
                "KokoroAne phoneme sequence has \(n) characters (max \(KokoroAneConstants.maxPhonemeLength))."
        case .inputProcessingFailed(let detail):
            return "KokoroAne input processing failed: \(detail)"
        case .acousticFramesExceedCap(let have, let cap):
            return
                "KokoroAne PostAlbert produced T_a=\(have) frames > MAX_FRAMES=\(cap). Chunk the input."
        case .predictionFailed(let stage, let err):
            return "KokoroAne stage '\(stage)' failed: \(err.localizedDescription)"
        case .unexpectedOutputShape(let stage, let expected, let got):
            return
                "KokoroAne stage '\(stage)' returned unexpected shape (expected \(expected), got \(got))."
        case .nonFiniteModelOutput(let stage, let output):
            return
                "KokoroAne stage '\(stage)' returned non-finite values in '\(output)'. "
                + "The Core ML runtime did not execute the model correctly on this OS."
        case .audioConversionFailed(let detail):
            return "KokoroAne audio conversion failed: \(detail)"
        }
    }
}
