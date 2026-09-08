import XCTest

#if !targetEnvironment(simulator)
/// Opt-in physical-device reproduction. Run this class by itself: other UI
/// suites use simulated camera states and may intentionally reset onboarding.
/// This test submits a query only. It does not register, rename, or delete
/// objects; normal camera capture may still update automatic spatial memory.
final class PhysicalCameraSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKoreanKeyboardRequestUsesTheRealCameraWithoutASemanticTargetError() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        defer { attachObservedState(of: app) }

        let query = app.textFields["vispace.query.field"]
        let onboarding = app.buttons["vispace.onboarding.start"]
        let permissionSettings = app.buttons["vispace.camera.permission.openSettings"]
        let recovery = app.staticTexts["vispace.camera.recovery.title"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let settledLaunch = XCTNSPredicateExpectation(
            predicate: NSPredicate(format:
                "query.hittable == YES OR onboarding.exists == YES OR permission.exists == YES "
                    + "OR recovery.exists == YES OR appAlert.exists == YES OR systemAlert.exists == YES"),
            object: [
                "query": query, "onboarding": onboarding, "permission": permissionSettings,
                "recovery": recovery, "appAlert": app.alerts.firstMatch,
                "systemAlert": springboard.alerts.firstMatch,
            ] as NSDictionary
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settledLaunch], timeout: 15), .completed)
        if onboarding.exists {
            throw XCTSkip("Existing onboarding must already be completed; this test does not accept consent or reset onboarding.")
        }
        if permissionSettings.exists {
            throw XCTSkip("Camera permission must already be granted; this test does not change permissions.")
        }
        if app.alerts.firstMatch.exists || springboard.alerts.firstMatch.exists {
            throw XCTSkip("A system prompt requires the device owner's action before real-camera testing; this test does not dismiss permission prompts.")
        }

        XCTAssertFalse(recovery.exists, "The real camera must start without a recovery error")
        XCTAssertTrue(app.otherElements["vispace.camera.surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(query.isHittable)
        XCTAssertFalse(app.staticTexts["vispace.perception.unavailable.title"].exists,
                       "The bundled detector must load on the physical device")

        let request = "키보드 어디있어?"
        query.tap()
        query.typeText(request)
        XCTAssertEqual(query.value as? String, request)
        let submit = app.buttons["vispace.query.submit"]
        XCTAssertTrue(submit.isHittable)
        submit.tap()

        let result = app.otherElements["vispace.query.result"].firstMatch
        let readableResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == YES AND label != ''"),
            object: result.staticTexts.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [readableResult], timeout: 15), .completed)
        let message = result.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertFalse(message.contains("찾을 물체를 이해하지 못했어요"))
        XCTAssertFalse(message.contains("물체 이름을 말하거나"),
                       "A supported Korean keyboard request must not become an unknown semantic target")
        XCTAssertFalse(message.contains("이 요청은 물체 찾기"),
                       "The request must be routed to object search")
        XCTAssertFalse(app.staticTexts["vispace.perception.unavailable.title"].exists)
        XCTAssertFalse(recovery.exists)
        // An unseen keyboard, an uncertain position, or multiple candidates
        // are valid results. This smoke test does not assert scene contents.
    }

    @MainActor
    private func attachObservedState(of app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "physical-camera-korean-keyboard-search"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "physical-camera-korean-keyboard-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
#endif
