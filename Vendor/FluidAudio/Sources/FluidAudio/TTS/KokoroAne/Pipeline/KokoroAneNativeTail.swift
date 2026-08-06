import Accelerate
@preconcurrency import CoreML
import Foundation

/// Native implementation of the small Kokoro iSTFT tail graph.
///
/// Some Apple OS/runtime combinations reuse a dynamic-shape BNNS scratch
/// buffer after its input grows, writing beyond the old allocation. Keeping
/// this final, weight-only graph out of Core ML avoids that native crash while
/// preserving the exact operations encoded in `KokoroTail.mlmodelc`.
struct KokoroAneNativeTail: Sendable {
    private static let inputChannels = 128
    private static let outputChannels = 22
    private static let spectrumBins = 11
    private static let convolutionKernel = 7
    private static let synthesisKernel = 20
    private static let synthesisStride = 5
    private static let minimumInputLength = 100
    private static let maximumInputLength = 240_001

    private let bias: [Float]
    /// Seven row-major `[22, 128]` matrices, one for each kernel position.
    private let convolutionWeightsByKernel: [Float]
    private let realSynthesisWeights: [Float]
    private let imaginarySynthesisWeights: [Float]

    init(modelURL: URL) throws {
        let weightsURL =
            modelURL
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin", isDirectory: false)
        let blob = try Data(contentsOf: weightsURL, options: [.mappedIfSafe])
        let reader = try CoreMLWeightBlob(data: blob, source: weightsURL)

        bias = try reader.float32Blob(
            descriptorOffset: 64,
            expectedCount: Self.outputChannels
        )
        realSynthesisWeights = try reader.float32Blob(
            descriptorOffset: 256,
            expectedCount: Self.spectrumBins * Self.synthesisKernel
        )
        imaginarySynthesisWeights = try reader.float32Blob(
            descriptorOffset: 1_216,
            expectedCount: Self.spectrumBins * Self.synthesisKernel
        )
        let convolutionWeights = try reader.float32Blob(
            descriptorOffset: 2_176,
            expectedCount: Self.outputChannels
                * Self.inputChannels
                * Self.convolutionKernel
        )

        // Core ML stores W as [output, input, kernel]. BLAS needs one
        // contiguous [output, input] matrix per kernel position.
        var reordered = [Float](repeating: 0, count: convolutionWeights.count)
        for kernel in 0..<Self.convolutionKernel {
            for output in 0..<Self.outputChannels {
                for input in 0..<Self.inputChannels {
                    let source =
                        (output * Self.inputChannels + input)
                        * Self.convolutionKernel + kernel
                    let destination =
                        kernel
                        * Self.outputChannels * Self.inputChannels
                        + output * Self.inputChannels + input
                    reordered[destination] = convolutionWeights[source]
                }
            }
        }
        convolutionWeightsByKernel = reordered
    }

    func predict(xPre: MLMultiArray) throws -> [Float] {
        let shape = xPre.shape.map(\.intValue)
        guard shape.count == 3,
            shape[0] == 1,
            shape[1] == Self.inputChannels,
            (Self.minimumInputLength...Self.maximumInputLength).contains(shape[2])
        else {
            throw KokoroAneError.unexpectedOutputShape(
                stage: KokoroAneStage.tail.rawValue,
                expected:
                    "x_pre [1, 128, L], L in "
                    + "\(Self.minimumInputLength)...\(Self.maximumInputLength)",
                got: "\(shape)"
            )
        }

        let length = shape[2]
        let inputCountResult = Self.inputChannels.multipliedReportingOverflow(by: length)
        guard !inputCountResult.overflow, xPre.count == inputCountResult.partialValue else {
            throw KokoroAneError.unexpectedOutputShape(
                stage: KokoroAneStage.tail.rawValue,
                expected: "\(Self.inputChannels * length) contiguous values",
                got: "\(xPre.count) values"
            )
        }

        let expectedStrides = [Self.inputChannels * length, length, 1]
        if xPre.dataType == .float32, xPre.strides.map(\.intValue) == expectedStrides {
            let pointer = xPre.dataPointer.assumingMemoryBound(to: Float.self)
            return try predict(
                input: UnsafeBufferPointer(start: pointer, count: xPre.count),
                length: length
            )
        }

        // Retain compatibility with a strided MLMultiArray while keeping the
        // normal contiguous Vocoder output on the zero-copy path.
        let copiedInput = KokoroAneArrays.readFloats(xPre)
        return try copiedInput.withUnsafeBufferPointer { input in
            try predict(input: input, length: length)
        }
    }

