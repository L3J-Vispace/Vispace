import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class SpatialInteractionCoordinatorTests: XCTestCase {
    func testFurnitureDimensionInputUsesTheCompleteVisibleValueAndLocale() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(FurnitureDimensionInput.parse("2.35", locale: english), 2.35)
        XCTAssertEqual(FurnitureDimensionInput.parse("2,35", locale: german), 2.35)
        XCTAssertEqual(FurnitureDimensionInput.parse(" 0.1 ", locale: english), 0.1)
        XCTAssertEqual(FurnitureDimensionInput.parse("10", locale: german), 10)
        for invalid in ["", "abc", "2.3m", "NaN", "inf", "-1", "0", "10.01", "2.3.4", "1,000"] {
            XCTAssertNil(FurnitureDimensionInput.parse(invalid, locale: english), invalid)
        }
        XCTAssertNil(FurnitureDimensionInput.parse("2.35", locale: german))
        XCTAssertNil(FurnitureDimensionInput.parse("2,35", locale: english))
        XCTAssertNil(FurnitureDimensionInput.parse("2,35m", locale: german))
    }

    func testEveryModeClearsPriorWorkBeforeStartingOneAction() {
        var calls: [String] = []
        let coordinator = SpatialInteractionCoordinator(
            cancelObjectQuery: { calls.append("object.cancel") },
            cancelRelationQuery: { calls.append("relation.cancel") },
            cancelPlacement: { calls.append("placement.cancel") },
            clearRoute: { calls.append("route.clear") },
            submitObjectQuery: { calls.append("object:\($0)") },
            submitRelationQuery: { calls.append("relation:\($0)") },
            evaluatePlacement: { calls.append("placement:\($0.rawValue)") }
        )
        let cleared = ["object.cancel", "relation.cancel", "placement.cancel", "route.clear"]
        for (command, last) in [
            (SpatialCommand.objectQuery("phone"), "object:phone"),
            (.relationQuery("under desk"), "relation:under desk"), (.placement(.sofa), "placement:sofa"),
        ] {
            calls = []
            XCTAssertNil(coordinator.perform(command))
            XCTAssertEqual(calls, cleared + [last])
        }
        calls = []
        XCTAssertEqual(coordinator.perform(.rejected(.ambiguousFurniture)), .ambiguousFurniture)
        XCTAssertEqual(calls, cleared)
    }
}
