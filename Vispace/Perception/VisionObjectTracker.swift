import CoreGraphics
import Foundation
@preconcurrency import Vision

public struct VisionTrackID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TrackingSeed: Equatable, Sendable {
    public let id: VisionTrackID
    public let boundingBox: NormalizedBoundingBox

    public init(
        id: VisionTrackID = VisionTrackID(),
        boundingBox: NormalizedBoundingBox
    ) {
        self.id = id
        self.boundingBox = boundingBox
    }
}

public struct TrackedObject: Equatable, Sendable {
    public let id: VisionTrackID
    public let confidence: Float
    public let boundingBox: NormalizedBoundingBox

    public init(
        id: VisionTrackID,
        confidence: Float,
        boundingBox: NormalizedBoundingBox
    ) {
        self.id = id
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public protocol ObjectTracking: Sendable {
    func seed(_ seeds: [TrackingSeed]) async
    func track(in frame: ARFrameSnapshot) async throws -> [TrackedObject]
    func reset() async
}

/// Stateful seam around VNTrackObjectRequest. A detector must provide initial
/// boxes; tracking follows those boxes and does not perform semantic re-ID.
public actor VisionObjectTracker: ObjectTracking {
    private struct State {
        let id: VisionTrackID
        let request: VNTrackObjectRequest
    }

    private var sequenceHandler = VNSequenceRequestHandler()
    private var states: [VisionTrackID: State] = [:]
    private let minimumConfidence: Float

    public init(minimumConfidence: Float = 0.3) {
        self.minimumConfidence =
            minimumConfidence.isFinite
            ? min(max(minimumConfidence, 0), 1)
            : 0.3
    }

    public func seed(_ seeds: [TrackingSeed]) async {
        sequenceHandler = VNSequenceRequestHandler()
        states.removeAll(keepingCapacity: true)

        for seed in seeds {
            guard let boundingBox = seed.boundingBox.visionBoundingBox else {
                continue
            }
            let observation = VNDetectedObjectObservation(
                boundingBox: boundingBox
            )
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            states[seed.id] = State(id: seed.id, request: request)
        }
    }

    public func track(in frame: ARFrameSnapshot) async throws -> [TrackedObject] {
        guard !states.isEmpty else {
            return []
        }

        let orderedStates = states.values.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        let requests = orderedStates.map(\.request)
        try sequenceHandler.perform(
            requests,
            on: frame.capturedImage.pixelBuffer,
            orientation: frame.imageOrientation.cgImageOrientation
        )

        var liveIDs = Set<VisionTrackID>()
        var output: [TrackedObject] = []
        output.reserveCapacity(orderedStates.count)

        for state in orderedStates {
            guard
                let observation = state.request.results?.first as? VNDetectedObjectObservation,
                observation.confidence.isFinite,
                observation.confidence >= minimumConfidence
            else {
                continue
            }

            state.request.inputObservation = observation
            liveIDs.insert(state.id)
            output.append(
                TrackedObject(
                    id: state.id,
                    confidence: observation.confidence,
                    boundingBox: NormalizedBoundingBox(observation.boundingBox)
                )
            )
        }

        states = states.filter { liveIDs.contains($0.key) }
        if states.isEmpty {
            sequenceHandler = VNSequenceRequestHandler()
        }
        return output
    }

    public func reset() async {
        states.removeAll(keepingCapacity: false)
        sequenceHandler = VNSequenceRequestHandler()
    }
}

extension NormalizedBoundingBox {
    fileprivate var visionBoundingBox: CGRect? {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite), width > 0, height > 0 else {
            return nil
        }

        let source = CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
        let clipped = source.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}
