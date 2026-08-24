//
//  WordCloudView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/20/21.
//

import Foundation
import CoreGraphics

/// Maps today's accumulated answer difficulty to a stable visual hierarchy.
/// A normal single answer is GOOD = 0, VAGUE = 1, or NOIDEA = 2. Repeated
/// difficulty can raise the day's maximum while the mapping remains linear.
enum WordCloudDifficultyScale {
    static let minimumFontSize: CGFloat = 22
    static let maximumFontSize: CGFloat = 50

    static func normalizedDifficulty(
        for difficultyScore: Int,
        maximumDifficultyScore: Int
    ) -> CGFloat {
        let score = max(difficultyScore, 0)
        // Anchor an ordinary answer at GOOD / VAGUE / NOIDEA = 0 / 1 / 2.
        // A larger maximum only occurs when a word was difficult repeatedly.
        let scaleMaximum = max(maximumDifficultyScore, 2)
        return min(CGFloat(score) / CGFloat(scaleMaximum), 1)
    }

    static func fontSize(
        for difficultyScore: Int,
        maximumDifficultyScore: Int
    ) -> CGFloat {
        let normalizedDifficulty = normalizedDifficulty(
            for: difficultyScore,
            maximumDifficultyScore: maximumDifficultyScore
        )
        return minimumFontSize
            + (maximumFontSize - minimumFontSize) * normalizedDifficulty
    }
}

#if !WORD_CLOUD_LAYOUT_HARNESS
import SwiftUI

struct WordElement {
    let text: String
    let color: Color
    let fontName: String
    let fontSize: CGFloat
    let difficultyScore: Int
}

struct WordCloudView: View {
    private let words: [WordElement]

    @State private var topologyCache = WordCloudTopologyCache()
    @State private var wordSizes: [CGSize]
    @State private var measuredWordsSignature: String

    init() {
        let generatedWords = [WordElement].generate()
        words = generatedWords
        self._wordSizes = State(
            initialValue: [CGSize](repeating: .zero, count: generatedWords.count)
        )
        self._measuredWordsSignature = State(
            initialValue: Self.signature(for: generatedWords)
        )
    }

