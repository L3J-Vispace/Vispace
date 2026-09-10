import XCTest

final class UserObjectRegistrationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRegistrationFormLeavesCameraAimVisibleBeforeAndAfterNameEntry() throws {
        for largestText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR",
                "-VispaceDisableARSession", "-VispaceSkipOnboarding",
            ]
            if largestText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                        "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            let name = openRegistration(in: app)
            let form = app.scrollViews["vispace.registration.form"]
            let cameraCenterY = app.windows.firstMatch.frame.midY
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "registration-aim-\(largestText ? "largest" : "standard")"
            capture.lifetime = .keepAlways
            add(capture)
            XCTAssertGreaterThanOrEqual(form.frame.minY, cameraCenterY + 32,
                                        "The form must leave the camera's central aiming region visible")
            name.tap()
            name.typeText("phone\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(form.frame.minY, cameraCenterY + 32)
            app.buttons["vispace.registration.close"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testExistingObjectPickerCanBeOpenedAndCancelledWithoutCreatingARegistration() throws {
        let app = launchWithoutCameraEvidence()
        let name = openRegistration(in: app)
        let existing = app.buttons["vispace.registration.choose-existing"]
        XCTAssertTrue(existing.isHittable)
        existing.tap()
        XCTAssertTrue(app.navigationBars["위치를 바꿀 물체"].waitForExistence(timeout: 3))
        app.navigationBars["위치를 바꿀 물체"].buttons["취소"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["vispace.registration.capture"].isEnabled)
        XCTAssertFalse(app.buttons["기억한 위치 검색"].exists)
        app.buttons["vispace.registration.close"].tap()
    }

    @MainActor
    func testRegistrationActionsRemainReachableAtLargestAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-VispaceDisableARSession", "-VispaceSkipOnboarding",
        ]
        app.launch()
        XCTAssertTrue(app.textFields["vispace.query.field"].waitForExistence(timeout: 5))
        let name = openRegistration(in: app)
        let instructionCapture = XCTAttachment(screenshot: app.screenshot())
        instructionCapture.name = "registration-instructions-largest-text"
        instructionCapture.lifetime = .keepAlways
        add(instructionCapture)
        try app.performAccessibilityAudit(for: .textClipped)
        name.tap()
        name.typeText("휴대폰")
        XCTAssertEqual(name.value as? String, "휴대폰")
        name.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
                      "Done must dismiss the keyboard so the primary action is reachable")
        let nameCapture = XCTAttachment(screenshot: name.screenshot())
        nameCapture.name = "registration-name-largest-text"
        nameCapture.lifetime = .keepAlways
        add(nameCapture)
        try app.performAccessibilityAudit(for: .textClipped)
        let capture = app.buttons["vispace.registration.capture"]
        for _ in 0..<5 {
            if capture.isHittable { break }
            app.scrollViews["vispace.registration.form"].swipeUp()
        }
        XCTAssertTrue(capture.isHittable)
        let formCapture = XCTAttachment(screenshot: app.screenshot())
        formCapture.name = "registration-largest-accessibility-form"
        formCapture.lifetime = .keepAlways
        add(formCapture)
        capture.tap()
        let close = app.buttons["vispace.registration.close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.textFields["vispace.query.field"].isHittable)
    }

    @MainActor
    func testRegistrationCanBeCancelledAndReopenedWithoutRetainingTheDraft() throws {
        let app = launchWithoutCameraEvidence()
        let name = openRegistration(in: app)
        let capture = app.buttons["vispace.registration.capture"]
        XCTAssertFalse(capture.isEnabled, "An unnamed object cannot be registered")
        XCTAssertTrue(app.staticTexts["vispace.registration.status"].label.contains("마지막 확인 위치"))

        name.tap()
        name.typeText("my speaker")
        XCTAssertTrue(capture.isEnabled)
        capture.tap()
        app.buttons["vispace.registration.close"].tap()

        let query = app.textFields["vispace.query.field"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(query.isHittable)
        XCTAssertFalse(app.buttons["vispace.registration.close"].exists)

        let freshName = openRegistration(in: app)
        XCTAssertEqual(freshName.value as? String, freshName.placeholderValue)
        XCTAssertFalse(capture.isEnabled)
        XCTAssertTrue(app.staticTexts["vispace.registration.status"].label.contains("마지막 확인 위치"))
        app.buttons["vispace.registration.close"].tap()
        XCTAssertTrue(query.isHittable)
    }

    @MainActor
    func testMissingCameraEvidenceDoesNotReportASavedObjectAndAllowsRetry() throws {
        let app = launchWithoutCameraEvidence()
        let name = openRegistration(in: app)
        name.tap()
        name.typeText("my speaker")
        app.buttons["vispace.registration.capture"].tap()

        let status = app.staticTexts["vispace.registration.status"]
        let unavailable = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "위치를 확인하지 못했어요", "카메라 입력이 중단됐어요"
        )
        let expectation = XCTNSPredicateExpectation(predicate: unavailable, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed)
        XCTAssertFalse(app.buttons["기억한 위치 검색"].exists)
        XCTAssertTrue(app.buttons["vispace.registration.capture"].isEnabled)
        XCTAssertTrue(name.isEnabled)
        XCTAssertEqual(name.value as? String, "my speaker")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "manual-registration-no-camera-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["vispace.registration.close"].tap()
        XCTAssertTrue(app.textFields["vispace.query.field"].isHittable)
    }

    @MainActor
    private func launchWithoutCameraEvidence() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR",
            "-VispaceDisableARSession", "-VispaceSkipOnboarding",
        ]
        app.launch()
        XCTAssertTrue(app.textFields["vispace.query.field"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openRegistration(in app: XCUIApplication) -> XCUIElement {
        app.buttons["vispace.placement.menu"].tap()
        let entry = app.buttons["물체 위치 직접 등록"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        let name = app.textFields["vispace.registration.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vispace.registration.close"].isHittable)
        XCTAssertFalse(app.textFields["vispace.query.field"].isHittable)
        return name
    }
}
