import Foundation

/// Pairwise (orthogonal) covering-array generator.
///
/// Given N dimensions with arities `[a1, a2, ..., aN]`, returns the smallest
/// set of N-tuples such that every PAIR of values from any two dimensions
/// appears together in at least one tuple.
///
/// Algorithm: greedy In-Parameter-Order (IPO). Not optimal (a true minimum
/// cover requires NP-hard search), but produces near-minimal arrays in
/// reasonable time and order. Output size grows as O(maxArity^2 * log N).
///
/// References:
///   - Tai & Lei, "A Test Generation Strategy for Pairwise Testing" (2002)
///   - Cohen, Dalal, Fredman, Patton, "The AETG System" (1997)
public enum PairwiseCovering {
    /// Generate covering tuples for the given dimension arities.
    /// Each output tuple has `arities.count` integers; tuple[i] is in
    /// `[0, arities[i])`. Caller is responsible for mapping these indices to
    /// actual values.
    ///
    /// - Returns: an array of tuples covering every pair-of-values across
    ///   any two dimensions. Empty when arities is empty. For N=1, returns
    ///   `[[0], [1], ..., [arities[0]-1]]`.
    public static func generate(arities: [Int]) -> [[Int]] {
        guard !arities.isEmpty else { return [] }
        guard arities.count >= 2 else {
            return (0..<arities[0]).map { [$0] }
        }
        // Step 1: seed with full cross-product over the first two dimensions
        var tuples: [[Int]] = []
        for a in 0..<arities[0] {
            for b in 0..<arities[1] {
                tuples.append([a, b])
            }
        }
        // Step 2: extend dimension by dimension
        for d in 2..<arities.count {
            tuples = extend(tuples: tuples, withDim: d, arity: arities[d], allArities: arities)
        }
        return tuples
    }

    private static func extend(tuples: [[Int]], withDim d: Int, arity: Int, allArities: [Int]) -> [[Int]] {
        // Compute every pair (prevDim, prevVal) x (d, dVal) that needs covering.
        var uncovered: Set<UncoveredKey> = []
        for prev in 0..<d {
            for prevVal in 0..<allArities[prev] {
                for thisVal in 0..<arity {
                    uncovered.insert(.init(dim1: prev, val1: prevVal, dim2: d, val2: thisVal))
                }
            }
        }

        var output = tuples
        // Phase A: extend each existing tuple greedily, picking the d-value
        // that covers the most still-uncovered pairs.
        for i in output.indices {
            if uncovered.isEmpty { break }
            var bestVal = 0
            var bestCovered = -1
            for v in 0..<arity {
                var covers = 0
                for prev in 0..<d {
                    let key = UncoveredKey(dim1: prev, val1: output[i][prev], dim2: d, val2: v)
                    if uncovered.contains(key) { covers += 1 }
                }
                if covers > bestCovered {
                    bestCovered = covers
                    bestVal = v
                }
            }
            output[i].append(bestVal)
            for prev in 0..<d {
                uncovered.remove(.init(dim1: prev, val1: output[i][prev], dim2: d, val2: bestVal))
            }
        }
        // Phase B: any remaining uncovered pairs require new tuples.
        while !uncovered.isEmpty {
            // Pick any uncovered pair as the seed for a new tuple
            guard let seed = uncovered.first else { break }
            var newTuple = Array(repeating: 0, count: d + 1)
            newTuple[seed.dim1] = seed.val1
            newTuple[d] = seed.val2
            // Greedily fill remaining positions to maximize pair coverage
            for pos in 0..<(d + 1) where pos != seed.dim1 && pos != d {
                var bestVal = 0
                var bestCovered = -1
                for v in 0..<allArities[pos] {
                    newTuple[pos] = v
                    var covers = 0
                    for other in 0..<(d + 1) where other != pos {
                        let lo = min(pos, other), hi = max(pos, other)
                        let loV = newTuple[lo], hiV = newTuple[hi]
                        if uncovered.contains(.init(dim1: lo, val1: loV, dim2: hi, val2: hiV)) {
                            covers += 1
                        }
                    }
                    if covers > bestCovered {
                        bestCovered = covers
                        bestVal = v
                    }
                }
                newTuple[pos] = bestVal
            }
            output.append(newTuple)
            // Mark all pairs in this new tuple as covered
            for i in 0..<(d + 1) {
                for j in (i + 1)..<(d + 1) {
                    uncovered.remove(.init(dim1: i, val1: newTuple[i], dim2: j, val2: newTuple[j]))
                }
            }
        }
        return output
    }

    private struct UncoveredKey: Hashable {
        let dim1: Int
        let val1: Int
        let dim2: Int
        let val2: Int
    }
}
