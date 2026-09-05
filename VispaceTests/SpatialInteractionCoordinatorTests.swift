import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class SpatialInteractionCoordinatorTests: XCTestCase {
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
