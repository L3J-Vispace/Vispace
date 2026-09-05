import Foundation

/// Pure admission check shared by the live controller and tests. A frame must
/// still belong to the exact attached ARSession run after asynchronous model
/// work finishes; matching map coordinates alone are intentionally insufficient.
public struct PerceptionFrameValidator: Sendable {
    public init() {}

    public func confirmedIdentity(
        for pose: ARPoseSnapshot,
        currentToken: ARSessionFrameToken?,
        currentIdentity: ARCaptureIdentity,
        sessionIsRunning: Bool
    ) -> ARCaptureIdentity? {
        guard
            sessionIsRunning,
            currentToken == pose.sessionToken,
            pose.coordinateFrameStatus == .confirmed,
            pose.trackingState == .normal,
            pose.timestamp.isFinite,
            pose.timestamp >= 0,
            pose.capturedAt.isFinite,
            pose.capturedAt >= 0,
            currentIdentity.status == .confirmed,
            currentIdentity.coordinateFrameID == pose.coordinateFrameID,
            currentIdentity.segmentID == pose.segmentID
        else {
            return nil
        }

        // The map identifier may be assigned while inference is in flight.
        // Returning the current identity lets the caller persist only after a
        // real checkpoint exists without rewriting old coordinate provenance.
        return currentIdentity
    }
}