    init(_ words: [WordElement]) {
        self.words = words
        self._wordSizes = State(
            initialValue: [CGSize](repeating: .zero, count: words.count)
        )
        self._measuredWordsSignature = State(
            initialValue: Self.signature(for: words)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let squareCanvas = WordCloudLayoutMetrics.squareCanvas(
                inside: proxy.size
            )
            cloud(canvasSize: squareCanvas)
                .frame(
                    width: squareCanvas.width,
                    height: squareCanvas.height
                )
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height / 2
                )
        }
    }

    private func cloud(canvasSize: CGSize) -> some View {
        let wordsSignature = Self.signature(for: words)
        let measurementsAreCurrent = measuredWordsSignature == wordsSignature
            && wordSizes.count == words.count
        let hasAllMeasurements = measurementsAreCurrent
            && wordSizes.allSatisfy { $0.width > 0 && $0.height > 0 }
        let packing = hasAllMeasurements
            ? topologyCache.packing(
                itemSizes: wordSizes,
                priorities: words.map { CGFloat($0.difficultyScore) },
                canvasAspectRatio: WordCloudLayoutMetrics.packingAspectRatio,
                spacing: 4
            )
            : WordCloudPacking(
                positions: [CGPoint](repeating: .zero, count: words.count),
                bounds: .zero
            )
        let renderScale = hasAllMeasurements
            ? WordCloudLayoutMetrics.renderScale(
                packingBounds: packing.bounds,
                canvasSize: canvasSize,
                inset: 10,
                fillFraction: 0.92,
                maximumScale: WordCloudLayoutMetrics.maximumRenderScale(
                    canvasSize: canvasSize
                )
            )
            : 1

        return ZStack {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                NavigationLink(destination: CardView(word.text, true, true)) {
                    Text(word.text)
                        .foregroundColor(word.color)
                        .font(Font.custom(word.fontName, size: word.fontSize))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(2)
                        .background(WordSizeGetter($wordSizes, index))
                }
                // Measurement always happens at the reference font size.
                // Scaling is visual only, so it cannot trigger a remeasure/repack loop.
                .scaleEffect(renderScale, anchor: .center)
                .position(
                    x: canvasSize.width / 2 + packing.positions[index].x * renderScale,
                    y: canvasSize.height / 2 + packing.positions[index].y * renderScale
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
        .opacity(words.isEmpty || hasAllMeasurements ? 1 : 0)
        .onChange(of: wordsSignature) { newSignature in
            measuredWordsSignature = newSignature
            wordSizes = [CGSize](repeating: .zero, count: words.count)
            topologyCache.invalidate()
        }
    }

    private static func signature(for words: [WordElement]) -> String {
        words.map { word in
            "\(word.text.count):\(word.text)|\(word.fontName)|\(word.fontSize)|\(word.difficultyScore)"
        }
        .joined(separator: "\u{1f}")
    }
}

private final class WordCloudTopologyCache {
    private var itemSizes = [CGSize]()
    private var priorities = [CGFloat]()
    private var canvasAspectRatio: CGFloat = 0
    private var spacing: CGFloat = 0
    private var cachedPacking: WordCloudPacking?

    func packing(
        itemSizes: [CGSize],
        priorities: [CGFloat],
        canvasAspectRatio: CGFloat,
        spacing: CGFloat
    ) -> WordCloudPacking {
        if let cachedPacking,
            sizesMatch(itemSizes, self.itemSizes),
            valuesMatch(priorities, self.priorities),
            abs(canvasAspectRatio - self.canvasAspectRatio) < 0.015,
            abs(spacing - self.spacing) < 0.01
        {
            return cachedPacking
        }

        let packing = WordCloudPacker.pack(
            itemSizes: itemSizes,
            priorities: priorities,
            canvasAspectRatio: canvasAspectRatio,
            spacing: spacing
        )
        self.itemSizes = itemSizes
        self.priorities = priorities
        self.canvasAspectRatio = canvasAspectRatio
        self.spacing = spacing
        self.cachedPacking = packing
        return packing
    }

    func invalidate() {
        itemSizes = []
        priorities = []
        canvasAspectRatio = 0
        spacing = 0
        cachedPacking = nil
    }

    private func sizesMatch(_ lhs: [CGSize], _ rhs: [CGSize]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { first, second in
            abs(first.width - second.width) < 0.25
                && abs(first.height - second.height) < 0.25
        }
    }

    private func valuesMatch(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.001 }
    }
}
#endif

struct WordCloudPacking {
    let positions: [CGPoint]
    let bounds: CGRect
}

enum WordCloudLayoutMetrics {
    /// The share page may be portrait, landscape, split-screen, iPad, or Mac,
    /// but the authored cloud always occupies the largest centered square that
    /// fits in the available region.
    static let packingAspectRatio: CGFloat = 1

    static func squareCanvas(inside availableSize: CGSize) -> CGSize {
        let side = max(0, min(availableSize.width, availableSize.height))
        return CGSize(width: side, height: side)
    }

    /// Keep sparse iPhone clouds near their authored font sizes while still
    /// allowing the same design to grow moderately on iPad and Mac.
    static func maximumRenderScale(canvasSize: CGSize) -> CGFloat {
        let shortestSide = min(canvasSize.width, canvasSize.height)
        let maximumRenderedFont = min(max(shortestSide * 0.14, 54), 76)
        return maximumRenderedFont / WordCloudDifficultyScale.maximumFontSize
    }

