import Foundation
import VispaceCore

/// Tracks source-metadata writes across actors. A relation capture may be
/// published only while the complete source transaction stayed unchanged.
final class SpatialObjectMutationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var writers = 0

    var stableVersion: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return writers == 0 ? generation : nil
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        writers += 1
        generation &+= 1
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        writers -= 1
        generation &+= 1
    }

    /// Equality must cover the entire current map/frame, including additions.
    /// Checking only that old records still exist misses a newly observed object
    /// that can change the meaning or ambiguity of a relation question.
    static func representsSameSnapshot(
        records: [StoredSpatialObjectRecord], currentObjects: [SpatialObjectMetadata],
        mapID: MapID, coordinateFrameID: CoordinateFrameID
    ) -> Bool {
        let captured = records.map(\.metadata).filter {
            $0.mapID == mapID && $0.position.coordinateFrameID == coordinateFrameID
        }
        let current = currentObjects.filter {
            $0.mapID == mapID && $0.position.coordinateFrameID == coordinateFrameID
        }
        guard Set(captured.map { $0.object.id }).count == captured.count,
            Set(current.map { $0.object.id }).count == current.count
        else { return false }
        return Set(captured) == Set(current)
    }
}
