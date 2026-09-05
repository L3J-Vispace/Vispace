import Combine
import Foundation

/// Serializes lifecycle intent with the asynchronous deletion barrier. Feature
/// controllers own their work; this boundary owns when they may run together.
@MainActor
final class SpatialApplicationLifecycle: ObservableObject {
    enum State: Equatable {
        case inactive
        case active
        case deleting
        case storageUnavailable
    }

    enum LifecycleError: Error { case deletionInProgress }

    @Published private(set) var state: State = .inactive
    private var wantsActive = false
    private var servicesAreActive = false
    private var isDeleting = false
    private let prepareStorage: () throws -> Void
    private let start: () -> Void
    private let stop: (_ saveCheckpoint: Bool) -> Void
    private let quiesce: () async -> Void
    private let deleteStore: () async throws -> Void

    init(
        prepareStorage: @escaping () throws -> Void,
        start: @escaping () -> Void,
        stop: @escaping (_ saveCheckpoint: Bool) -> Void,
        quiesce: @escaping () async -> Void,
        deleteStore: @escaping () async throws -> Void
    ) {
        self.prepareStorage = prepareStorage
        self.start = start
        self.stop = stop
        self.quiesce = quiesce
        self.deleteStore = deleteStore
    }

    func setActive(_ active: Bool, saveCheckpoint: Bool = true) {
        wantsActive = active
        guard !isDeleting else { return }
        if active {
            activateIfAllowed()
        } else {
            stopIfRunning(saveCheckpoint: saveCheckpoint)
            state = .inactive
        }
    }

    func retry() {
        guard wantsActive, !isDeleting else { return }
        stopIfRunning(saveCheckpoint: false)
        activateIfAllowed()
    }

    func deleteSpatialData() async throws {
        try await performStorageMaintenance(deleteStore)
    }

    func performStorageMaintenance(_ action: () async throws -> Void) async throws {
        guard !isDeleting else { throw LifecycleError.deletionInProgress }
        isDeleting = true
        state = .deleting
        stopIfRunning(saveCheckpoint: false)
        defer {
            isDeleting = false
            if wantsActive {
                activateIfAllowed()
            } else {
                state = .inactive
            }
        }
        // All asynchronous writers must be joined before the store disappears.
        await quiesce()
        try await action()
    }

    private func activateIfAllowed() {
        guard wantsActive, !servicesAreActive, !isDeleting else { return }
        do {
            // Migrate existing storage even when iOS camera permission is denied.
            try prepareStorage()
            start()
            servicesAreActive = true
            state = .active
        } catch {
            state = .storageUnavailable
        }
    }

    private func stopIfRunning(saveCheckpoint: Bool) {
        guard servicesAreActive else { return }
        servicesAreActive = false
        stop(saveCheckpoint)
    }
}
