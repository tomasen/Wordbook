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

    static func main() {
        let scenarios = [
            Scenario(name: "iPhone portrait", canvas: CGSize(width: 370, height: 430)),
            Scenario(name: "4:3 iPad/Mac", canvas: CGSize(width: 800, height: 600)),
            Scenario(name: "16:9", canvas: CGSize(width: 800, height: 450)),
            Scenario(name: "narrow split", canvas: CGSize(width: 300, height: 560)),
        ]

        for scenario in scenarios {
            for count in [1, 5, 12, 16, 24, 50] {
                verify(scenario, itemSizes: Array(itemSizes.prefix(count)))
            }
        }
        print("PASS: deterministic packing, no overlaps, and occupancy thresholds met")
    }

    private static func verify(_ scenario: Scenario, itemSizes: [CGSize]) {
        let caseName = "\(scenario.name), \(itemSizes.count) words"
        let spacing: CGFloat = 4
        let aspect = scenario.canvas.width / scenario.canvas.height
        let first = WordCloudPacker.pack(
            itemSizes: itemSizes,
            canvasAspectRatio: aspect,
            spacing: spacing
        )
        let second = WordCloudPacker.pack(
            itemSizes: itemSizes,
            canvasAspectRatio: aspect,
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

        let renderScale = WordCloudLayoutMetrics.renderScale(
            packingBounds: first.bounds,
            canvasSize: scenario.canvas,
            inset: 10,
            fillFraction: 0.96,
            maximumScale: 1.55
        )
        require(renderScale.isFinite && renderScale > 0, "finite render scale", caseName)
        require(
            first.bounds.width * renderScale <= scenario.canvas.width - 20 + 0.001,
            "scaled width containment",
            caseName
        )
        require(
            first.bounds.height * renderScale <= scenario.canvas.height - 20 + 0.001,
            "scaled height containment",
            caseName
        )

        let normalizedExtent = max(first.bounds.width / aspect, first.bounds.height)
        let normalizedCanvasArea = aspect * normalizedExtent * normalizedExtent
        let envelopeOccupancy = first.bounds.width * first.bounds.height
            / normalizedCanvasArea
        let wordArea = itemSizes.reduce(CGFloat.zero) { total, size in
            total + size.width * size.height
        }
        let packingDensity = wordArea / (first.bounds.width * first.bounds.height)

        if itemSizes.count >= 12 {
            require(envelopeOccupancy >= 0.58, "envelope occupancy", caseName)
            require(packingDensity >= 0.25, "packing density", caseName)
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
