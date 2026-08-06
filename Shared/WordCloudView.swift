//
//  WordCloudView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/20/21.
//

import SwiftUI

struct WordElement {
    let text: String
    let color: Color
    let fontName: String
    let fontSize: CGFloat
}

struct WordCloudView: View {
    private let words: [WordElement]

    @State private var positionCache = WordCloudPositionCache()
    @State private var canvasRect = CGRect()
    @State private var wordSizes: [CGSize]
    @State private var fontSizeRatio: CGFloat = 1

    init() {
        words = [WordElement].generate()
        self._wordSizes = State(
            initialValue: [CGSize](repeating: CGSize.zero, count: words.count)
        )
    }

    init(_ words: [WordElement]) {
        self.words = words
        self._wordSizes = State(
            initialValue: [CGSize](repeating: CGSize.zero, count: words.count)
        )
    }

    var body: some View {
        let positions = calcPositions(canvasSize: canvasRect.size, itemSizes: wordSizes)
        let layoutIsReady = words.isEmpty
            || positionCache.matches(
                words: words,
                canvasSize: canvasRect.size,
                wordSizes: wordSizes,
                fontSizeRatio: fontSizeRatio
            )

        return ZStack {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                NavigationLink(destination: CardView(word.text, true, true)) {
                    Text(word.text)
                        .foregroundColor(word.color)
                        .font(
                            Font.custom(
                                word.fontName,
                                size: word.fontSize * fontSizeRatio
                            )
                        )
                        .lineLimit(1)
                        .fixedSize()
                        .padding(2)
                        .background(WordSizeGetter($wordSizes, index))
                }
                .position(
                    x: canvasRect.width / 2 + positions[index].x,
                    y: canvasRect.height / 2 + positions[index].y
                )
            }
        }
        .opacity(layoutIsReady ? 1 : 0)
        .background(RectGetter($canvasRect))
        .onChange(of: words.count) {
            if wordSizes.count != words.count {
                wordSizes = [CGSize](repeating: .zero, count: words.count)
                fontSizeRatio = 1
                positionCache.invalidate()
            }
        }
    }

    func calcPositions(canvasSize: CGSize, itemSizes: [CGSize]) -> [CGPoint] {
        let emptyPositions = [CGPoint](repeating: .zero, count: words.count)
        guard canvasSize.width > 0,
            canvasSize.height > 0,
            !words.isEmpty,
            itemSizes.count == words.count,
            itemSizes.allSatisfy({ $0.width > 0 && $0.height > 0 })
        else {
            return emptyPositions
        }

        if positionCache.matches(
            words: words,
            canvasSize: canvasSize,
            wordSizes: itemSizes,
            fontSizeRatio: fontSizeRatio
        ) {
            return positionCache.positions
        }

        let packing = WordCloudPacker.pack(
            itemSizes: itemSizes,
            canvasAspectRatio: canvasSize.width / canvasSize.height,
            spacing: 4
        )

        // Fit the packed cluster to about 92% of the available square. Unlike
        // the old layout, this can enlarge a small cloud as well as shrink a
        // crowded one. Fitting all words inside the canvas takes precedence;
        // the upper cap keeps a small cloud from becoming poster-sized.
        let canvasInset: CGFloat = 10
        let usableWidth = max(canvasSize.width - canvasInset * 2, 1)
        let usableHeight = max(canvasSize.height - canvasInset * 2, 1)
        let widthScale = usableWidth / max(packing.bounds.width, 1)
        let heightScale = usableHeight / max(packing.bounds.height, 1)
        let fitMultiplier = min(widthScale, heightScale) * 0.92
        let desiredRatio = min(fontSizeRatio * fitMultiplier, 1.35)
        let roundedRatio = (desiredRatio * 100).rounded() / 100

        if abs(roundedRatio - fontSizeRatio) > 0.015 {
            let expectedRatio = fontSizeRatio
            let scaleRevision = positionCache.beginScaleUpdate()
            DispatchQueue.main.async {
                guard positionCache.isCurrentScaleUpdate(scaleRevision),
                    abs(fontSizeRatio - expectedRatio) < 0.005
                else {
                    return
                }
                guard abs(roundedRatio - fontSizeRatio) > 0.015 else { return }
                fontSizeRatio = roundedRatio
                wordSizes = [CGSize](repeating: .zero, count: words.count)
                positionCache.invalidate()
            }
            return packing.positions
        }

        positionCache.store(
            words: words,
            canvasSize: canvasSize,
            wordSizes: itemSizes,
            positions: packing.positions,
            fontSizeRatio: fontSizeRatio
        )
        return packing.positions
    }
}

