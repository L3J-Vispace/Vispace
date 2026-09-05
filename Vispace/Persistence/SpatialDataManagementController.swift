import Combine
import Foundation
import VispaceCore

public struct SpatialStoredPlace: Identifiable, Sendable {
    public let id: MapID
    public let updatedAt: TimeInterval
    public let objectCount: Int
}

public struct SpatialStorageOverview: Sendable {
    public let usedBytes: Int64
    public let availableBytes: Int64
    public let places: [SpatialStoredPlace]
}

public enum SpatialDataManagementState: Equatable, Sendable {
    case idle
    case deleting
    case switching
    case deleted
    case failed(message: String)
}

/// Coordinates user-initiated deletion with the live capture lifecycle. The
/// app supplies the lifecycle closure so this type never reaches into feature
/// controllers or silently deletes data on its own.
@MainActor
public final class SpatialDataManagementController: ObservableObject {
    public typealias DeleteAction = @MainActor @Sendable () async throws -> Void

    @Published public private(set) var state: SpatialDataManagementState = .idle
    @Published public private(set) var overview: SpatialStorageOverview?
    @Published public private(set) var overviewFailed = false

    private let deleteAction: DeleteAction
    private var deletionTask: Task<Void, Never>?
    private var overviewGeneration: UInt64 = 0
    private let overviewProvider: (@Sendable () async throws -> SpatialStorageOverview)?
    private let deletePlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)?
    private let selectPlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)?

    public var isBusy: Bool { state == .deleting || state == .switching }

    public init(
        overviewProvider: (@Sendable () async throws -> SpatialStorageOverview)? = nil,
        deletePlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)? = nil,
        selectPlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)? = nil,
        deleteAction: @escaping DeleteAction
    ) {
        self.deleteAction = deleteAction
        self.overviewProvider = overviewProvider
        self.deletePlaceAction = deletePlaceAction
        self.selectPlaceAction = selectPlaceAction
    }

    deinit {
        deletionTask?.cancel()
    }

    public func deleteAllSpatialData() {
        performDeletion(deleteAction)
    }

    public func deletePlace(_ mapID: MapID) {
        guard let deletePlaceAction else { return }
        performDeletion { try await deletePlaceAction(mapID) }
    }

    public func selectPlace(_ mapID: MapID) {
        guard let selectPlaceAction else { return }
        performDeletion({ try await selectPlaceAction(mapID) }, switching: true)
    }

    public func refreshOverview() async {
        await refreshOverview(duringMaintenance: false)
    }

    private func refreshOverview(duringMaintenance: Bool) async {
        guard let overviewProvider, duringMaintenance || !isBusy else { return }
        overviewGeneration &+= 1
        let generation = overviewGeneration
        do {
            let value = try await overviewProvider()
            try Task.checkCancellation()
            guard generation == overviewGeneration else { return }
            overview = value
            overviewFailed = false
        } catch is CancellationError {
        } catch {
            guard generation == overviewGeneration else { return }
            overview = nil
            overviewFailed = true
        }
    }

    private func performDeletion(_ action: @escaping DeleteAction, switching: Bool = false) {
        guard deletionTask == nil else {
            return
        }
        overviewGeneration &+= 1
        overview = nil
        overviewFailed = false
        state = switching ? .switching : .deleting
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action()
                try Task.checkCancellation()
                await refreshOverview(duringMaintenance: true)
                try Task.checkCancellation()
                state = switching ? .idle : .deleted
            } catch is CancellationError {
                state = .idle
            } catch {
                await refreshOverview(duringMaintenance: true)
                state = .failed(message: switching ? String(localized: "data.place.select.failed") : String(localized: "data.delete.failed"))
            }
            deletionTask = nil
        }
    }

    public func clearStatus() {
        guard deletionTask == nil else {
            return
        }
        state = .idle
    }
}

public enum SpatialDataStoreMaintenance {
    /// Deletes only Vispace's dedicated SpatialCapture directory and recreates
    /// the empty container. Callers must pause capture and persistence first.
    public static func deleteAll(at directoryURL: URL) throws {
        let target = directoryURL.standardizedFileURL
        guard target.lastPathComponent == "SpatialCapture",
            target.deletingLastPathComponent().lastPathComponent == "Vispace"
        else {
            throw SpatialDataStoreMaintenanceError.unexpectedDirectory
        }
        let fileManager = FileManager.default
        try SpatialStorageDirectory.validatePath(at: target, fileManager: fileManager)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try SpatialStorageDirectory.prepare(at: target, fileManager: fileManager)
    }
}

public enum SpatialDataStoreMaintenanceError: Error, Equatable {
    case unexpectedDirectory
    case placeUnavailable
}
