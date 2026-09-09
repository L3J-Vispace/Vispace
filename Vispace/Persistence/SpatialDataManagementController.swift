import Combine
import Foundation
import VispaceCore

public struct SpatialStoredPlace: Identifiable, Sendable {
    public let id: MapID
    public let updatedAt: TimeInterval
    public let objectCount: Int
    public let checkpointBytes: Int64
    public let olderCheckpointBytes: Int64
    public let removedObjectCount: Int

    public init(id: MapID, updatedAt: TimeInterval, objectCount: Int,
                checkpointBytes: Int64 = 0, olderCheckpointBytes: Int64 = 0, removedObjectCount: Int = 0) {
        self.id = id
        self.updatedAt = updatedAt
        self.objectCount = objectCount
        self.checkpointBytes = checkpointBytes
        self.olderCheckpointBytes = olderCheckpointBytes
        self.removedObjectCount = removedObjectCount
    }
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
    case exporting
    case importing
    case imported
    case deleted
    case cleaningRemovedHistory
    case cleanedRemovedHistory
    case failed(message: String)
}

/// Coordinates user-initiated deletion with the live capture lifecycle. The
/// app supplies the lifecycle closure so this type never reaches into feature
/// controllers or silently deletes data on its own.
@MainActor
public final class SpatialDataManagementController: ObservableObject {
    public typealias DeleteAction = @MainActor @Sendable () async throws -> Void
    public typealias ExportPlaceAction = @MainActor @Sendable (MapID) async throws -> SpatialPlaceEncryptedExport
    public typealias ImportPlaceAction = @MainActor @Sendable (URL, String) async throws -> MapID

    @Published public private(set) var state: SpatialDataManagementState = .idle
    @Published public private(set) var overview: SpatialStorageOverview?
    @Published public private(set) var overviewFailed = false
    @Published public private(set) var preparedExport: SpatialPlaceEncryptedExport?

    private let deleteAction: DeleteAction
    private var deletionTask: Task<Void, Never>?
    private var overviewGeneration: UInt64 = 0
    private let overviewProvider: (@Sendable () async throws -> SpatialStorageOverview)?
    private let deletePlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)?
    private let selectPlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)?
    private let exportPlaceAction: ExportPlaceAction?
    private let importPlaceAction: ImportPlaceAction?
    private let cleanupRemovedHistoryAction: (@MainActor @Sendable (MapID) async throws -> Void)?

    public var isBusy: Bool {
        state == .deleting || state == .switching || state == .exporting || state == .importing
            || state == .cleaningRemovedHistory || preparedExport != nil
    }
    public var supportsPlaceTransfer: Bool { exportPlaceAction != nil && importPlaceAction != nil }
    public var supportsRemovedHistoryCleanup: Bool { cleanupRemovedHistoryAction != nil }

    public init(
        overviewProvider: (@Sendable () async throws -> SpatialStorageOverview)? = nil,
        deletePlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)? = nil,
        selectPlaceAction: (@MainActor @Sendable (MapID) async throws -> Void)? = nil,
        exportPlaceAction: ExportPlaceAction? = nil,
        importPlaceAction: ImportPlaceAction? = nil,
        cleanupRemovedHistoryAction: (@MainActor @Sendable (MapID) async throws -> Void)? = nil,
        deleteAction: @escaping DeleteAction
    ) {
        self.deleteAction = deleteAction
        self.overviewProvider = overviewProvider
        self.deletePlaceAction = deletePlaceAction
        self.selectPlaceAction = selectPlaceAction
        self.exportPlaceAction = exportPlaceAction
        self.importPlaceAction = importPlaceAction
        self.cleanupRemovedHistoryAction = cleanupRemovedHistoryAction
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

    public func cleanupRemovedObjectHistory(_ mapID: MapID) {
        guard let cleanupRemovedHistoryAction else { return }
        performDeletion({ try await cleanupRemovedHistoryAction(mapID) }, cleaningRemovedHistory: true)
    }

    public func preparePlaceExport(_ mapID: MapID) {
        guard deletionTask == nil, preparedExport == nil, let exportPlaceAction else { return }
        state = .exporting
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { deletionTask = nil }
            do {
                let export = try await exportPlaceAction(mapID)
                try Task.checkCancellation()
                preparedExport = export
                state = .idle
            } catch is CancellationError { state = .idle }
            catch { state = .failed(message: Self.transferErrorMessage(error)) }
        }
    }

    public func discardPreparedExport() {
        preparedExport = nil
    }

    public func importPlace(from selectedFile: URL, recoveryKey: String) {
        guard deletionTask == nil, preparedExport == nil, let importPlaceAction else { return }
        overviewGeneration &+= 1
        overview = nil
        overviewFailed = false
        state = .importing
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { deletionTask = nil }
            do {
                _ = try await importPlaceAction(selectedFile, recoveryKey)
                await refreshOverview(duringMaintenance: true)
                state = .imported
            } catch is CancellationError { state = .idle }
            catch {
                await refreshOverview(duringMaintenance: true)
                state = .failed(message: Self.transferErrorMessage(error))
            }
        }
    }

    private static func transferErrorMessage(_ error: any Error) -> String {
        if let repositoryError = error as? WorldMapCheckpointRepositoryError {
            switch repositoryError {
            case .importedMapAlreadyExists, .importedCoordinateFrameAlreadyExists, .importedObjectAlreadyExists:
                return String(localized: "data.transfer.duplicate")
            case .metadataFileUnavailable: return String(localized: "data.transfer.recovery.required")
            default: break
            }
        }
        if let archiveError = error as? SpatialPlaceArchiveError {
            switch archiveError {
            case .invalidRecoveryKey, .authenticationFailed: return String(localized: "data.transfer.key.failed")
            case .fileTooLarge: return String(localized: "data.transfer.size.failed")
            case .unsupportedVersion: return String(localized: "data.transfer.version.failed")
            case .invalidDocument, .checksumMismatch, .placeUnavailable: return String(localized: "data.transfer.invalid")
            }
        }
        if error is SpatialStorageError { return String(localized: "data.transfer.storage.failed") }
        return String(localized: "data.transfer.failed")
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

    private func performDeletion(_ action: @escaping DeleteAction, switching: Bool = false,
                                 cleaningRemovedHistory: Bool = false) {
        guard deletionTask == nil, preparedExport == nil else {
            return
        }
        overviewGeneration &+= 1
        overview = nil
        overviewFailed = false
        state = switching ? .switching : (cleaningRemovedHistory ? .cleaningRemovedHistory : .deleting)
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action()
                try Task.checkCancellation()
                await refreshOverview(duringMaintenance: true)
                try Task.checkCancellation()
                state = switching ? .idle : (cleaningRemovedHistory ? .cleanedRemovedHistory : .deleted)
            } catch is CancellationError {
                state = .idle
            } catch {
                await refreshOverview(duringMaintenance: true)
                state = .failed(message: switching ? String(localized: "data.place.select.failed")
                    : (cleaningRemovedHistory ? String(localized: "data.history.cleanup.failed")
                       : String(localized: "data.delete.failed")))
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