private final class WordCloudPositionCache {
    var words = [WordElement]()
    var canvasSize = CGSize.zero
    var wordSizes = [CGSize]()
    var positions = [CGPoint]()
    var fontSizeRatio: CGFloat = 1
    private var scaleRevision = 0

    func matches(
        words: [WordElement],
        canvasSize: CGSize,
        wordSizes: [CGSize],
        fontSizeRatio: CGFloat
    ) -> Bool {
        positions.count == words.count
            && elementsMatch(words, self.words)
            && sizesMatch([canvasSize], [self.canvasSize], tolerance: 0.25)
            && sizesMatch(wordSizes, self.wordSizes, tolerance: 0.25)
            && abs(fontSizeRatio - self.fontSizeRatio) < 0.005
    }

    func store(
        words: [WordElement],
        canvasSize: CGSize,
        wordSizes: [CGSize],
        positions: [CGPoint],
        fontSizeRatio: CGFloat
    ) {
        cancelScaleUpdate()
        self.words = words
        self.canvasSize = canvasSize
        self.wordSizes = wordSizes
        self.positions = positions
        self.fontSizeRatio = fontSizeRatio
    }

    func invalidate() {
        cancelScaleUpdate()
        words = []
        canvasSize = .zero
        wordSizes = []
        positions = []
        fontSizeRatio = 1
    }

    func beginScaleUpdate() -> Int {
        scaleRevision &+= 1
        return scaleRevision
    }

    func isCurrentScaleUpdate(_ revision: Int) -> Bool {
        scaleRevision == revision
    }

    private func cancelScaleUpdate() {
        scaleRevision &+= 1
    }

    private func elementsMatch(_ lhs: [WordElement], _ rhs: [WordElement]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { first, second in
            first.text == second.text
                && first.fontName == second.fontName
                && abs(first.fontSize - second.fontSize) < 0.005
        }
    }

    private func sizesMatch(
        _ lhs: [CGSize],
        _ rhs: [CGSize],
        tolerance: CGFloat
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { first, second in
            abs(first.width - second.width) < tolerance
                && abs(first.height - second.height) < tolerance
        }
    }
}

private struct WordCloudPacking {
    let positions: [CGPoint]
    let bounds: CGRect
}

