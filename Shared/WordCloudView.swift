//
//  WordCloudView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/20/21.
//

import Foundation
import CoreGraphics

#if !WORD_CLOUD_LAYOUT_HARNESS
import SwiftUI

struct WordElement {
    let text: String
    let color: Color
    let fontName: String
    let fontSize: CGFloat
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
            cloud(canvasSize: proxy.size)
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
                canvasAspectRatio: canvasSize.width / max(canvasSize.height, 1),
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
                fillFraction: 0.96,
                maximumScale: 1.55
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
            "\(word.text.count):\(word.text)|\(word.fontName)|\(word.fontSize)"
        }
        .joined(separator: "\u{1f}")
    }
}

private final class WordCloudTopologyCache {
    private var itemSizes = [CGSize]()
    private var canvasAspectRatio: CGFloat = 0
    private var spacing: CGFloat = 0
    private var cachedPacking: WordCloudPacking?

    func packing(
        itemSizes: [CGSize],
        canvasAspectRatio: CGFloat,
        spacing: CGFloat
    ) -> WordCloudPacking {
        if let cachedPacking,
            sizesMatch(itemSizes, self.itemSizes),
            abs(canvasAspectRatio - self.canvasAspectRatio) < 0.015,
            abs(spacing - self.spacing) < 0.01
        {
            return cachedPacking
        }

        let packing = WordCloudPacker.pack(
            itemSizes: itemSizes,
            canvasAspectRatio: canvasAspectRatio,
            spacing: spacing
        )
        self.itemSizes = itemSizes
        self.canvasAspectRatio = canvasAspectRatio
        self.spacing = spacing
        self.cachedPacking = packing
        return packing
    }

    func invalidate() {
        itemSizes = []
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
}
#endif

struct WordCloudPacking {
    let positions: [CGPoint]
    let bounds: CGRect
}

enum WordCloudLayoutMetrics {
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

/// Deterministic edge-contact packing. Every candidate is scored by the
/// normalized canvas extent needed to contain it, rather than raw area alone.
/// Several stable order and direction variants are evaluated and the best
/// final topology is returned.
enum WordCloudPacker {
    private enum OrderStrategy {
        case area
        case longestSide
        case width
        case height
    }

    private enum SearchDirection {
        case horizontalForward
        case horizontalReverse
        case verticalForward
        case verticalReverse

        var prefersHorizontalGrowth: Bool {
            switch self {
            case .horizontalForward, .horizontalReverse:
                return true
            case .verticalForward, .verticalReverse:
                return false
            }
        }

        var reversesAnchors: Bool {
            switch self {
            case .horizontalReverse, .verticalReverse:
                return true
            case .horizontalForward, .verticalForward:
                return false
            }
        }
    }

    private struct Variant {
        let order: OrderStrategy
        let direction: SearchDirection
    }

    private static let variants = [
        Variant(order: .area, direction: .horizontalForward),
        Variant(order: .area, direction: .verticalForward),
        Variant(order: .longestSide, direction: .horizontalReverse),
        Variant(order: .longestSide, direction: .verticalReverse),
        Variant(order: .width, direction: .horizontalForward),
        Variant(order: .width, direction: .verticalReverse),
        Variant(order: .height, direction: .verticalForward),
        Variant(order: .height, direction: .horizontalReverse),
    ]

