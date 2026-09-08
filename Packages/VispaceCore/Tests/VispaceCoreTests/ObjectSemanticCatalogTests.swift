import XCTest
@testable import VispaceCore

final class ObjectSemanticCatalogTests: XCTestCase {
    func testAllEightyBundledClassesHaveUniqueBidirectionalNames() {
        let catalog = ObjectSemanticCatalog.default
        XCTAssertEqual(catalog.bundledModelLabels.count, 80)
        XCTAssertEqual(Set(catalog.bundledModelLabels).count, 80)
        for entry in catalog.entries {
            XCTAssertFalse(entry.koreanName.isEmpty)
            for term in entry.searchTerms {
                XCTAssertEqual(catalog.entry(for: term), entry, term)
                XCTAssertEqual(catalog.canonicalLabel(for: "  \(term.uppercased())  "), entry.canonicalLabel, term)
                XCTAssertEqual(catalog.displayName(for: term), entry.koreanName, term)
            }
        }
    }

    func testLegacyModelIdentifiersAndModernLabelsShareVocabulary() {
        let catalog = ObjectSemanticCatalog.default
        for (legacy, modern) in [("tvmonitor", "monitor"), ("diningtable", "dining table"),
                                 ("pottedplant", "potted plant"), ("sofa", "couch"),
                                 ("motorbike", "motorcycle"), ("aeroplane", "airplane")] {
            XCTAssertEqual(catalog.canonicalLabel(for: modern), legacy)
            XCTAssertTrue(catalog.aliases(for: legacy).contains(modern))
        }
    }

    func testUnsupportedCategoriesAreExplicitAndUnknownCustomLabelsArePreserved() {
        let catalog = ObjectSemanticCatalog.default
        for label in ["key", "wallet", "desk", "speaker", "desktop computer", "cable", "printer"] {
            XCTAssertEqual(catalog.entry(for: label)?.supportsAutomaticDetection, false)
            XCTAssertFalse(catalog.bundledModelLabels.contains(label))
        }
        XCTAssertNil(catalog.entry(for: "custom widget"))
        XCTAssertEqual(catalog.canonicalLabel(for: " Custom Widget "), "custom widget")
        XCTAssertEqual(catalog.displayName(for: "Custom Widget"), "Custom Widget")
        XCTAssertTrue(catalog.aliases(for: "custom widget").isEmpty)
    }
}
