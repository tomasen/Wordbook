import Foundation

// Run from the repository root:
// swiftc -D WORD_CLOUD_LAYOUT_HARNESS Shared/WordCloudView.swift \
//   scripts/WordCloudLayoutHarness.swift -o /tmp/word-cloud-harness

@main
struct WordCloudLayoutHarness {
    private struct Scenario {
        let name: String
        let canvas: CGSize
    }

    private static let itemSizes: [CGSize] = (0..<50).map { index in
        let fontSize = CGFloat(20 + (index * 37) % 41)
        let characterCount = CGFloat(4 + (index * 7) % 9)
        return CGSize(
            width: characterCount * fontSize * 0.52 + 4,
            height: fontSize * 1.2 + 4
        )
    }

    private static let priorities: [CGFloat] = (0..<50).map { index in
        CGFloat(50 - index)
    }

    /// Mirrors the sparse seven-word case that exposed the poster-like layout:
    /// two NOIDEA, two VAGUE, then three GOOD answers.
    private static let sparseConfidenceSizes: [CGSize] = [
        measuredSize(characters: 6, fontSize: 50),
        measuredSize(characters: 7, fontSize: 50),
        measuredSize(characters: 9, fontSize: 36),
        measuredSize(characters: 7, fontSize: 36),
        measuredSize(characters: 6, fontSize: 22),
        measuredSize(characters: 5, fontSize: 22),
        measuredSize(characters: 6, fontSize: 22),
    ]
    private static let sparseConfidencePriorities: [CGFloat] = [
        2, 2, 1, 1, 0, 0, 0,
    ]

    static func main() {
        verifyDifficultyScale()

        let scenarios = [
            Scenario(name: "iPhone portrait", canvas: CGSize(width: 370, height: 430)),
            Scenario(name: "4:3 iPad/Mac", canvas: CGSize(width: 800, height: 600)),
            Scenario(name: "16:9", canvas: CGSize(width: 800, height: 450)),
            Scenario(name: "narrow split", canvas: CGSize(width: 300, height: 560)),
        ]

        for scenario in scenarios {
            for count in [1, 3, 7, 12, 16, 24, 50] {
                verify(scenario, itemSizes: Array(itemSizes.prefix(count)))
            }
            verify(
                scenario,
                itemSizes: sparseConfidenceSizes,
                itemPriorities: sparseConfidencePriorities,
                label: "sparse confidence sample"
            )
        }
        verifyScreenAspectDoesNotChangeTopology(scenarios)
        print("PASS: square, deterministic packing, no overlaps, and occupancy thresholds met")
    }

    private static func verifyDifficultyScale() {
        let singleAnswerSizes = [0, 1, 2].map {
            WordCloudDifficultyScale.fontSize(
                for: $0,
                maximumDifficultyScore: 2
            )
        }
        require(close(singleAnswerSizes[0], 22), "GOOD is smallest", "difficulty scale")
        require(close(singleAnswerSizes[1], 36), "VAGUE is medium", "difficulty scale")
        require(close(singleAnswerSizes[2], 50), "NOIDEA is largest", "difficulty scale")

        let allGoodSize = WordCloudDifficultyScale.fontSize(
            for: 0,
            maximumDifficultyScore: 0
        )
        let allVagueSize = WordCloudDifficultyScale.fontSize(
            for: 1,
            maximumDifficultyScore: 1
        )
        let allNoIdeaSize = WordCloudDifficultyScale.fontSize(
            for: 2,
            maximumDifficultyScore: 2
        )
        require(close(allGoodSize, 22), "equal GOOD scores stay small", "difficulty scale")
        require(close(allVagueSize, 36), "equal VAGUE scores stay medium", "difficulty scale")
        require(close(allNoIdeaSize, 50), "equal NOIDEA scores stay large", "difficulty scale")

        let repeatedDifficultySizes = [0, 1, 2, 4].map {
            WordCloudDifficultyScale.fontSize(
                for: $0,
                maximumDifficultyScore: 4
            )
        }
        require(
            zip(repeatedDifficultySizes, repeatedDifficultySizes.dropFirst())
                .allSatisfy(<),
            "repeated difficulty remains strictly ordered",
            "difficulty scale"
        )
        require(close(repeatedDifficultySizes.last!, 50), "maximum remains bounded", "difficulty scale")
        print("Difficulty scale: GOOD 22, VAGUE 36, NOIDEA 50 — PASS")
    }

