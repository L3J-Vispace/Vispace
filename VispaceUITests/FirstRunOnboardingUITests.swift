import XCTest

final class FirstRunOnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstRunExplainsCaptureThenStaysCompletedAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-VispaceResetOnboarding",
            "-VispaceSimulateCameraDenied",
        ]
        app.launch()

        let window = app.windows.firstMatch
        let scrollView = app.scrollViews.firstMatch
        let startButton = app.buttons["vispace.onboarding.start"]
        let title = app.staticTexts["vispace.onboarding.title"]
        let scanTitle = app.staticTexts["vispace.onboarding.scan.title"]
        let memoryTitle = app.staticTexts["vispace.onboarding.memory.title"]
        let askTitle = app.staticTexts["vispace.onboarding.ask.title"]
        let guideTitle = app.staticTexts["vispace.onboarding.guide.title"]
        let privacyTitle = app.staticTexts["vispace.onboarding.privacy.title"]
        let storageTitle = app.staticTexts["vispace.onboarding.storage.title"]
        let permissionNotice = app.staticTexts["vispace.onboarding.permissionNotice"]

        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollView.exists)
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertTrue(startButton.isHittable)
        XCTAssertGreaterThanOrEqual(startButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(startButton.frame.height, 44)
        XCTAssertTrue(title.exists)
        XCTAssertEqual(title.label, "주변 공간을 비춰 보세요")
        XCTAssertEqual(scanTitle.label, "천천히 둘러보세요")
        XCTAssertEqual(memoryTitle.label, "공간 기억을 만들어요")
        XCTAssertEqual(askTitle.label, "공간에 관해 물어보세요")
        XCTAssertEqual(guideTitle.label, "배치 추천과 안전 경로를 확인하세요")
        XCTAssertEqual(privacyTitle.label, "원본 영상은 저장하지 않아요")
        XCTAssertEqual(storageTitle.label, "삭제 전까지 기기에만 보관해요")
        XCTAssertEqual(
            permissionNotice.label,
            "시작하면 기기 내 카메라 처리와 공간 데이터 저장에 동의하며, 이어서 카메라 접근 권한을 요청합니다."
        )
        XCTAssertFalse(app.otherElements["vispace.camera.surface"].exists)

        let initialAttachment = XCTAttachment(screenshot: app.screenshot())
        initialAttachment.name = "first-run-onboarding-ko-AXXXL-top"
        initialAttachment.lifetime = .keepAlways
        add(initialAttachment)

        for _ in 0..<14 {
            if permissionNotice.frame.minY >= window.frame.minY,
                permissionNotice.frame.maxY <= startButton.frame.minY
            {
                break
            }
            scrollView.swipeUp()
        }

        XCTAssertGreaterThanOrEqual(permissionNotice.frame.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(permissionNotice.frame.maxY, startButton.frame.minY)

        let scrolledAttachment = XCTAttachment(screenshot: app.screenshot())
        scrolledAttachment.name = "first-run-onboarding-ko-AXXXL-bottom"
        scrolledAttachment.lifetime = .keepAlways
        add(scrolledAttachment)

        startButton.tap()

        let settingsButton = app.buttons["vispace.camera.permission.openSettings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsButton.isHittable)
        XCTAssertGreaterThanOrEqual(settingsButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(settingsButton.frame.height, 44)
        XCTAssertTrue(app.staticTexts["카메라 접근이 꺼져 있어요"].exists)
        XCTAssertFalse(app.otherElements["vispace.camera.surface"].exists)
        XCTAssertFalse(startButton.exists)

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "-AppleLocale",
            "ko_KR",
            "-VispaceDisableARSession",
        ]
        app.launch()

        let cameraSurface = app.otherElements["vispace.camera.surface"]
        XCTAssertTrue(cameraSurface.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vispace.onboarding.start"].exists)
    }
}