    static func pack(
        itemSizes: [CGSize],
        canvasAspectRatio: CGFloat,
        spacing: CGFloat
    ) -> WordCloudPacking {
        guard !itemSizes.isEmpty else {
            return WordCloudPacking(positions: [], bounds: .zero)
        }

        let targetAspect = min(max(canvasAspectRatio, 0.35), 3)
        var bestPacking: WordCloudPacking?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for variant in variants {
            let packing = pack(
                itemSizes: itemSizes,
                spacing: spacing,
                targetAspect: targetAspect,
                variant: variant
            )
            let score = packingScore(
                bounds: packing.bounds,
                targetAspect: targetAspect
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
        spacing: CGFloat,
        targetAspect: CGFloat,
        variant: Variant
    ) -> WordCloudPacking {
        let placementOrder = sortedIndices(
            for: itemSizes,
            strategy: variant.order
        )
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
                : bestCenter(
                    for: paddedSize,
                    placedFrames: placedFrames,
                    clusterBounds: clusterBounds,
                    targetAspect: targetAspect,
                    direction: variant.direction
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

    private static func sortedIndices(
        for itemSizes: [CGSize],
        strategy: OrderStrategy
    ) -> [Int] {
        itemSizes.indices.sorted { first, second in
            let firstSize = itemSizes[first]
            let secondSize = itemSizes[second]
            let firstPrimary: CGFloat
            let secondPrimary: CGFloat

            switch strategy {
            case .area:
                firstPrimary = firstSize.width * firstSize.height
                secondPrimary = secondSize.width * secondSize.height
            case .longestSide:
                firstPrimary = max(firstSize.width, firstSize.height)
                secondPrimary = max(secondSize.width, secondSize.height)
            case .width:
                firstPrimary = firstSize.width
                secondPrimary = secondSize.width
            case .height:
                firstPrimary = firstSize.height
                secondPrimary = secondSize.height
            }

            if abs(firstPrimary - secondPrimary) > 0.01 {
                return firstPrimary > secondPrimary
            }
            let firstArea = firstSize.width * firstSize.height
            let secondArea = secondSize.width * secondSize.height
            if abs(firstArea - secondArea) > 0.01 {
                return firstArea > secondArea
            }
            if abs(firstSize.width - secondSize.width) > 0.01 {
                return firstSize.width > secondSize.width
            }
            return first < second
        }
    }

    private static func bestCenter(
        for size: CGSize,
        placedFrames: [CGRect],
        clusterBounds: CGRect,
        targetAspect: CGFloat,
        direction: SearchDirection
    ) -> CGPoint {
        var candidates = [CGPoint]()
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let anchors = direction.reversesAnchors
            ? Array(placedFrames.reversed())
            : placedFrames

        for anchor in anchors {
            let horizontalAlignments = uniqueValues([
                anchor.midY,
                anchor.minY + halfHeight,
                anchor.maxY - halfHeight,
                0,
            ])
            let verticalAlignments = uniqueValues([
                anchor.midX,
                anchor.minX + halfWidth,
                anchor.maxX - halfWidth,
                0,
            ])

            let appendHorizontalCandidates = {
                for y in horizontalAlignments {
                    candidates.append(CGPoint(x: anchor.maxX + halfWidth, y: y))
                    candidates.append(CGPoint(x: anchor.minX - halfWidth, y: y))
                }
            }
            let appendVerticalCandidates = {
                for x in verticalAlignments {
                    candidates.append(CGPoint(x: x, y: anchor.maxY + halfHeight))
                    candidates.append(CGPoint(x: x, y: anchor.minY - halfHeight))
                }
            }

            if direction.prefersHorizontalGrowth {
                appendHorizontalCandidates()
                appendVerticalCandidates()
            } else {
                appendVerticalCandidates()
                appendHorizontalCandidates()
            }
        }

        var bestPoint: CGPoint?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in candidates {
            let frame = CGRect(
                x: candidate.x - halfWidth,
                y: candidate.y - halfHeight,
                width: size.width,
                height: size.height
            )
            guard !placedFrames.contains(where: { $0.intersects(frame) }) else {
                continue
            }

            let score = packingScore(
                bounds: clusterBounds.union(frame),
                targetAspect: targetAspect
            )
            if score < bestScore - 0.0001 {
                bestScore = score
                bestPoint = candidate
            }
        }

        if let bestPoint {
            return bestPoint
        }

        // Edge candidates normally guarantee a result. This deterministic
        // spiral remains as a defensive fallback for unusual floating-point
        // intersections.
        let goldenAngle = CGFloat.pi * (3 - sqrt(5))
        for sample in 1...20_000 {
            let radius = sqrt(CGFloat(sample)) * 3
            let angle = CGFloat(sample) * goldenAngle
            let candidate = CGPoint(
                x: radius * cos(angle),
                y: radius * sin(angle)
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

        return CGPoint(
            x: clusterBounds.maxX + halfWidth + 1,
            y: clusterBounds.midY
        )
    }

    private static func uniqueValues(_ values: [CGFloat]) -> [CGFloat] {
        var result = [CGFloat]()
        for value in values where !result.contains(where: { abs($0 - value) < 0.01 }) {
            result.append(value)
        }
        return result
    }

    private static func packingScore(
        bounds: CGRect,
        targetAspect: CGFloat
    ) -> CGFloat {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        // With a normalized canvas height of 1, this is the exact canvas
        // extent required for a uniform fit of the candidate bounds.
        let normalizedExtent = max(width / targetAspect, height)
        let canvasEnvelopeArea = max(
            targetAspect * normalizedExtent * normalizedExtent,
            1
        )
        let unusedFraction = max(
            0,
            1 - (width * height / canvasEnvelopeArea)
        )
        let normalizedCenterX = bounds.midX / max(targetAspect * normalizedExtent, 1)
        let normalizedCenterY = bounds.midY / max(normalizedExtent, 1)
        let centerPenalty = sqrt(
            normalizedCenterX * normalizedCenterX
                + normalizedCenterY * normalizedCenterY
        )
        return normalizedExtent
            * (1 + unusedFraction * 0.12 + centerPenalty * 0.004)
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
                    fontSize: CGFloat.random(in: 20...50)
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
