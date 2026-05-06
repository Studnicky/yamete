import XCTest
@testable import ResponseKit

/// Behavioural cells for `EDIDExtractor.parseEDID`. The IORegistry
/// walking path is impossible to test in isolation (it depends on the
/// host's actual hardware tree); the byte-parsing path is pure and
/// gets full coverage here. These cells pin the EDID 1.x identifier
/// layout: bytes 8–9 are vendor (big-endian 15-bit packed), bytes
/// 10–11 are product (little-endian), bytes 12–15 are serial
/// (little-endian).
final class EDIDExtractor_Tests: XCTestCase {

    /// Well-formed 16-byte input with all three identifier fields
    /// populated. Vendor=0x06 0x10 → 0x0610 (Apple's 'APP' EDID code),
    /// product=0xCD 0xAB → 0xABCD little-endian, serial=0x78 0x56 0x34
    /// 0x12 → 0x12345678 little-endian.
    func testParseEDID_wellFormed_extractsAllThreeIdentifiers() {
        let bytes: [UInt8] = [
            0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,  // EDID magic header (unused by parser; padding)
            0x06, 0x10,                                       // vendor (big-endian)
            0xCD, 0xAB,                                       // product (little-endian)
            0x78, 0x56, 0x34, 0x12                            // serial (little-endian)
        ]
        let edid = EDIDExtractor.parseEDID(Data(bytes))
        XCTAssertNotNil(edid,
            "[edid=well-formed] 16-byte input must parse")
        XCTAssertEqual(edid?.vendorID, 0x0610,
            "[edid=vendor-bigendian] vendor must read bytes 8-9 in big-endian (got \(String(describing: edid?.vendorID)))")
        XCTAssertEqual(edid?.productID, 0xABCD,
            "[edid=product-littleendian] product must read bytes 10-11 in little-endian (got \(String(describing: edid?.productID)))")
        XCTAssertEqual(edid?.serialNumber, 0x12345678,
            "[edid=serial-littleendian] serial must read bytes 12-15 in little-endian (got \(String(describing: edid?.serialNumber)))")
    }

    /// Many cheap monitors leave the EDID serial bytes as zero — the
    /// optional descriptor isn't programmed. The parser must still
    /// succeed and return serial=0 rather than refuse the input.
    func testParseEDID_zeroSerial_stillParses() {
        let bytes: [UInt8] = [
            0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
            0x12, 0x34,                                       // arbitrary vendor
            0x56, 0x78,                                       // arbitrary product
            0x00, 0x00, 0x00, 0x00                            // serial = 0 (zero descriptor)
        ]
        let edid = EDIDExtractor.parseEDID(Data(bytes))
        XCTAssertNotNil(edid,
            "[edid=zero-serial] zero-serial input must still parse")
        XCTAssertEqual(edid?.vendorID, 0x1234,
            "[edid=zero-serial-vendor] vendor unaffected by zero serial")
        XCTAssertEqual(edid?.productID, 0x7856,
            "[edid=zero-serial-product] product unaffected by zero serial")
        XCTAssertEqual(edid?.serialNumber, 0,
            "[edid=zero-serial-zero] serial must equal zero when descriptor is unprogrammed")
    }

    /// Inputs shorter than 16 bytes must return nil — IORegistry
    /// occasionally returns truncated EDID blobs on misconfigured
    /// adapter chains, and we do NOT want to read past the end of
    /// the buffer.
    func testParseEDID_truncated_returnsNil() {
        let shortBytes: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x12, 0x34]  // only 10 bytes
        XCTAssertNil(EDIDExtractor.parseEDID(Data(shortBytes)),
            "[edid=truncated] truncated input must return nil instead of reading past the buffer")
    }

    /// Empty input must return nil rather than synthesise zero-fill
    /// identifiers that could erroneously match a display whose
    /// CGDisplay numbers happen to all be zero.
    func testParseEDID_empty_returnsNil() {
        XCTAssertNil(EDIDExtractor.parseEDID(Data()),
            "[edid=empty] empty input must return nil")
    }

    /// A 128-byte block (full-length EDID 1.x) must work just like
    /// a 16-byte slice — the parser only inspects bytes 0–15 so
    /// trailing data is irrelevant.
    func testParseEDID_fullLengthBlock_parsesIdentifiersFromHeaderOnly() {
        var bytes: [UInt8] = [
            0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
            0xAB, 0xCD,                                       // vendor
            0xEF, 0x01,                                       // product
            0x99, 0x88, 0x77, 0x66                            // serial
        ]
        // Pad to 128 bytes with arbitrary garbage.
        bytes.append(contentsOf: [UInt8](repeating: 0xFF, count: 128 - bytes.count))
        let edid = EDIDExtractor.parseEDID(Data(bytes))
        XCTAssertEqual(edid?.vendorID, 0xABCD,
            "[edid=full-length] vendor must come from bytes 8-9 regardless of trailing data")
        XCTAssertEqual(edid?.productID, 0x01EF,
            "[edid=full-length] product must come from bytes 10-11 regardless of trailing data")
        XCTAssertEqual(edid?.serialNumber, 0x66778899,
            "[edid=full-length] serial must come from bytes 12-15 regardless of trailing data")
    }
}
