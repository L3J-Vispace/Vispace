import Foundation
import XCTest

@testable import Vispace

@MainActor
final class OnboardingStateTests: XCTestCase {
    func testCompletionIsPersistedAcrossStateInstances() throws {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialState = OnboardingState(defaults: defaults, arguments: [])
        XCTAssertFalse(initialState.hasCompleted)

        initialState.complete()

        XCTAssertTrue(initialState.hasCompleted)
        XCTAssertTrue(defaults.bool(forKey: OnboardingState.completionKey))
        XCTAssertTrue(OnboardingState(defaults: defaults, arguments: []).hasCompleted)
    }

    #if DEBUG
        func testUITestArgumentsCanResetOrTemporarilySkipOnboarding() throws {
            let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set(true, forKey: OnboardingState.completionKey)

            let resetState = OnboardingState(
                defaults: defaults,
                arguments: ["-VispaceResetOnboarding"]
            )
            XCTAssertFalse(resetState.hasCompleted)
            XCTAssertFalse(defaults.bool(forKey: OnboardingState.completionKey))

            let skippedState = OnboardingState(
                defaults: defaults,
                arguments: ["-VispaceSkipOnboarding"]
            )
            XCTAssertTrue(skippedState.hasCompleted)
            XCTAssertFalse(defaults.bool(forKey: OnboardingState.completionKey))
        }
    #endif
}