/// Deterministic edge-contact packing. Large words establish the center and
/// smaller words fill the remaining gaps. Candidate scoring keeps the cluster
/// compact while preferring the canvas aspect ratio.
private enum WordCloudPacker {
    static func pack(
        itemSizes: [CGSize],
        canvasAspectRatio: CGFloat,
        spacing: CGFloat
    ) -> WordCloudPacking {
        guard !itemSizes.isEmpty else {
            return WordCloudPacking(positions: [], bounds: .zero)
        }

        let placementOrder = itemSizes.indices.sorted { first, second in
            let firstArea = itemSizes[first].width * itemSizes[first].height
            let secondArea = itemSizes[second].width * itemSizes[second].height
            if abs(firstArea - secondArea) > 0.01 {
                return firstArea > secondArea
            }
            if abs(itemSizes[first].width - itemSizes[second].width) > 0.01 {
                return itemSizes[first].width > itemSizes[second].width
            }
            return first < second
        }

        var positions = [CGPoint](repeating: .zero, count: itemSizes.count)
        var placedFrames: [CGRect] = []
        var clusterBounds = CGRect.null
        let targetAspect = min(max(canvasAspectRatio, 0.6), 1.8)

        for index in placementOrder {
            let itemSize = itemSizes[index]
            let paddedSize = CGSize(
                width: itemSize.width + spacing,
                height: itemSize.height + spacing
            )

            let center: CGPoint
            if placedFrames.isEmpty {
                center = .zero
            } else {
                center = bestCenter(
                    for: paddedSize,
                    placedFrames: placedFrames,
                    clusterBounds: clusterBounds,
                    targetAspect: targetAspect
                )
            }

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
        let centeredPositions = positions.map {
            CGPoint(x: $0.x - packedCenter.x, y: $0.y - packedCenter.y)
        }
        let centeredBounds = clusterBounds.offsetBy(
            dx: -packedCenter.x,
            dy: -packedCenter.y
        )
        return WordCloudPacking(positions: centeredPositions, bounds: centeredBounds)
    }

    private static func bestCenter(
        for size: CGSize,
        placedFrames: [CGRect],
        clusterBounds: CGRect,
        targetAspect: CGFloat
    ) -> CGPoint {
        var candidates: [CGPoint] = []
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2

        for anchor in placedFrames {
            let left = anchor.minX - halfWidth
            let right = anchor.maxX + halfWidth
            let top = anchor.minY - halfHeight
            let bottom = anchor.maxY + halfHeight
            let alignedY = [
                CGFloat.zero,
                anchor.minY + halfHeight,
                anchor.midY,
                anchor.maxY - halfHeight,
            ]
            let alignedX = [
                CGFloat.zero,
                anchor.minX + halfWidth,
                anchor.midX,
                anchor.maxX - halfWidth,
            ]

            for y in alignedY {
                candidates.append(CGPoint(x: left, y: y))
                candidates.append(CGPoint(x: right, y: y))
            }
            for x in alignedX {
                candidates.append(CGPoint(x: x, y: top))
                candidates.append(CGPoint(x: x, y: bottom))
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

            let candidateBounds = clusterBounds.union(frame)
            let score = packingScore(
                bounds: candidateBounds,
                targetAspect: targetAspect
            )
            if score < bestScore {
                bestScore = score
                bestPoint = candidate
            }
        }

        if let bestPoint {
            return bestPoint
        }

        // Edge candidates always have an open exterior in normal input. Keep
        // a deterministic spiral fallback for unusually interlocked shapes.
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

        // This is practically unreachable, but remains deterministic and
        // avoids collapsing every word onto the origin.
        return CGPoint(
            x: clusterBounds.maxX + halfWidth + 1,
            y: clusterBounds.midY
        )
    }

    private static func packingScore(
        bounds: CGRect,
        targetAspect: CGFloat
    ) -> CGFloat {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let area = width * height
        let aspectPenalty = abs(width / height - targetAspect) / targetAspect
        let centerX = bounds.midX / width
        let centerY = bounds.midY / height
        let centerPenalty = sqrt(centerX * centerX + centerY * centerY)
        return area * (1 + aspectPenalty * 0.75 + centerPenalty * 0.04)
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(
            x: origin.x + size.width / 2,
            y: origin.y + size.height / 2
        )
    }
}

struct WordSizeGetter: View {
    @Binding var sizeStorage: [CGSize]
    private var index: Int
    
    init(_ sizeStorage: Binding<[CGSize]>, _ index: Int) {
        _sizeStorage = sizeStorage
        self.index = index
    }
    
    var body: some View {
        GeometryReader { proxy in
            self.createView(proxy: proxy)
        }
    }
    
    func createView(proxy: GeometryProxy) -> some View {
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
    static let colorPlate =  ["shareFont1", "shareFont2", "shareFont3",
                              "shareFont1", "shareFont5"]
    static let fontPlate = [ "SFProText-Bold",
                             "SFProText-Medium", "SFProText-Regular", "SFProText-Semibold"]
    
    static func generate(_ cap: Int = Int.random(in: 1...50)) -> [WordElement] {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        var words = [WordElement]()
        for _ in 0...cap {
            words.append(
                WordElement(text: String((0...Int.random(in: 4...9)).map{ _ in letters.randomElement()! }),
                            color: Color(colorPlate.randomElement()!),
                            fontName: fontPlate.randomElement()!,
                            fontSize: CGFloat.random(in:20...50))
            )
        }
        return words
    }
}

struct WordCloudView_Previews: PreviewProvider {
    static var previews: some View {
        VStack{
            Spacer()
            WordCloudView()
            Spacer().padding()
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }
}
