import UIKit
import XCTest

@testable import Vispace

@MainActor
final class PrivacySnapshotShieldTests: XCTestCase {
    func testOpaqueCoverProtectsWindowAndIsRemovedOnReturn() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        let shield = PrivacySnapshotShield()
        defer { shield.removeCovers(); window.isHidden = true }

        shield.coverWindows()
        let cover = try XCTUnwrap(window.subviews.last)
        XCTAssertEqual(cover.accessibilityIdentifier, "vispace.privacy.shield")
        XCTAssertEqual(cover.backgroundColor, .black)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertEqual(cover.frame, window.bounds)

        shield.removeCovers()
        XCTAssertFalse(window.subviews.contains { $0.accessibilityIdentifier == "vispace.privacy.shield" })
    }
}
