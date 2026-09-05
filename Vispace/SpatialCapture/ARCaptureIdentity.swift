import Foundation
import VispaceCore

/// Identifies the coordinate system and uninterrupted segment associated with
/// ARKit callbacks. A failed relocalization replaces both values so unrelated
/// coordinate spaces cannot be merged accidentally.
public struct ARCaptureIdentity: Equatable, Hashable, Sendable {
    public enum Status: String, Equatable, Hashable, Sendable {
        case newSegment
        case relocalizing
        case confirmed
    }

    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let status: Status

    public init(
        coordinateFrameID: CoordinateFrameID = CoordinateFrameID(),
        segmentID: CaptureSegmentID = CaptureSegmentID(),
        mapID: MapID? = nil,
        status: Status = .newSegment
    ) {
        self.coordinateFrameID = coordinateFrameID
        self.segmentID = segmentID
        self.mapID = mapID
        self.status = status
    }
}

final class ARCaptureIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ARCaptureIdentity

    init(_ value: ARCaptureIdentity = ARCaptureIdentity()) {
        storedValue = value
    }

    var value: ARCaptureIdentity {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    func recordCheckpoint(
        mapID: MapID,
        matching identity: ARCaptureIdentity
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard
            storedValue.coordinateFrameID == identity.coordinateFrameID,
            storedValue.segmentID == identity.segmentID
        else {
            return
        }
        storedValue = ARCaptureIdentity(
            coordinateFrameID: storedValue.coordinateFrameID,
            segmentID: storedValue.segmentID,
            mapID: mapID,
            status: storedValue.status
        )
    }

    /// Applies a lifecycle status transition only while `identity` still
    /// identifies the coordinate frame currently owned by this box.
    ///
    /// The stored map identifier is intentionally retained. A checkpoint can
    /// be recorded after a caller observes `identity` but before it performs
    /// the transition, and replacing the whole value would otherwise roll the
    /// checkpoint back to the caller's stale map identifier.
    @discardableResult
    func transitionStatus(
        to status: ARCaptureIdentity.Status,
        matching identity: ARCaptureIdentity
    ) -> ARCaptureIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard
            storedValue.coordinateFrameID == identity.coordinateFrameID,
            storedValue.segmentID == identity.segmentID
        else {
            return nil
        }

        let transitioned = ARCaptureIdentity(
            coordinateFrameID: storedValue.coordinateFrameID,
            segmentID: storedValue.segmentID,
            mapID: storedValue.mapID,
            status: status
        )
        storedValue = transitioned
        return transitioned
    }
}
