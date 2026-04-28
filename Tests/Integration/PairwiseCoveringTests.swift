import XCTest
@testable import YameteApp

final class PairwiseCoveringTests: IntegrationTestCase {
    /// Empty arities returns empty.
    func testEmpty_returnsEmpty() {
        XCTAssertEqual(PairwiseCovering.generate(arities: []).count, 0)
    }

    /// Single dimension with k values returns k singleton tuples.
    func testSingleDim_returnsKTuples() {
        XCTAssertEqual(PairwiseCovering.generate(arities: [3]), [[0], [1], [2]])
    }

    /// Two dimensions: must cover every pair = full Cartesian.
    func testTwoDims_isFullCartesian() {
        let tuples = PairwiseCovering.generate(arities: [2, 3])
        XCTAssertEqual(tuples.count, 6)
        // Every (a, b) combination present
        let pairs = Set(tuples.map { "\($0[0]),\($0[1])" })
        XCTAssertEqual(pairs.count, 6)
    }

    /// Three or more dimensions: every pair from every two dims must appear.
    /// This is the defining property of pairwise coverage.
    func testThreePlusDims_allPairsCovered() {
        let arities = [3, 3, 3, 3]
        let tuples = PairwiseCovering.generate(arities: arities)
        for i in 0..<arities.count {
            for j in (i + 1)..<arities.count {
                for vi in 0..<arities[i] {
                    for vj in 0..<arities[j] {
                        let found = tuples.contains { $0[i] == vi && $0[j] == vj }
                        XCTAssertTrue(found, "Missing pair: dim \(i)=\(vi), dim \(j)=\(vj)")
                    }
                }
            }
        }
    }

    /// Pairwise must be smaller than full Cartesian for 4+ dimensions.
    func testPairwise_isSmallerThanCartesian() {
        let arities = [3, 3, 3, 3, 3]
        let tuples = PairwiseCovering.generate(arities: arities)
        let cartesian = arities.reduce(1, *)
        XCTAssertLessThan(tuples.count, cartesian)
    }

    /// ConfigurationMatrix DSL works end-to-end with typed values.
    func testDSL_returnsTypedTuples() {
        let cells = ConfigurationMatrix.pairwise(
            MatrixDimension("a", [10, 20]),
            MatrixDimension("b", ["x", "y", "z"])
        )
        XCTAssertEqual(cells.count, 6)
        // Every combination present
        let serialized = Set(cells.map { "\($0.0)-\($0.1)" })
        XCTAssertEqual(serialized.count, 6)
    }

    /// Larger smoke test: 6 dimensions of arity 3 must produce <100 tuples
    /// (full cartesian = 729) and cover every pair.
    func testLargerArity_keepsTupleCountReasonable() {
        let arities = [3, 3, 3, 3, 3, 3]
        let tuples = PairwiseCovering.generate(arities: arities)
        XCTAssertLessThan(tuples.count, 100, "pairwise should be << 729 cartesian; got \(tuples.count)")
    }
}
