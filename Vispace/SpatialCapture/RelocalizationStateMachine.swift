import Foundation

struct RelocalizationStateMachine: Sendable {
    enum State: Equatable, Sendable {
        case idle
        case awaitingNormal(
            generation: UInt64,
            sessionRunGeneration: UInt64,
            identity: ARCaptureIdentity
        )
        case confirmed(identity: ARCaptureIdentity)
        case timedOut(generation: UInt64)
    }

    enum Outcome: Equatable, Sendable {
        case none
        case confirmed(ARCaptureIdentity)
        case startFreshSegment
    }

    private(set) var state: State = .idle
    private var generation: UInt64 = 0

    mutating func begin(
        identity: ARCaptureIdentity,
        sessionRunGeneration: UInt64
    ) -> UInt64 {
        generation &+= 1
        let relocalizing = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            status: .relocalizing
        )
        state = .awaitingNormal(
            generation: generation,
            sessionRunGeneration: sessionRunGeneration,
            identity: relocalizing
        )
        return generation
    }

    mutating func observe(
        _ trackingState: ARTrackingStateSnapshot,
        identity observedIdentity: ARCaptureIdentity,
        sessionRunGeneration observedRunGeneration: UInt64
    ) -> Outcome {
        guard
            case .awaitingNormal(_, let expectedRunGeneration, let identity) = state,
            expectedRunGeneration == observedRunGeneration,
            identity.coordinateFrameID == observedIdentity.coordinateFrameID,
            identity.segmentID == observedIdentity.segmentID,
            observedIdentity.status == .relocalizing,
            trackingState == .normal
        else {
            return .none
        }
        let confirmed = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            // A checkpoint created while recovery is in flight may attach a
            // newer map ID to this exact frame and segment. Preserve it.
            mapID: observedIdentity.mapID,
            status: .confirmed
        )
        state = .confirmed(identity: confirmed)
        return .confirmed(confirmed)
    }

    mutating func timeout(generation expectedGeneration: UInt64) -> Outcome {
        guard case .awaitingNormal(let activeGeneration, _, _) = state,
            activeGeneration == expectedGeneration
        else {
            return .none
        }
        state = .timedOut(generation: activeGeneration)
        return .startFreshSegment
    }

    mutating func cancel() {
        generation &+= 1
        state = .idle
    }
}
