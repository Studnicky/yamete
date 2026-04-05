import XCTest
@testable import YameteLib

final class BundleResourcesTests: XCTestCase {

    func testUrlsReturnsEmptyForNonexistentFolder() {
        let urls = BundleResources.urls(in: "nonexistent_folder_xyz", extensions: ["mp3"])
        XCTAssertTrue(urls.isEmpty, "Should return empty for folder that doesn't exist")
    }

    func testUrlsFiltersByExtension() {
        let mp3s = BundleResources.urls(in: "sounds", extensions: ["mp3"])
        let wavs = BundleResources.urls(in: "sounds", extensions: ["wav"])
        let combined = BundleResources.urls(in: "sounds", extensions: ["mp3", "wav"])

        XCTAssertEqual(combined.count, mp3s.count + wavs.count)
    }

    func testUrlsReturnsSortedResults() {
        let urls = BundleResources.urls(in: "sounds", extensions: ["mp3"])
        let names = urls.map { $0.lastPathComponent }
        XCTAssertEqual(names, names.sorted(), "URLs should be sorted by filename")
    }

    func testUrlsIgnoresNonMatchingExtensions() {
        let urls = BundleResources.urls(in: "sounds", extensions: ["xyz_nonexistent"])
        XCTAssertTrue(urls.isEmpty, "Should return empty when no files match the extension")
    }
}

final class GenericClampTests: XCTestCase {

    func testIntClamp() {
        // Verifies the generic Comparable.clamped(to:) works for Int too
        XCTAssertEqual((-5).clamped(to: 0...10), 0)
        XCTAssertEqual(15.clamped(to: 0...10), 10)
        XCTAssertEqual(5.clamped(to: 0...10), 5)
    }
}
