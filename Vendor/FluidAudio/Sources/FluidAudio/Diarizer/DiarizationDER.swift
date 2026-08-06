//
//  DiarizationDER.swift
//  LS-EEND-Test
//
//  Frame-wise Diarization Error Rate with optimal (Hungarian) speaker
//  mapping. Matches the NIST md-eval / pyannote DER definition:
//
//      DER = (miss + false_alarm + confusion) / total_ref_speech
//
//  where per 10 ms frame t with Nref speakers in the reference and Nsys
//  speakers in the hypothesis:
//      miss       = max(0, Nref − Nsys)
//      false_alarm= max(0, Nsys − Nref)
//      confusion  = min(Nref, Nsys) − Ncorrect_t
//  and Ncorrect_t counts hyp speakers whose globally-mapped label is also
//  active in the reference at t. The global mapping is the one-to-one
//  hyp→ref assignment that maximises total overlap time (Hungarian).
//
//  Collar support: `collar` is the full width around each reference
//  speaker-change boundary that is excluded from scoring. A frame whose
//  midpoint lies within ±collar/2 of any boundary in the reference is
//  dropped from every accumulator (matches pyannote.metrics).

import Foundation

public struct DERSpeakerSegment: Sendable, Hashable {
    public let speaker: String
    public let start: Double
    public let end: Double
    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public struct DERResult: Sendable {
    public let der: Double
    public let confusion: Double
    public let falseAlarm: Double
    public let miss: Double
    public let totalRefSpeech: Double
    /// Flat `hypLabel → refLabel` mapping found by Hungarian. Hyp labels
    /// that drew no ref partner are omitted.
    public let mapping: [String: String]
}

public enum DiarizationDER {

    /// Compute frame-wise DER. `frameStep` is the analysis grid; segments
    /// are discretised by midpoint test.
    public static func compute(
        ref: [DERSpeakerSegment],
        hyp: [DERSpeakerSegment],
        frameStep: Double = 0.01,
        collar: Double = 0
    ) -> DERResult {
        precondition(frameStep > 0)
        precondition(collar >= 0)

        // Discover label sets + total duration.
        var refLabels: [String] = []
        var hypLabels: [String] = []
        var refIdx: [String: Int] = [:]
        var hypIdx: [String: Int] = [:]
        var maxEnd: Double = 0
        for s in ref {
            if refIdx[s.speaker] == nil {
                refIdx[s.speaker] = refLabels.count
                refLabels.append(s.speaker)
            }
            maxEnd = max(maxEnd, s.end)
        }
        for s in hyp {
            if hypIdx[s.speaker] == nil {
                hypIdx[s.speaker] = hypLabels.count
                hypLabels.append(s.speaker)
            }
            maxEnd = max(maxEnd, s.end)
        }
        let numFrames = Int(ceil(maxEnd / frameStep)) + 1
        if numFrames <= 0 || (refLabels.isEmpty && hypLabels.isEmpty) {
            return DERResult(
                der: 0, confusion: 0, falseAlarm: 0,
                miss: 0, totalRefSpeech: 0, mapping: [:])
        }

        // Rasterise each label to a BitSet per frame.
        let refMask = rasterise(
            ref, labelIdx: refIdx, numLabels: refLabels.count,
            numFrames: numFrames, frameStep: frameStep)
        let hypMask = rasterise(
            hyp, labelIdx: hypIdx, numLabels: hypLabels.count,
            numFrames: numFrames, frameStep: frameStep)

        // Overlap matrix O[h][r] = #frames both active.
        let H = hypLabels.count
        let R = refLabels.count
        var overlap = [Int](repeating: 0, count: H * R)
        if H > 0 && R > 0 {
            for t in 0..<numFrames {
                let hRow = t * H
                let rRow = t * R
                for h in 0..<H where hypMask[hRow + h] {
                    for r in 0..<R where refMask[rRow + r] {
                        overlap[h * R + r] &+= 1
                    }
                }
            }
        }

        // Hungarian on square padded cost matrix. Maximise overlap ⇒
        // minimise (maxOverlap − overlap).
        let n = max(H, R)
        var mapping = [Int](repeating: -1, count: H)  // hypIndex → refIndex
        if n > 0 {
            let maxO = overlap.max() ?? 0
            var cost = [Int](repeating: maxO, count: n * n)
            for h in 0..<H {
                for r in 0..<R {
                    cost[h * n + r] = maxO - overlap[h * R + r]
                }
            }
            let assign = Hungarian.solve(costSquare: cost, n: n)
            for h in 0..<H {
                let r = assign[h]
                if r < R && overlap[h * R + r] > 0 {
                    mapping[h] = r
                }
            }
        }

        // Build collar mask — frame is scorable iff its midpoint is not
        // within collar/2 of any reference speaker-change boundary.
        let scorable = collarMask(
            ref: ref, numFrames: numFrames, frameStep: frameStep, collar: collar)

        // Frame-wise error accumulation under the global mapping.
        var sumMiss = 0
        var sumFA = 0
        var sumConf = 0
        var sumRef = 0
        for t in 0..<numFrames where scorable[t] {
            let hRow = t * H
            let rRow = t * R
            var nRef = 0
            for r in 0..<R where refMask[rRow + r] { nRef += 1 }
            var nSys = 0
            for h in 0..<H where hypMask[hRow + h] { nSys += 1 }
            var nCorrect = 0
            for h in 0..<H where hypMask[hRow + h] {
                let rm = mapping[h]
                if rm >= 0 && refMask[rRow + rm] { nCorrect += 1 }
            }
            sumMiss += max(0, nRef - nSys)
            sumFA += max(0, nSys - nRef)
            sumConf += min(nRef, nSys) - nCorrect
            sumRef += nRef
        }
        let missS = Double(sumMiss) * frameStep
        let faS = Double(sumFA) * frameStep
        let confS = Double(sumConf) * frameStep
        let refS = Double(sumRef) * frameStep
        let der = refS > 0 ? (missS + faS + confS) / refS : 0

        var mapOut: [String: String] = [:]
        for h in 0..<H {
            let r = mapping[h]
            if r >= 0 { mapOut[hypLabels[h]] = refLabels[r] }
        }
        return DERResult(
            der: der, confusion: confS, falseAlarm: faS, miss: missS,
            totalRefSpeech: refS, mapping: mapOut
        )
    }