    static func renderScale(
        packingBounds: CGRect,
        canvasSize: CGSize,
        inset: CGFloat,
        fillFraction: CGFloat,
        maximumScale: CGFloat
    ) -> CGFloat {
        guard packingBounds.width > 0,
            packingBounds.height > 0,
            canvasSize.width > inset * 2,
            canvasSize.height > inset * 2
        else {
            return 1
        }

        let usableWidth = canvasSize.width - inset * 2
        let usableHeight = canvasSize.height - inset * 2
        let fitScale = min(
            usableWidth / packingBounds.width,
            usableHeight / packingBounds.height
        ) * fillFraction
        return max(0.05, min(fitScale, maximumScale))
    }
}

/// Deterministic confidence-first word-cloud packing. High-difficulty words
/// establish the center and the remaining words follow an elliptical golden-
/// angle spiral. Multiple stable phases are scored to avoid a row or column.
enum WordCloudPacker {
    private struct Variant {
        let phase: CGFloat
        let direction: CGFloat
    }

    private static let variants = [
        Variant(phase: 0, direction: 1),
        Variant(phase: .pi / 4, direction: 1),
        Variant(phase: .pi / 2, direction: 1),
        Variant(phase: .pi * 3 / 4, direction: 1),
    ]

    static func pack(
        itemSizes: [CGSize],
        priorities: [CGFloat],
        canvasAspectRatio: CGFloat,
        spacing: CGFloat
    ) -> WordCloudPacking {
        guard !itemSizes.isEmpty, priorities.count == itemSizes.count else {
            return WordCloudPacking(positions: [], bounds: .zero)
        }

        let targetAspect = min(max(canvasAspectRatio, 0.9), 1.8)
        let placementOrder = priorityOrder(
            itemSizes: itemSizes,
            priorities: priorities
        )
        let wordArea = itemSizes.reduce(CGFloat.zero) {
            $0 + $1.width * $1.height
        }
        var bestPacking: WordCloudPacking?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for variant in variants {
            let packing = pack(
                itemSizes: itemSizes,
                placementOrder: placementOrder,
                spacing: spacing,
                targetAspect: targetAspect,
                variant: variant
            )
            let score = packingScore(
                bounds: packing.bounds,
                targetAspect: targetAspect,
                wordArea: wordArea,
                primaryPosition: packing.positions[placementOrder[0]]
            )
            if score < bestScore - 0.0001 {
                bestScore = score
                bestPacking = packing
            }
        }

        return bestPacking ?? WordCloudPacking(
            positions: [CGPoint](repeating: .zero, count: itemSizes.count),
            bounds: .zero
        )
    }

    private static func pack(
        itemSizes: [CGSize],
        placementOrder: [Int],
        spacing: CGFloat,
        targetAspect: CGFloat,
        variant: Variant
    ) -> WordCloudPacking {
        var positions = [CGPoint](repeating: .zero, count: itemSizes.count)
        var placedFrames = [CGRect]()
        var clusterBounds = CGRect.null

        for index in placementOrder {
            let itemSize = itemSizes[index]
            let paddedSize = CGSize(
                width: itemSize.width + spacing,
                height: itemSize.height + spacing
            )
            let center = placedFrames.isEmpty
                ? CGPoint.zero
                : spiralCenter(
                    for: paddedSize,
                    placedFrames: placedFrames,
                    targetAspect: targetAspect,
                    variant: variant
                )
            let frame = CGRect(
                x: center.x - paddedSize.width / 2,
                y: center.y - paddedSize.height / 2,
                width: paddedSize.width,
                height: paddedSize.height
            )
            positions[index] = center
            placedFrames.append(frame)
            clusterBounds = clusterBounds.isNull ? frame : clusterBounds.union(frame)
        }

        let packedCenter = clusterBounds.center
        return WordCloudPacking(
            positions: positions.map {
                CGPoint(x: $0.x - packedCenter.x, y: $0.y - packedCenter.y)
            },
            bounds: clusterBounds.offsetBy(
                dx: -packedCenter.x,
                dy: -packedCenter.y
            )
        )
    }

    private static func priorityOrder(
        itemSizes: [CGSize],
        priorities: [CGFloat]
    ) -> [Int] {
        itemSizes.indices.sorted { first, second in
            if abs(priorities[first] - priorities[second]) > 0.001 {
                return priorities[first] > priorities[second]
            }
            return first < second
        }
    }

