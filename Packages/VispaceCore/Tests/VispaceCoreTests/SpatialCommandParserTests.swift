import XCTest

@testable import VispaceCore

final class SpatialCommandParserTests: XCTestCase {
    private let parser = SpatialCommandParser()

    func testPlacementIsSpecificAndEnglishTokenBounded() {
        XCTAssertEqual(parser.parse("소파 놓으면 어때?"), .placement(.sofa))
        XCTAssertEqual(parser.parse("Can I place a bed here?"), .placement(.bed))
        XCTAssertEqual(parser.parse("place bedspread"), .rejected(.unsupportedFurniture))
        XCTAssertEqual(parser.parse("fit bedroom"), .rejected(.unsupportedFurniture))
        XCTAssertEqual(parser.parse("misplaced sofa"), .objectQuery("misplaced sofa"))
    }

    func testAmbiguousAndNegativeRequestsDoNotRunPlacement() {
        XCTAssertEqual(parser.parse("소파와 침대 배치"), .rejected(.ambiguousFurniture))
        for text in [
            "소파 놓지 마", "Don't place a sofa", "do not recommend a desk", "can't fit a bed", "침대 안 놓을래",
        ] {
            XCTAssertEqual(parser.parse(text), .rejected(.negatedPlacement), text)
        }
    }

    func testBoundsApplyBeforeRoutingAndNormalizationHandlesKorean() {
        XCTAssertEqual(parser.parse(String(repeating: "x", count: 257)), .rejected(.tooLong))
        XCTAssertEqual(parser.parse("a" + String(repeating: "\u{0301}", count: 1_025)), .rejected(.tooLong))
        XCTAssertEqual(parser.parse("  \n "), .rejected(.empty))
        XCTAssertEqual(parser.parse("소파 배치".decomposedStringWithCanonicalMapping), .placement(.sofa))
    }

    func testExistingQueriesKeepTheirDomainRouter() {
        for text in ["마지막으로 소파를 어디 놓았어?", "소파가 놓인 곳으로 안내해 줘"] {
            XCTAssertEqual(parser.parse(text), .objectQuery(text))
        }
        XCTAssertEqual(parser.parse("phone"), .objectQuery("phone"))
        XCTAssertEqual(parser.parse("책상 아래 뭐가 있어?"), .relationQuery("책상 아래 뭐가 있어?"))
        XCTAssertEqual(parser.parse("소파로 안내"), .objectQuery("소파로 안내"))
        XCTAssertEqual(parser.parse("마지막으로 소파 어디 있었어"), .objectQuery("마지막으로 소파 어디 있었어"))
    }
}
