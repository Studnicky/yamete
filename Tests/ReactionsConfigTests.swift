import XCTest
@testable import YameteCore

final class ReactionsConfigTests: XCTestCase {
    func testEventIntensityExhaustive() {
        for kind in ReactionKind.allCases where kind != .impact {
            XCTAssertNotNil(ReactionsConfig.eventIntensity[kind],
                "ReactionsConfig.eventIntensity missing entry for .\(kind)")
        }
    }

    func testDefaultsWithinValidRanges() {
        XCTAssertTrue(Detection.unitRange.contains(Defaults.sensitivityMin))
        XCTAssertTrue(Detection.unitRange.contains(Defaults.sensitivityMax))
        XCTAssertTrue(Defaults.sensitivityMin < Defaults.sensitivityMax)
    }
}