    private static func spiralCenter(
        for size: CGSize,
        placedFrames: [CGRect],
        targetAspect: CGFloat,
        variant: Variant
    ) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let goldenAngle = CGFloat.pi * (3 - sqrt(5))
        let horizontalScale = sqrt(targetAspect)
        let verticalScale = 1 / horizontalScale

        for sample in 1...20_000 {
            let radius = sqrt(CGFloat(sample)) * 3
            let angle = variant.phase
                + variant.direction * CGFloat(sample) * goldenAngle
            let candidate = CGPoint(
                x: radius * cos(angle) * horizontalScale,
                y: radius * sin(angle) * verticalScale
            )
            let frame = CGRect(
                x: candidate.x - halfWidth,
                y: candidate.y - halfHeight,
                width: size.width,
                height: size.height
            )
            if !placedFrames.contains(where: { $0.intersects(frame) }) {
                return candidate
            }
        }

        let outerBounds = placedFrames.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(
            x: outerBounds.maxX + halfWidth + 1,
            y: outerBounds.midY
        )
    }

    private static func packingScore(
        bounds: CGRect,
        targetAspect: CGFloat,
        wordArea: CGFloat,
        primaryPosition: CGPoint
    ) -> CGFloat {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let normalizedExtent = max(width / targetAspect, height)
        let canvasEnvelopeArea = max(
            targetAspect * normalizedExtent * normalizedExtent,
            1
        )
        let unusedFraction = max(
            0,
            1 - (width * height / canvasEnvelopeArea)
        )
        let emptyFraction = max(0, 1 - wordArea / max(width * height, 1))
        let primaryCenterPenalty = hypot(
            primaryPosition.x / max(width, 1),
            primaryPosition.y / max(height, 1)
        )
        return normalizedExtent
            * (1
                + unusedFraction * 0.10
                + emptyFraction * 0.08
                + primaryCenterPenalty * 0.10)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

#if !WORD_CLOUD_LAYOUT_HARNESS
struct WordSizeGetter: View {
    @Binding var sizeStorage: [CGSize]
    private var index: Int

    init(_ sizeStorage: Binding<[CGSize]>, _ index: Int) {
        _sizeStorage = sizeStorage
        self.index = index
    }

    var body: some View {
        GeometryReader { proxy in
            createView(proxy: proxy)
        }
    }

    private func createView(proxy: GeometryProxy) -> some View {
        let measuredSize = proxy.size
        DispatchQueue.main.async {
            guard index < sizeStorage.count else { return }
            let currentSize = sizeStorage[index]
            if abs(currentSize.width - measuredSize.width) > 0.1
                || abs(currentSize.height - measuredSize.height) > 0.1
            {
                sizeStorage[index] = measuredSize
            }
        }
        return Rectangle().fill(Color.clear)
    }
}

extension Array where Element == WordElement {
    static let colorPlate = ["shareFont1", "shareFont2", "shareFont3",
                             "shareFont1", "shareFont5"]
    static let fontPlate = ["SFProText-Bold", "SFProText-Medium",
                            "SFProText-Regular", "SFProText-Semibold"]

    static func generate(_ cap: Int = Int.random(in: 1...50)) -> [WordElement] {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        var words = [WordElement]()
        for _ in 0...cap {
            words.append(
                WordElement(
                    text: String((0...Int.random(in: 4...9)).map { _ in
                        letters.randomElement()!
                    }),
                    color: Color(colorPlate.randomElement()!),
                    fontName: fontPlate.randomElement()!,
                    fontSize: CGFloat.random(in: 20...50),
                    difficultyScore: Int.random(in: 0...2)
                )
            )
        }
        return words
    }
}

struct WordCloudView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            WordCloudView()
                .previewLayout(.fixed(width: 390, height: 430))
            WordCloudView()
                .previewLayout(.fixed(width: 720, height: 520))
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }
}
#endif
