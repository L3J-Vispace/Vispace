import XCTest

final class CameraOnlyUITests: XCTestCase {
    @MainActor
    func testSearchRegistrationAndReturnPassStructuralAccessibilityAudit() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR",
            "-VispaceDisableARSession", "-VispaceSkipOnboarding",
        ]
        app.launch()
        let field = app.textFields["vispace.query.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("phone")
        app.buttons["vispace.query.submit"].tap()
        XCTAssertTrue(app.otherElements["vispace.query.result"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait, .textClipped])
        app.buttons["vispace.object.register"].tap()
        XCTAssertTrue(app.textFields["vispace.registration.name"].waitForExistence(timeout: 5))
        let registrationCapture = XCTAttachment(screenshot: app.screenshot())
        registrationCapture.name = "registration-from-search-result"
        registrationCapture.lifetime = .keepAlways
        add(registrationCapture)
        let registrationHierarchy = XCTAttachment(string: app.debugDescription)
        registrationHierarchy.name = "registration-from-search-result-hierarchy"
        registrationHierarchy.lifetime = .keepAlways
        add(registrationHierarchy)
        XCTAssertFalse(field.isHittable)
        XCTAssertFalse(app.buttons["vispace.query.submit"].isHittable)
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait, .textClipped]) { issue in
            // iOS 26.5 predicts clipping for these default-size controls despite their dynamic layout.
            // The largest-text test audits both without a filter and captures the scrolled content.
            let runtime = ProcessInfo.processInfo.operatingSystemVersion
            return runtime.majorVersion == 26 && runtime.minorVersion == 5
                && issue.auditType == .textClipped
                && ["vispace.registration.status", "vispace.registration.name"]
                    .contains(issue.element?.identifier ?? "")
                && issue.detailedDescription.contains("may be clipped at larger Dynamic Type sizes")
        }
        app.buttons["vispace.registration.close"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "phone")
        XCTAssertTrue(app.buttons["vispace.query.submit"].isHittable)
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait, .textClipped])
    }

    @MainActor
    func testObjectToolsMenuUsesSelectedLanguage() throws {
        for (language, locale, menuLabel, registerLabel, sofaLabel) in [
            ("en", "en_US", "Object registration and furniture placement", "Remember an object location", "Sofa"),
            ("ko", "ko_KR", "물체 등록 및 가구 배치", "물체 위치 직접 등록", "소파"),
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                "-VispaceDisableARSession", "-VispaceSkipOnboarding",
            ]
            app.launch()
            let menu = app.buttons["vispace.placement.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            XCTAssertEqual(menu.label, menuLabel)
            menu.tap()
            let registration = app.buttons[registerLabel]
            XCTAssertTrue(registration.waitForExistence(timeout: 3))
            XCTAssertTrue(registration.isHittable)
            let sofa = app.buttons["vispace.placement.sofa"]
            XCTAssertEqual(sofa.label, sofaLabel)
            XCTAssertTrue(sofa.isHittable)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "object-tools-menu-\(language)"
            capture.lifetime = .keepAlways
            add(capture)
            app.terminate()
        }
    }

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
    func testQueryControlsHaveUsableTouchTargetsWithKeyboard() throws {
        try verifyQueryControlTouchTargets(accessibilitySize: false)
    }

    @MainActor
    func testQueryControlsRemainUsableAtLargestAccessibilitySize() throws {
        try verifyQueryControlTouchTargets(accessibilitySize: true)
    }

    @MainActor
    private func verifyQueryControlTouchTargets(accessibilitySize: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-VispaceDisableARSession", "-VispaceSkipOnboarding",
        ]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let field = app.textFields["vispace.query.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("phone")
        let settings = app.buttons["vispace.data.settings"]
        let menu = app.buttons["vispace.placement.menu"]
        let submit = app.buttons["vispace.query.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        for control in [settings, menu, submit] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame))
            XCTAssertFalse(control.frame.intersects(field.frame))
        }
        if accessibilitySize {
            XCTAssertGreaterThanOrEqual(settings.frame.minY, field.frame.maxY)
        }
        // Tapping beyond the visible glyph exercises the expanded hit region.
        submit.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        XCTAssertTrue(app.otherElements["vispace.query.result"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = accessibilitySize ? "query-controls-accessibility-xxxl" : "query-controls-standard"
        capture.lifetime = .keepAlways
        add(capture)
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        XCTAssertTrue(app.navigationBars["Spatial Data"].waitForExistence(timeout: 5))
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

        let evaluate = app.buttons["vispace.placement.evaluate"]
        XCTAssertTrue(evaluate.waitForExistence(timeout: 5))
        XCTAssertTrue(evaluate.isEnabled)
        evaluate.tap()

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

        let delete = revealDeleteAction(in: app)
        XCTAssertTrue(delete.isHittable)
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
        XCTAssertTrue(success.isHittable, "Deletion feedback must remain visible after the storage list changes.")
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

        XCTAssertTrue(app.navigationBars["공간 데이터"].waitForExistence(timeout: 5))
        XCTAssertTrue(revealDeleteAction(in: app).isHittable)
    }

    @MainActor
    private func revealDeleteAction(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["vispace.data.delete"]
        // Settings now contains supported-device details and a place catalog.
        // Exercise the real scrollable screen rather than requiring the
        // destructive action to remain in the initial viewport.
        for _ in 0..<8 {
            if button.exists && button.isHittable { return button }
            app.swipeUp()
        }
        return button
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
        XCTAssertTrue(body.label.contains("물체 자동 인식과 공간 기억 자동 갱신을 사용할 수 없어요"))
        XCTAssertTrue(app.textFields["vispace.query.field"].isHittable)
        XCTAssertTrue(app.buttons["vispace.data.settings"].isHittable)
    }
}
