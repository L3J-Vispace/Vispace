import XCTest

final class CameraOnlyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShippingSurfaceContainsNoCustomChrome() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-VispaceDisableARSession")
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.count, 0)
        XCTAssertEqual(app.staticTexts.count, 0)
        XCTAssertEqual(app.navigationBars.count, 0)
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertEqual(app.toolbars.count, 0)
        XCTAssertEqual(app.alerts.count, 0)

        let cameraSurface = app.otherElements["vispace.camera.surface"]
        XCTAssertTrue(cameraSurface.waitForExistence(timeout: 2))
        XCTAssertEqual(cameraSurface.frame, app.windows.firstMatch.frame)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "camera-only-surface"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
