import Combine
import UIKit

/// Installs opaque covers synchronously before UIKit takes an app-switcher
/// snapshot. Window-level covers also protect presented settings sheets.
@MainActor
final class PrivacySnapshotShield: ObservableObject {
    private var subscriptions = Set<AnyCancellable>()
    private var covers: [UIView] = []

    init() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.coverWindows() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.removeCovers() }
            }
            .store(in: &subscriptions)
    }

    func coverWindows() {
        removeCovers()
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !window.isHidden {
                let cover = UIView(frame: window.bounds)
                cover.backgroundColor = .black
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.accessibilityIdentifier = "vispace.privacy.shield"
                cover.isAccessibilityElement = true
                cover.accessibilityLabel = "Vispace"
                window.addSubview(cover)
                covers.append(cover)
            }
        }
    }

    func removeCovers() {
        covers.forEach { $0.removeFromSuperview() }
        covers.removeAll()
    }
}