    /// Scorability mask: `scorable[t] == false` ⇒ frame is inside a
    /// collar around some reference boundary and must be excluded from
    /// every accumulator (incl. the `totalRefSpeech` denominator).
    /// `collar == 0` returns an all-true mask.
    private static func collarMask(
        ref: [DERSpeakerSegment],
        numFrames: Int,
        frameStep: Double,
        collar: Double
    ) -> [Bool] {
        var mask = [Bool](repeating: true, count: numFrames)
        if collar <= 0 { return mask }
        let half = collar / 2.0
        // Every segment endpoint is a boundary; start + end contribute.
        var boundaries: [Double] = []
        boundaries.reserveCapacity(ref.count * 2)
        for s in ref where s.end > s.start {
            boundaries.append(s.start)
            boundaries.append(s.end)
        }
        for b in boundaries {
            let lo = max(0, Int(floor((b - half) / frameStep)))
            let hi = min(numFrames, Int(ceil((b + half) / frameStep)))
            if hi <= lo { continue }
            for t in lo..<hi { mask[t] = false }
        }
        return mask
    }

    /// Bitset layout: `[t * numLabels + label] → Bool`. A frame is marked
    /// active for label `l` if some segment covering label `l` overlaps
    /// the frame midpoint `(t + 0.5) * frameStep`.
    private static func rasterise(
        _ segs: [DERSpeakerSegment],
        labelIdx: [String: Int],
        numLabels: Int,
        numFrames: Int,
        frameStep: Double
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: numFrames * numLabels)
        if numLabels == 0 { return mask }
        for seg in segs {
            guard let li = labelIdx[seg.speaker], seg.end > seg.start else { continue }
            // midpoint-test range: smallest t with (t+0.5)*step >= start,
            // largest with (t+0.5)*step < end.
            let tStart = max(0, Int(ceil(seg.start / frameStep - 0.5)))
            let tEndEx = min(numFrames, Int(ceil(seg.end / frameStep - 0.5)))
            if tEndEx <= tStart { continue }
            for t in tStart..<tEndEx {
                mask[t * numLabels + li] = true
            }
        }
        return mask
    }
}

// MARK: - Hungarian (O(n^3) min-cost assignment on a square cost matrix)

fileprivate enum Hungarian {
    /// Kuhn-Munkres with potentials. `cost` is row-major `n × n`,
    /// non-negative integers. Returns `assign[row] = col`.
    static func solve(costSquare cost: [Int], n: Int) -> [Int] {
        if n == 0 { return [] }
        // Classic Jonker-Volgenant style implementation adapted for
        // square n×n. 1-based indexing in arrays of size n+1 for the
        // canonical algorithm — cost is read as `cost[(i-1)*n + (j-1)]`.
        let INF = Int.max / 4
        var u = [Int](repeating: 0, count: n + 1)
        var v = [Int](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)
        var way = [Int](repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Int](repeating: INF, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = INF
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[(i0 - 1) * n + (j - 1)] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var assign = [Int](repeating: -1, count: n)
        for j in 1...n {
            if p[j] != 0 { assign[p[j] - 1] = j - 1 }
        }
        return assign
    }
}