    private func predict(input: UnsafeBufferPointer<Float>, length: Int) throws -> [Float] {
        guard !input.contains(where: { !$0.isFinite }) else {
            throw KokoroAneError.nonFiniteModelOutput(
                stage: KokoroAneStage.vocoder.rawValue,
                output: "x_pre"
            )
        }

        // The compiled Tail model permits at most 240,001 frames, so these
        // exact conversions are guaranteed after the shape check above.
        guard let blasLength = Int32(exactly: length) else {
            throw KokoroAneError.unexpectedOutputShape(
                stage: KokoroAneStage.tail.rawValue,
                expected: "a BLAS-compatible input length",
                got: "\(length)"
            )
        }
        var convolution = [Float](
            repeating: 0,
            count: Self.outputChannels * length
        )

        // Initialize the 22 output rows with their scalar biases.
        for output in 0..<Self.outputChannels {
            let rowStart = output * length
            convolution.withUnsafeMutableBufferPointer { destination in
                var value = bias[output]
                vDSP_vfill(
                    &value,
                    destination.baseAddress! + rowStart,
                    1,
                    vDSP_Length(length)
                )
            }
        }

        // Conv1D(k=7, pad=3, stride=1) as seven GEMMs. Cropping the input
        // and destination columns for each offset exactly supplies the three
        // implicit zero-padding positions without materializing im2col.
        convolutionWeightsByKernel.withUnsafeBufferPointer { weights in
            input.withUnsafeBufferPointer { source in
                convolution.withUnsafeMutableBufferPointer { destination in
                    for kernel in 0..<Self.convolutionKernel {
                        let shift = kernel - 3
                        let inputStart = max(shift, 0)
                        let outputStart = max(-shift, 0)
                        let columnCount = length - abs(shift)
                        guard columnCount > 0 else { continue }

                        cblas_sgemm(
                            CblasRowMajor,
                            CblasNoTrans,
                            CblasNoTrans,
                            Int32(Self.outputChannels),
                            Int32(columnCount),
                            Int32(Self.inputChannels),
                            1,
                            weights.baseAddress!
                                + kernel * Self.outputChannels * Self.inputChannels,
                            Int32(Self.inputChannels),
                            source.baseAddress! + inputStart,
                            blasLength,
                            1,
                            destination.baseAddress! + outputStart,
                            blasLength
                        )
                    }
                }
            }
        }

        // The MIL graph represents an 11-bin complex spectrum as magnitude
        // and a bounded phase: exp(mag), then cos(sin(raw))/sin(sin(raw)).
        var realSpectrum = [Float](repeating: 0, count: Self.spectrumBins * length)
        var imaginarySpectrum = [Float](repeating: 0, count: realSpectrum.count)
        for bin in 0..<Self.spectrumBins {
            let magnitudeRow = bin * length
            let phaseRow = (bin + Self.spectrumBins) * length
            for frame in 0..<length {
                let magnitude = expf(convolution[magnitudeRow + frame])
                let phase = sinf(convolution[phaseRow + frame])
                guard magnitude.isFinite, phase.isFinite else {
                    throw KokoroAneError.nonFiniteModelOutput(
                        stage: KokoroAneStage.tail.rawValue,
                        output: "spectrum"
                    )
                }
                realSpectrum[magnitudeRow + frame] = magnitude * cosf(phase)
                imaginarySpectrum[magnitudeRow + frame] = magnitude * sinf(phase)
            }
        }

        // Two ConvTranspose1D(k=20, stride=5) operations, subtraction, and
        // the graph's ten-sample crop on each side. Combining the two paths
        // avoids allocating their full intermediate waveforms.
        let sampleCount = Self.synthesisStride * length - Self.synthesisStride
        var samples = [Float](repeating: 0, count: sampleCount)
        for bin in 0..<Self.spectrumBins {
            let spectrumRow = bin * length
            let weightRow = bin * Self.synthesisKernel
            for frame in 0..<length {
                let real = realSpectrum[spectrumRow + frame]
                let imaginary = imaginarySpectrum[spectrumRow + frame]
                let fullOutputStart = frame * Self.synthesisStride
                for kernel in 0..<Self.synthesisKernel {
                    let output = fullOutputStart + kernel - 10
                    guard output >= 0, output < sampleCount else { continue }
                    samples[output] +=
                        real * realSynthesisWeights[weightRow + kernel]
                        - imaginary * imaginarySynthesisWeights[weightRow + kernel]
                }
            }
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw KokoroAneError.nonFiniteModelOutput(
                stage: KokoroAneStage.tail.rawValue,
                output: "audio"
            )
        }
        return samples
    }
}

