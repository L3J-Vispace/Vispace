import XCTest

final class CameraOnlyUITests: XCTestCase {
    @MainActor
    func testAmbiguousPlacementCanBeDismissedThenReplacedWithOneFurniture() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR",
            "-VispaceDisableARSession", "-VispaceSkipOnboarding",
        ]
        app.launch()
        let field = app.textFields["vispace.query.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("place sofa and bed here")
        app.buttons["vispace.query.submit"].tap()
        let result = app.otherElements["vispace.query.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.staticTexts.firstMatch.label.contains("가구 하나"))
        app.buttons["vispace.query.dismiss"].tap()
        XCTAssertFalse(result.exists)
        app.buttons["vispace.placement.menu"].tap()
        let sofa = app.buttons["vispace.placement.sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 3))
        sofa.tap()
        let evaluate = app.buttons["vispace.placement.evaluate"]
        XCTAssertTrue(evaluate.waitForExistence(timeout: 5))
        XCTAssertTrue(evaluate.isEnabled)
        evaluate.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.staticTexts.firstMatch.label.contains("공간 정보"))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCameraSurfaceKeepsFullScreenCaptureWithGroundedSearchControl() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-VispaceDisableARSession",
            "-VispaceSkipOnboarding",
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 0)
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertEqual(app.toolbars.count, 0)
        XCTAssertEqual(app.alerts.count, 0)

        let cameraSurface = app.otherElements["vispace.camera.surface"]
        XCTAssertTrue(cameraSurface.waitForExistence(timeout: 2))
        XCTAssertEqual(cameraSurface.frame, app.windows.firstMatch.frame)

        let queryField = app.textFields["vispace.query.field"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 2))
        XCTAssertTrue(queryField.isHittable)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "camera-search-surface"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSearchProducesAnHonestResultWithoutARSession() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-VispaceDisableARSession",
            "-VispaceSkipOnboarding",
        ]
        app.launch()

        let queryField = app.textFields["vispace.query.field"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        queryField.tap()
        queryField.typeText("phone")

        let submit = app.buttons["vispace.query.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        submit.tap()

        XCTAssertTrue(
            app.otherElements["vispace.query.result"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.otherElements["vispace.grounding.unverified"].exists)
    }

    @MainActor
    func testPlacementRequestFailsClosedWithoutSpatialEvidence() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-VispaceDisableARSession",
            "-VispaceSkipOnboarding",
        ]
        app.launch()

        let queryField = app.textFields["vispace.query.field"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vispace.placement.menu"].exists)
        queryField.tap()
        queryField.typeText("place sofa here")
        app.buttons["vispace.query.submit"].tap()

        let result = app.otherElements["vispace.query.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.staticTexts.firstMatch.label.contains("공간 정보"))
        XCTAssertFalse(app.otherElements["vispace.furniture.unverified"].exists)
    }

    @MainActor
    func testRelationRequestExplainsUnconfirmedCameraState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-VispaceDisableARSession",
            "-VispaceSkipOnboarding",
        ]
        app.launch()

        let queryField = app.textFields["vispace.query.field"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        queryField.tap()
        queryField.typeText("what is above desk")
        app.buttons["vispace.query.submit"].tap()

        let result = app.otherElements["vispace.query.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.staticTexts.firstMatch.label.contains("카메라 위치"))
    }

    @MainActor
    func testSpatialDataCanBeDeletedFromCameraSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-VispaceDisableARSession",
            "-VispaceSkipOnboarding",
        ]
        app.launch()

        let settings = app.buttons["vispace.data.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let delete = app.buttons["vispace.data.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()

        let confirm = app.buttons.matching(
            identifier: "vispace.data.delete.confirm"
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()

        let success = app.descendants(matching: .any)
            .matching(identifier: "vispace.data.delete.success")
            .firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["vispace.camera.surface"].exists)
    }

    @MainActor
    func testCameraPermissionDeniedStillAllowsSpatialDataManagement() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-VispaceSkipOnboarding",
            "-VispaceSimulateCameraDenied",
        ]
        app.launch()

        let manageData = app.buttons["vispace.camera.recovery.manageData"]
        XCTAssertTrue(manageData.waitForExistence(timeout: 5))
        XCTAssertEqual(manageData.label, "공간 데이터 관리")
        XCTAssertTrue(manageData.isHittable)
        XCTAssertTrue(app.buttons["vispace.camera.permission.openSettings"].isHittable)
        XCTAssertFalse(app.otherElements["vispace.camera.surface"].exists)
        manageData.tap()

        XCTAssertTrue(app.buttons["vispace.data.delete"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["공간 데이터"].exists)
    }

    @MainActor
    func testUnavailableCameraShowsEnglishRetryAndDataRecoveryActions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-VispaceSkipOnboarding",
            "-VispaceDisableARSession",
            "-VispaceSimulateCameraUnavailable",
        ]
        app.launch()

        let title = app.staticTexts["vispace.camera.recovery.title"]
        let retry = app.buttons["vispace.camera.recovery.retry"]
        let manageData = app.buttons["vispace.camera.recovery.manageData"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Spatial camera is unavailable")
        XCTAssertEqual(retry.label, "Try Again")
        XCTAssertEqual(manageData.label, "Manage Spatial Data")
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(manageData.isHittable)
        XCTAssertFalse(app.textFields["vispace.query.field"].exists)
    }

    @MainActor
    func testFailedCameraKeepsRecoveryActionsReachableAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-VispaceSkipOnboarding",
            "-VispaceDisableARSession",
            "-VispaceSimulateCameraFailed",
        ]
        app.launch()

        let title = app.staticTexts["vispace.camera.recovery.title"]
        let retry = app.buttons["vispace.camera.recovery.retry"]
        let manageData = app.buttons["vispace.camera.recovery.manageData"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "카메라 세션이 중단됐어요")
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(manageData.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertGreaterThanOrEqual(manageData.frame.height, 44)
        XCTAssertFalse(app.otherElements["vispace.camera.surface"].exists)
        XCTAssertFalse(app.textFields["vispace.query.field"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "camera-recovery-ko-AXXXL"
        attachment.lifetime = .keepAlways
        add(attachment)
        manageData.tap()

        XCTAssertTrue(app.navigationBars["공간 데이터"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testDetectorUnavailableExplainsKoreanFeatureLimitWithoutHidingSavedDataTools()
        throws
    {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-VispaceSkipOnboarding",
            "-VispaceDisableARSession",
            "-VispaceSimulateDetectorUnavailable",
        ]
        app.launch()

        let title = app.staticTexts["vispace.perception.unavailable.title"]
        let body = app.staticTexts["vispace.perception.unavailable.body"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "물체 인식을 사용할 수 없어요")
        XCTAssertTrue(body.label.contains("새 물체를 인식하거나 공간 기억에 추가하지 않아요"))
        XCTAssertTrue(app.textFields["vispace.query.field"].isHittable)
        XCTAssertTrue(app.buttons["vispace.data.settings"].isHittable)
    }
}
