import Combine
import Foundation

public enum SpatialDataManagementState: Equatable, Sendable {
    case idle
    case deleting
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

    private let deleteAction: DeleteAction
    private var deletionTask: Task<Void, Never>?

    public init(deleteAction: @escaping DeleteAction) {
        self.deleteAction = deleteAction
    }

    deinit {
        deletionTask?.cancel()
    }

    public func deleteAllSpatialData() {
        guard deletionTask == nil else {
            return
        }
        state = .deleting
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await deleteAction()
                try Task.checkCancellation()
                state = .deleted
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(message: String(localized: "data.delete.failed"))
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
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try SpatialStorageDirectory.prepare(at: target, fileManager: fileManager)
    }
}

public enum SpatialDataStoreMaintenanceError: Error, Equatable {
    case unexpectedDirectory
}