    private static func verify(
        _ scenario: Scenario,
        itemSizes: [CGSize],
        itemPriorities: [CGFloat]? = nil,
        label: String? = nil
    ) {
        let caseName = "\(scenario.name), \(label ?? "\(itemSizes.count) words")"
        let spacing: CGFloat = 4
        let resolvedPriorities = itemPriorities
            ?? Array(priorities.prefix(itemSizes.count))
        let squareCanvas = WordCloudLayoutMetrics.squareCanvas(
            inside: scenario.canvas
        )
        let preferredAspect = WordCloudLayoutMetrics.packingAspectRatio
        let first = WordCloudPacker.pack(
            itemSizes: itemSizes,
            priorities: resolvedPriorities,
            canvasAspectRatio: preferredAspect,
            spacing: spacing
        )
        let second = WordCloudPacker.pack(
            itemSizes: itemSizes,
            priorities: resolvedPriorities,
            canvasAspectRatio: preferredAspect,
            spacing: spacing
        )

        require(first.positions.count == itemSizes.count, "position count", caseName)
        require(same(first, second), "deterministic result", caseName)

        let frames = zip(first.positions, itemSizes).map { position, size in
            CGRect(
                x: position.x - (size.width + spacing) / 2,
                y: position.y - (size.height + spacing) / 2,
                width: size.width + spacing,
                height: size.height + spacing
            )
        }
        for firstIndex in frames.indices {
            let frame = frames[firstIndex]
            require(
                frame.minX >= first.bounds.minX - 0.001
                    && frame.maxX <= first.bounds.maxX + 0.001
                    && frame.minY >= first.bounds.minY - 0.001
                    && frame.maxY <= first.bounds.maxY + 0.001,
                "bounds containment",
                caseName
            )
            for secondIndex in frames.indices where secondIndex > firstIndex {
                let intersection = frames[firstIndex].intersection(frames[secondIndex])
                require(
                    intersection.isNull
                        || intersection.width < 0.001
                        || intersection.height < 0.001,
                    "overlap at \(firstIndex),\(secondIndex)",
                    caseName
                )
            }
        }

        require(close(squareCanvas.width, squareCanvas.height), "square canvas", caseName)
        require(close(preferredAspect, 1), "square packing aspect", caseName)

        let renderScale = WordCloudLayoutMetrics.renderScale(
            packingBounds: first.bounds,
            canvasSize: squareCanvas,
            inset: 10,
            fillFraction: 0.92,
            maximumScale: WordCloudLayoutMetrics.maximumRenderScale(
                canvasSize: squareCanvas
            )
        )
        require(renderScale.isFinite && renderScale > 0, "finite render scale", caseName)
        require(
            first.bounds.width * renderScale <= squareCanvas.width - 20 + 0.001,
            "scaled width containment",
            caseName
        )
        require(
            first.bounds.height * renderScale <= squareCanvas.height - 20 + 0.001,
            "scaled height containment",
            caseName
        )

        let normalizedExtent = max(
            first.bounds.width / preferredAspect,
            first.bounds.height
        )
        let normalizedCanvasArea = preferredAspect * normalizedExtent * normalizedExtent
        let envelopeOccupancy = first.bounds.width * first.bounds.height
            / normalizedCanvasArea
        let wordArea = itemSizes.reduce(CGFloat.zero) { total, size in
            total + size.width * size.height
        }
        let packingDensity = wordArea / (first.bounds.width * first.bounds.height)

        if itemSizes.count >= 7 {
            require(envelopeOccupancy >= 0.42, "envelope occupancy", caseName)
            require(packingDensity >= 0.16, "packing density", caseName)
            let primaryPosition = first.positions[0]
            let primaryDistance = hypot(
                primaryPosition.x / max(first.bounds.width, 1),
                primaryPosition.y / max(first.bounds.height, 1)
            )
            require(
                primaryDistance <= 0.28,
                "highest-priority word stays central",
                caseName
            )
            print(
                String(
                    format: "%@: bounds %.1fx%.1f, envelope %.3f, density %.3f",
                    caseName,
                    first.bounds.width,
                    first.bounds.height,
                    envelopeOccupancy,
                    packingDensity
                )
            )
        }
    }

    private static func verifyScreenAspectDoesNotChangeTopology(
        _ scenarios: [Scenario]
    ) {
        let sizes = sparseConfidenceSizes
        let reference = WordCloudPacker.pack(
            itemSizes: sizes,
            priorities: sparseConfidencePriorities,
            canvasAspectRatio: WordCloudLayoutMetrics.packingAspectRatio,
            spacing: 4
        )

        for scenario in scenarios {
            let squareCanvas = WordCloudLayoutMetrics.squareCanvas(
                inside: scenario.canvas
            )
            require(
                close(squareCanvas.width, squareCanvas.height),
                "square canvas",
                scenario.name
            )
            let packing = WordCloudPacker.pack(
                itemSizes: sizes,
                priorities: sparseConfidencePriorities,
                canvasAspectRatio: WordCloudLayoutMetrics.packingAspectRatio,
                spacing: 4
            )
            require(
                same(reference, packing),
                "screen aspect does not alter topology",
                scenario.name
            )
        }
    }

    private static func same(
        _ lhs: WordCloudPacking,
        _ rhs: WordCloudPacking
    ) -> Bool {
        guard lhs.positions.count == rhs.positions.count else { return false }
        let positionsMatch = zip(lhs.positions, rhs.positions).allSatisfy { first, second in
            abs(first.x - second.x) < 0.000_001
                && abs(first.y - second.y) < 0.000_001
        }
        return positionsMatch
            && abs(lhs.bounds.width - rhs.bounds.width) < 0.000_001
            && abs(lhs.bounds.height - rhs.bounds.height) < 0.000_001
    }

    private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    private static func measuredSize(
        characters: CGFloat,
        fontSize: CGFloat
    ) -> CGSize {
        CGSize(
            width: characters * fontSize * 0.52 + 4,
            height: fontSize * 1.2 + 4
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ check: String,
        _ caseName: String
    ) {
        guard condition() else {
            fatalError("FAIL [\(caseName)]: \(check)")
        }
    }
}
