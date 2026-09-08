import Foundation
import SwiftUI

@MainActor
final class OnboardingState: ObservableObject {
    static let completionKey = "vispace.onboarding.v1.completed"

    @Published private(set) var hasCompleted: Bool

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults

        #if DEBUG
            if arguments.contains("-VispaceResetOnboarding") {
                defaults.removeObject(forKey: Self.completionKey)
            }

            hasCompleted =
                arguments.contains("-VispaceSkipOnboarding")
                || defaults.bool(forKey: Self.completionKey)
        #else
            hasCompleted = defaults.bool(forKey: Self.completionKey)
        #endif
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
        hasCompleted = true
    }
}