private struct CoreMLWeightBlob {
    private static let fileHeaderSize = 64
    private static let descriptorSize = 64
    private static let sentinel: UInt32 = 0xDEAD_BEEF
    private static let float32Type: UInt32 = 2

    private let data: Data
    private let source: URL

    init(data: Data, source: URL) throws {
        self.data = data
        self.source = source
        guard data.count >= Self.fileHeaderSize else {
            throw KokoroAneError.inputProcessingFailed(
                "Kokoro Tail weights are truncated at \(source.path)"
            )
        }
        let blobCount = try uint32(at: 0)
        let version = try uint32(at: 4)
        guard blobCount == 4, version == 2 else {
            throw KokoroAneError.inputProcessingFailed(
                "Kokoro Tail weights have unsupported header count=\(blobCount), version=\(version)"
            )
        }
    }

    func float32Blob(descriptorOffset: Int, expectedCount: Int) throws -> [Float] {
        guard descriptorOffset.isMultiple(of: 64),
            descriptorOffset >= Self.fileHeaderSize,
            descriptorOffset <= data.count - Self.descriptorSize
        else {
            throw invalid("invalid descriptor offset \(descriptorOffset)")
        }

        let foundSentinel = try uint32(at: descriptorOffset)
        let dataType = try uint32(at: descriptorOffset + 4)
        let byteCount64 = try uint64(at: descriptorOffset + 8)
        let dataOffset64 = try uint64(at: descriptorOffset + 16)
        let paddingBits = try uint64(at: descriptorOffset + 24)
        let expectedBytes = expectedCount.multipliedReportingOverflow(by: 4)

        guard foundSentinel == Self.sentinel,
            dataType == Self.float32Type,
            paddingBits == 0,
            !expectedBytes.overflow,
            byteCount64 == UInt64(expectedBytes.partialValue),
            dataOffset64 <= UInt64(Int.max)
        else {
            throw invalid("invalid Float32 descriptor at byte \(descriptorOffset)")
        }

        let dataOffset = Int(dataOffset64)
        let end = dataOffset.addingReportingOverflow(expectedBytes.partialValue)
        guard dataOffset.isMultiple(of: 64),
            !end.overflow,
            dataOffset >= 0,
            end.partialValue <= data.count
        else {
            throw invalid("out-of-bounds payload at byte \(dataOffset)")
        }

        var values = [Float](repeating: 0, count: expectedCount)
        for index in 0..<expectedCount {
            let bits = try uint32(at: dataOffset + index * 4)
            values[index] = Float(bitPattern: bits)
        }
        guard values.allSatisfy(\.isFinite) else {
            throw invalid("non-finite Float32 payload at byte \(dataOffset)")
        }
        return values
    }

    private func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
            throw invalid("truncated UInt32 at byte \(offset)")
        }
        return data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private func uint64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt64>.size else {
            throw invalid("truncated UInt64 at byte \(offset)")
        }
        return data.withUnsafeBytes { bytes in
            UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private func invalid(_ detail: String) -> KokoroAneError {
        KokoroAneError.inputProcessingFailed(
            "Kokoro Tail weights at \(source.path) are invalid: \(detail)"
        )
    }
}
