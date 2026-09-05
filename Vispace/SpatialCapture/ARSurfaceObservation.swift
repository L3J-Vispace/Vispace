@preconcurrency import ARKit
import Foundation
import Metal
import VispaceCore
import simd

public enum ARSurfaceObservationChange: String, Equatable, Hashable, Sendable {
    case added
    case updated
    case removed
}

public enum ARSurfaceKind: String, Equatable, Hashable, Sendable {
    case plane
    case mesh
}

public enum ARPlaneAlignmentSnapshot: String, Equatable, Hashable, Sendable {
    case horizontal
    case vertical
    case unknown
}

public enum ARPlaneClassificationSnapshot: String, Equatable, Hashable, Sendable {
    case none
    case wall
    case floor
    case ceiling
    case table
    case seat
    case window
    case door
    case unknown
}

public enum ARMeshClassificationSnapshot: String, Equatable, Hashable, Sendable {
    case none
    case wall
    case floor
    case ceiling
    case table
    case seat
    case window
    case door
    case unknown
}

public struct ARPlaneObservationSnapshot: Equatable, Sendable {
    public let anchorID: UUID
    public let transform: Matrix4x4Snapshot
    public let center: SIMD3<Float>
    public let extent: SIMD3<Float>
    public let extentRotationOnYAxis: Float
    /// Refined anchor-local footprint used for support and boundary checks.
    public let boundaryVertices: [SIMD3<Float>]
    public let alignment: ARPlaneAlignmentSnapshot
    public let classification: ARPlaneClassificationSnapshot
}

public struct ARMeshObservationSnapshot: Equatable, Sendable {
    public let anchorID: UUID
    public let transform: Matrix4x4Snapshot
    public let vertices: [SIMD3<Float>]
    /// Three indices per triangle, in anchor-local coordinates.
    public let triangleIndices: [UInt32]
    /// One classification per triangle when ARKit exposes classification.
    public let faceClassifications: [ARMeshClassificationSnapshot]
}

public enum ARSurfaceObservationPayload: Equatable, Sendable {
    case plane(ARPlaneObservationSnapshot)
    case mesh(ARMeshObservationSnapshot)
    case removed(anchorID: UUID, kind: ARSurfaceKind)
}

public struct ARSurfaceObservation: Equatable, Sendable {
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let coordinateFrameStatus: ARCaptureIdentity.Status
    public let timestamp: TimeInterval
    public let change: ARSurfaceObservationChange
    public let payload: ARSurfaceObservationPayload
}

/// Coalesced surface state. Consumers may miss intermediate revisions without
/// losing accepted add/update/remove changes. Placement/navigation must fail
/// closed whenever `isComplete` is false.
public struct ARSurfaceStateSnapshot: Equatable, Sendable {
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let coordinateFrameStatus: ARCaptureIdentity.Status
    public let revision: UInt64
    public let timestamp: TimeInterval
    public let planes: [UUID: ARPlaneObservationSnapshot]
    public let meshes: [UUID: ARMeshObservationSnapshot]
    public let unresolvedFailures: [ARSurfaceObservationFailure]
    /// False across detach, pause, reset, and session replacement boundaries.
    /// An empty snapshot is not safe evidence that a space contains no obstacle
    /// until it was produced by the currently active ARSession.
    public let isCurrentSessionData: Bool
    /// Last actual anchor observation; an unrelated delta or full-state replay
    /// must not refresh every retained surface's age.
    public let anchorObservedAt: [UUID: TimeInterval]

    public init(
        coordinateFrameID: CoordinateFrameID, segmentID: CaptureSegmentID, mapID: MapID?,
        coordinateFrameStatus: ARCaptureIdentity.Status, revision: UInt64,
        timestamp: TimeInterval, planes: [UUID: ARPlaneObservationSnapshot],
        meshes: [UUID: ARMeshObservationSnapshot], unresolvedFailures: [ARSurfaceObservationFailure],
        isCurrentSessionData: Bool, anchorObservedAt: [UUID: TimeInterval] = [:]
    ) {
        self.coordinateFrameID = coordinateFrameID
        self.segmentID = segmentID
        self.mapID = mapID
        self.coordinateFrameStatus = coordinateFrameStatus
        self.revision = revision
        self.timestamp = timestamp
        self.planes = planes
        self.meshes = meshes
        self.unresolvedFailures = unresolvedFailures
        self.isCurrentSessionData = isCurrentSessionData
        self.anchorObservedAt = anchorObservedAt
    }

    public func hasFreshSurfaces(at evaluatedAt: TimeInterval, maximumAge: TimeInterval) -> Bool {
        guard evaluatedAt.isFinite, maximumAge.isFinite, maximumAge >= 0 else { return false }
        return Set(planes.keys).union(meshes.keys).allSatisfy { anchorID in
            guard let observedAt = anchorObservedAt[anchorID], observedAt.isFinite,
                observedAt >= 0 else { return false }
            let age = evaluatedAt - observedAt
            return age >= -0.25 && age <= maximumAge
        }
    }

    public var isComplete: Bool {
        isCurrentSessionData
            && coordinateFrameStatus == .confirmed
            && unresolvedFailures.isEmpty
    }
}

public enum ARSurfaceObservationError: Error, Equatable, Sendable {
    case unsupportedFaceIndexSize(Int)
    case invalidVertexBuffer
    case invalidFaceBuffer
    case geometryLimitExceeded(vertices: Int, faces: Int)
    case accumulatedGeometryLimitExceeded(vertices: Int, faces: Int)
    case accumulatedAnchorLimitExceeded(planes: Int, meshes: Int)
    case planeBoundaryLimitExceeded(Int)
    case unexpectedAdapterFailure(message: String)
}

public struct ARSurfaceObservationFailure: Equatable, Sendable {
    public let anchorID: UUID
    public let error: ARSurfaceObservationError
}

public struct ARSurfaceObservationBatch: Sendable {
    public let captureIdentity: ARCaptureIdentity
    public let timestamp: TimeInterval
    public let observations: [ARSurfaceObservation]
    public let failures: [ARSurfaceObservationFailure]
    /// True when `observations` and `failures` describe every current surface
    /// anchor, so an omitted prior anchor can be removed deterministically.
    public let isAuthoritative: Bool
    /// Actual delegate callback times, separate from full-list capture time.
    public let observedAnchorTimestamps: [UUID: TimeInterval]

    public init(
        captureIdentity: ARCaptureIdentity,
        timestamp: TimeInterval,
        observations: [ARSurfaceObservation],
        failures: [ARSurfaceObservationFailure],
        isAuthoritative: Bool = false,
        observedAnchorTimestamps: [UUID: TimeInterval] = [:]
    ) {
        self.captureIdentity = captureIdentity
        self.timestamp = timestamp
        self.observations = observations
        self.failures = failures
        self.isAuthoritative = isAuthoritative
        self.observedAnchorTimestamps = observedAnchorTimestamps
    }
}

/// App-owned bytes copied from ARKit on its delegate queue. Only these Sendable
/// values cross to the geometry worker; live ARAnchor/MTLBuffer objects never do.
struct ARSurfaceRawCaptureBatch: Sendable {
    let captureIdentity: ARCaptureIdentity
    let timestamp: TimeInterval
    let captures: [ARSurfaceRawCapture]
    let failures: [ARSurfaceObservationFailure]
    let isAuthoritative: Bool
    var observedAnchorTimestamps: [UUID: TimeInterval] = [:]
}

/// Retaining callback provenance until the session boundary means replacing a
/// pending full snapshot cannot erase an earlier coalesced anchor update.
struct ARSurfaceAnchorObservationHistory: Sendable {
    private struct Event: Sendable {
        let timestamp: TimeInterval
        let change: ARSurfaceObservationChange
        let kind: ARSurfaceKind
    }
    private var events: [UUID: Event] = [:]

    mutating func record(
        anchorID: UUID, kind: ARSurfaceKind, change: ARSurfaceObservationChange,
        timestamp: TimeInterval
    ) {
        guard timestamp.isFinite, timestamp >= 0,
            events[anchorID].map({ timestamp >= $0.timestamp }) != false
        else { return }
        events[anchorID] = Event(timestamp: timestamp, change: change, kind: kind)
        // Removed anchor IDs can accumulate during long captures. Eviction
        // only loses freshness evidence; it never manufactures a new time.
        if events.count > 4_096,
            let oldest = events.min(by: { $0.value.timestamp < $1.value.timestamp })?.key
        {
            events.removeValue(forKey: oldest)
        }
    }

    func applying(to batch: ARSurfaceRawCaptureBatch) -> ARSurfaceRawCaptureBatch {
        var timestamps: [UUID: TimeInterval] = [:]
        let captures = batch.captures.map { capture -> ARSurfaceRawCapture in
            guard let event = events[capture.anchorID], event.timestamp <= batch.timestamp else {
                return capture
            }
            timestamps[capture.anchorID] = event.timestamp
            if event.change == .removed {
                return ARSurfaceRawCapture(
                    anchorID: capture.anchorID, change: .removed,
                    payload: .removed(anchorID: capture.anchorID, kind: event.kind))
            }
            return capture
        }
        return ARSurfaceRawCaptureBatch(
            captureIdentity: batch.captureIdentity, timestamp: batch.timestamp,
            captures: captures, failures: batch.failures, isAuthoritative: batch.isAuthoritative,
            observedAnchorTimestamps: timestamps)
    }
}

struct ARSurfaceRawCapture: Sendable {
    let anchorID: UUID
    let change: ARSurfaceObservationChange
    let payload: ARSurfaceRawPayload
}

enum ARSurfaceRawPayload: Sendable {
    case plane(ARPlaneObservationSnapshot)
    case mesh(ARMeshRawCapture)
    case removed(anchorID: UUID, kind: ARSurfaceKind)
}

struct ARMeshRawCapture: Sendable {
    let anchorID: UUID
    let transform: Matrix4x4Snapshot
    let vertices: ARGeometryRawSource
    let faces: ARGeometryRawFaces
    let classifications: ARGeometryRawSource?
}

struct ARGeometryRawSource: Sendable {
    let data: Data
    let offset: Int
    let stride: Int
    let count: Int
}

struct ARGeometryRawFaces: Sendable {
    let data: Data
    let faceCount: Int
    let indexCountPerPrimitive: Int
    let bytesPerIndex: Int
}

final class ARSurfaceStateAccumulator: @unchecked Sendable {
    static let maximumAccumulatedVertices = 750_000
    static let maximumAccumulatedFaces = 1_500_000
    static let maximumAccumulatedPlanes = 1_024
    static let maximumAccumulatedMeshes = 128

    private let lock = NSLock()
    private var identity: ARCaptureIdentity?
    private var revision: UInt64 = 0
    private var planes: [UUID: ARPlaneObservationSnapshot] = [:]
    private var meshes: [UUID: ARMeshObservationSnapshot] = [:]
    private var unresolvedFailures: [UUID: ARSurfaceObservationError] = [:]
    private var anchorObservedAt: [UUID: TimeInterval] = [:]
    private var latestBatchTimestamp: TimeInterval?

    func applying(_ observations: [ARSurfaceObservation]) -> ARSurfaceStateSnapshot? {
        guard let first = observations.first else {
            return nil
        }
        return applying(
            ARSurfaceObservationBatch(
                captureIdentity: ARCaptureIdentity(
                    coordinateFrameID: first.coordinateFrameID,
                    segmentID: first.segmentID,
                    mapID: first.mapID,
                    status: first.coordinateFrameStatus
                ),
                timestamp: first.timestamp,
                observations: observations,
                failures: [],
                isAuthoritative: false
            )
        )
    }

    func applying(_ batch: ARSurfaceObservationBatch) -> ARSurfaceStateSnapshot? {
        guard
            batch.isAuthoritative
                || !batch.observations.isEmpty
                || !batch.failures.isEmpty
        else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let incomingIdentity = batch.captureIdentity
        let startsNewIdentity =
            identity?.coordinateFrameID != incomingIdentity.coordinateFrameID
            || identity?.segmentID != incomingIdentity.segmentID
        guard batch.timestamp.isFinite, batch.timestamp >= 0,
            startsNewIdentity || latestBatchTimestamp.map({ batch.timestamp >= $0 }) != false
        else { return nil }
        let baselineObservedAt = startsNewIdentity ? [:] : anchorObservedAt
        var nextObservedAt = baselineObservedAt
        let baselinePlanes: [UUID: ARPlaneObservationSnapshot] =
            startsNewIdentity ? [:] : planes
        let baselineMeshes: [UUID: ARMeshObservationSnapshot] =
            startsNewIdentity ? [:] : meshes
        var nextPlanes = baselinePlanes
        var nextMeshes = baselineMeshes
        var nextFailures: [UUID: ARSurfaceObservationError] =
            startsNewIdentity ? [:] : unresolvedFailures

        for observation in batch.observations {
            let observedAt = batch.observedAnchorTimestamps[observation.anchorID] ?? observation.timestamp
            guard
                observation.coordinateFrameID == incomingIdentity.coordinateFrameID,
                observation.segmentID == incomingIdentity.segmentID,
                observation.mapID == incomingIdentity.mapID,
                observation.coordinateFrameStatus == incomingIdentity.status,
                observation.timestamp.isFinite, observation.timestamp >= 0,
                observation.timestamp <= batch.timestamp,
                observedAt.isFinite, observedAt >= 0, observedAt <= observation.timestamp,
                nextObservedAt[observation.anchorID].map({ observedAt >= $0 }) != false
            else {
                continue
            }
            switch observation.payload {
            case .plane(let plane):
                if batch.observedAnchorTimestamps[plane.anchorID] != nil
                    || !batch.isAuthoritative || nextPlanes[plane.anchorID] != plane
                {
                    nextObservedAt[plane.anchorID] = observedAt
                }
                nextPlanes[plane.anchorID] = plane
                nextFailures.removeValue(forKey: plane.anchorID)
            case .mesh(let mesh):
                if batch.observedAnchorTimestamps[mesh.anchorID] != nil
                    || !batch.isAuthoritative || nextMeshes[mesh.anchorID] != mesh
                {
                    nextObservedAt[mesh.anchorID] = observedAt
                }
                nextMeshes[mesh.anchorID] = mesh
                nextFailures.removeValue(forKey: mesh.anchorID)
            case .removed(let anchorID, let kind):
                switch kind {
                case .plane:
                    nextPlanes.removeValue(forKey: anchorID)
                case .mesh:
                    nextMeshes.removeValue(forKey: anchorID)
                }
                nextFailures.removeValue(forKey: anchorID)
                nextObservedAt.removeValue(forKey: anchorID)
            }
        }

        if batch.isAuthoritative {
            let presentAnchorIDs = Set(batch.observations.map(\.anchorID))
                .union(batch.failures.map(\.anchorID))
            nextPlanes = nextPlanes.filter { presentAnchorIDs.contains($0.key) }
            nextMeshes = nextMeshes.filter { presentAnchorIDs.contains($0.key) }
            nextFailures = nextFailures.filter { presentAnchorIDs.contains($0.key) }
            nextObservedAt = nextObservedAt.filter { presentAnchorIDs.contains($0.key) }
        }

        let capacityError: ARSurfaceObservationError?
        if nextPlanes.count > Self.maximumAccumulatedPlanes
            || nextMeshes.count > Self.maximumAccumulatedMeshes
        {
            capacityError = .accumulatedAnchorLimitExceeded(
                planes: nextPlanes.count,
                meshes: nextMeshes.count
            )
        } else {
            let totalVertices = nextMeshes.values.reduce(into: 0) { count, mesh in
                count += mesh.vertices.count
            }
            let totalFaces = nextMeshes.values.reduce(into: 0) { count, mesh in
                count += mesh.triangleIndices.count / 3
            }
            capacityError =
                totalVertices > Self.maximumAccumulatedVertices
                    || totalFaces > Self.maximumAccumulatedFaces
                ? .accumulatedGeometryLimitExceeded(
                    vertices: totalVertices,
                    faces: totalFaces
                )
                : nil
        }

        if let capacityError {
            nextPlanes = baselinePlanes
            nextMeshes = baselineMeshes
            nextObservedAt = baselineObservedAt
            for observation in batch.observations {
                nextFailures[observation.anchorID] = capacityError
            }
        }
        for failure in batch.failures {
            nextFailures[failure.anchorID] = failure.error
        }

        if startsNewIdentity {
            revision = 0
        }
        identity = incomingIdentity
        planes = nextPlanes
        meshes = nextMeshes
        anchorObservedAt = nextObservedAt
        latestBatchTimestamp = batch.timestamp
        unresolvedFailures = nextFailures
        revision &+= 1
        return ARSurfaceStateSnapshot(
            coordinateFrameID: incomingIdentity.coordinateFrameID,
            segmentID: incomingIdentity.segmentID,
            mapID: incomingIdentity.mapID,
            coordinateFrameStatus: incomingIdentity.status,
            revision: revision,
            timestamp: batch.timestamp,
            planes: planes,
            meshes: meshes,
            unresolvedFailures:
                unresolvedFailures
                .map { ARSurfaceObservationFailure(anchorID: $0.key, error: $0.value) }
                .sorted { $0.anchorID.uuidString < $1.anchorID.uuidString },
            isCurrentSessionData: true,
            anchorObservedAt: anchorObservedAt
        )
    }

    /// Clears accumulated geometry and returns a fail-closed value suitable for
    /// replacing the channel's previously buffered snapshot immediately.
    func invalidated(
        captureIdentity: ARCaptureIdentity,
        timestamp: TimeInterval
    ) -> ARSurfaceStateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        identity = nil
        revision = 0
        planes.removeAll(keepingCapacity: false)
        meshes.removeAll(keepingCapacity: false)
        unresolvedFailures.removeAll(keepingCapacity: false)
        anchorObservedAt.removeAll(keepingCapacity: false)
        latestBatchTimestamp = nil

        return ARSurfaceStateSnapshot(
            coordinateFrameID: captureIdentity.coordinateFrameID,
            segmentID: captureIdentity.segmentID,
            mapID: captureIdentity.mapID,
            coordinateFrameStatus: captureIdentity.status,
            revision: 0,
            timestamp: timestamp,
            planes: [:],
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: false
        )
    }

    func reset() {
        lock.lock()
        identity = nil
        revision = 0
        planes.removeAll(keepingCapacity: false)
        meshes.removeAll(keepingCapacity: false)
        unresolvedFailures.removeAll(keepingCapacity: false)
        anchorObservedAt.removeAll(keepingCapacity: false)
        latestBatchTimestamp = nil
        lock.unlock()
    }
}

extension ARSurfaceObservation {
    fileprivate var anchorID: UUID {
        switch payload {
        case .plane(let plane): plane.anchorID
        case .mesh(let mesh): mesh.anchorID
        case .removed(let anchorID, _): anchorID
        }
    }
}

public struct ARSurfaceObservationAdapter: Sendable {
    public static let maximumVerticesPerAnchor = 250_000
    public static let maximumFacesPerAnchor = 500_000
    public static let maximumVerticesPerUpdate = ARSurfaceStateAccumulator
        .maximumAccumulatedVertices
    public static let maximumFacesPerUpdate = ARSurfaceStateAccumulator
        .maximumAccumulatedFaces
    public static let maximumPlaneBoundaryVertices = 4_096

    public init() {}

    public func makeObservations(
        from anchors: [ARAnchor],
        change: ARSurfaceObservationChange,
        captureIdentity: ARCaptureIdentity,
        timestamp: TimeInterval,
        isAuthoritative: Bool = false
    ) -> ARSurfaceObservationBatch {
        makeObservations(
            from: makeRawCapture(
                from: anchors,
                change: change,
                captureIdentity: captureIdentity,
                timestamp: timestamp,
                isAuthoritative: isAuthoritative
            )
        )
    }

    /// Performs only bounded bulk copies while still on ARKit's delegate
    /// queue. CPU-heavy scalar decoding happens later from app-owned Data.
    func makeRawCapture(
        from anchors: [ARAnchor],
        change: ARSurfaceObservationChange,
        captureIdentity: ARCaptureIdentity,
        timestamp: TimeInterval,
        isAuthoritative: Bool
    ) -> ARSurfaceRawCaptureBatch {
        var updateVertexCount = 0
        var updateFaceCount = 0
        var captures: [ARSurfaceRawCapture] = []
        var failures: [ARSurfaceObservationFailure] = []
        captures.reserveCapacity(anchors.count)

        for anchor in anchors {
            do {
                if change == .removed {
                    let kind: ARSurfaceKind?
                    if anchor is ARPlaneAnchor {
                        kind = .plane
                    } else if anchor is ARMeshAnchor {
                        kind = .mesh
                    } else {
                        kind = nil
                    }
                    guard let kind else {
                        continue
                    }
                    captures.append(
                        ARSurfaceRawCapture(
                            anchorID: anchor.identifier,
                            change: change,
                            payload: .removed(anchorID: anchor.identifier, kind: kind)
                        )
                    )
                    continue
                }

                let payload: ARSurfaceRawPayload
                if let plane = anchor as? ARPlaneAnchor {
                    payload = .plane(try makePlaneSnapshot(from: plane))
                } else if let mesh = anchor as? ARMeshAnchor {
                    let proposedVertexCount = updateVertexCount + mesh.geometry.vertices.count
                    let proposedFaceCount = updateFaceCount + mesh.geometry.faces.count
                    guard
                        proposedVertexCount <= Self.maximumVerticesPerUpdate,
                        proposedFaceCount <= Self.maximumFacesPerUpdate
                    else {
                        throw ARSurfaceObservationError.geometryLimitExceeded(
                            vertices: proposedVertexCount,
                            faces: proposedFaceCount
                        )
                    }
                    payload = .mesh(try makeMeshRawCapture(from: mesh))
                    updateVertexCount = proposedVertexCount
                    updateFaceCount = proposedFaceCount
                } else {
                    continue
                }

                captures.append(
                    ARSurfaceRawCapture(
                        anchorID: anchor.identifier,
                        change: change,
                        payload: payload
                    )
                )
            } catch let error as ARSurfaceObservationError {
                failures.append(
                    ARSurfaceObservationFailure(anchorID: anchor.identifier, error: error)
                )
            } catch {
                failures.append(
                    ARSurfaceObservationFailure(
                        anchorID: anchor.identifier,
                        error: .unexpectedAdapterFailure(message: String(describing: error))
                    )
                )
            }
        }
        return ARSurfaceRawCaptureBatch(
            captureIdentity: captureIdentity,
            timestamp: timestamp,
            captures: captures,
            failures: failures,
            isAuthoritative: isAuthoritative
        )
    }

    func makeObservations(
        from rawBatch: ARSurfaceRawCaptureBatch
    ) -> ARSurfaceObservationBatch {
        var observations: [ARSurfaceObservation] = []
        var failures = rawBatch.failures
        observations.reserveCapacity(rawBatch.captures.count)

        for capture in rawBatch.captures {
            do {
                let payload: ARSurfaceObservationPayload =
                    switch capture.payload {
                    case .plane(let plane): .plane(plane)
                    case .mesh(let mesh): .mesh(try makeMeshSnapshot(from: mesh))
                    case .removed(let anchorID, let kind):
                        .removed(anchorID: anchorID, kind: kind)
                    }
                observations.append(
                    ARSurfaceObservation(
                        coordinateFrameID: rawBatch.captureIdentity.coordinateFrameID,
                        segmentID: rawBatch.captureIdentity.segmentID,
                        mapID: rawBatch.captureIdentity.mapID,
                        coordinateFrameStatus: rawBatch.captureIdentity.status,
                        timestamp: rawBatch.timestamp,
                        change: capture.change,
                        payload: payload
                    )
                )
            } catch let error as ARSurfaceObservationError {
                failures.append(
                    ARSurfaceObservationFailure(anchorID: capture.anchorID, error: error)
                )
            } catch {
                failures.append(
                    ARSurfaceObservationFailure(
                        anchorID: capture.anchorID,
                        error: .unexpectedAdapterFailure(message: String(describing: error))
                    )
                )
            }
        }

        return ARSurfaceObservationBatch(
            captureIdentity: rawBatch.captureIdentity,
            timestamp: rawBatch.timestamp,
            observations: observations,
            failures: failures,
            isAuthoritative: rawBatch.isAuthoritative,
            observedAnchorTimestamps: rawBatch.observedAnchorTimestamps
        )
    }

    private func makePlaneSnapshot(
        from anchor: ARPlaneAnchor
    ) throws -> ARPlaneObservationSnapshot {
        let planeExtent = anchor.planeExtent
        let boundaryVertices = anchor.geometry.boundaryVertices
        guard boundaryVertices.count <= Self.maximumPlaneBoundaryVertices else {
            throw ARSurfaceObservationError.planeBoundaryLimitExceeded(
                boundaryVertices.count
            )
        }
        return ARPlaneObservationSnapshot(
            anchorID: anchor.identifier,
            transform: Matrix4x4Snapshot(anchor.transform),
            center: anchor.center,
            extent: SIMD3<Float>(planeExtent.width, 0, planeExtent.height),
            extentRotationOnYAxis: planeExtent.rotationOnYAxis,
            boundaryVertices: boundaryVertices,
            alignment: planeAlignment(anchor.alignment),
            classification: planeClassification(anchor.classification)
        )
    }

    private func makeMeshRawCapture(from anchor: ARMeshAnchor) throws -> ARMeshRawCapture {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let faceCount = geometry.faces.count
        guard
            vertexCount <= Self.maximumVerticesPerAnchor,
            faceCount <= Self.maximumFacesPerAnchor
        else {
            throw ARSurfaceObservationError.geometryLimitExceeded(
                vertices: vertexCount,
                faces: faceCount
            )
        }

        let vertices = try copyRawSource(
            geometry.vertices,
            elementByteCount: MemoryLayout<Float>.size * 3,
            invalidError: .invalidVertexBuffer
        )
        let faces = try copyRawFaces(geometry.faces)
        let classifications: ARGeometryRawSource?
        if let source = geometry.classification {
            guard source.count == faceCount else {
                throw ARSurfaceObservationError.invalidFaceBuffer
            }
            classifications = try copyRawSource(
                source,
                elementByteCount: 1,
                invalidError: .invalidFaceBuffer
            )
        } else {
            classifications = nil
        }

        return ARMeshRawCapture(
            anchorID: anchor.identifier,
            transform: Matrix4x4Snapshot(anchor.transform),
            vertices: vertices,
            faces: faces,
            classifications: classifications
        )
    }

    private func copyRawSource(
        _ source: ARGeometrySource,
        elementByteCount: Int,
        invalidError: ARSurfaceObservationError
    ) throws -> ARGeometryRawSource {
        guard source.offset >= 0, source.stride >= elementByteCount else {
            throw invalidError
        }
        guard source.count > 0 else {
            return ARGeometryRawSource(data: Data(), offset: 0, stride: source.stride, count: 0)
        }
        let (strideBytes, strideOverflow) = source.stride.multipliedReportingOverflow(
            by: source.count - 1
        )
        let (lastOffset, offsetOverflow) = source.offset.addingReportingOverflow(strideBytes)
        let (requiredBytes, sizeOverflow) = lastOffset.addingReportingOverflow(elementByteCount)
        guard
            !strideOverflow,
            !offsetOverflow,
            !sizeOverflow,
            requiredBytes >= 0,
            requiredBytes <= source.buffer.length
        else {
            throw invalidError
        }
        return ARGeometryRawSource(
            data: Data(bytes: source.buffer.contents(), count: requiredBytes),
            offset: source.offset,
            stride: source.stride,
            count: source.count
        )
    }

    private func copyRawFaces(_ element: ARGeometryElement) throws -> ARGeometryRawFaces {
        guard element.indexCountPerPrimitive == 3 else {
            throw ARSurfaceObservationError.invalidFaceBuffer
        }
        guard element.bytesPerIndex == 2 || element.bytesPerIndex == 4 else {
            throw ARSurfaceObservationError.unsupportedFaceIndexSize(element.bytesPerIndex)
        }
        let (indexCount, indexOverflow) = element.count.multipliedReportingOverflow(
            by: element.indexCountPerPrimitive
        )
        let (requiredBytes, sizeOverflow) = indexCount.multipliedReportingOverflow(
            by: element.bytesPerIndex
        )
        guard
            !indexOverflow,
            !sizeOverflow,
            requiredBytes >= 0,
            requiredBytes <= element.buffer.length
        else {
            throw ARSurfaceObservationError.invalidFaceBuffer
        }
        return ARGeometryRawFaces(
            data: Data(bytes: element.buffer.contents(), count: requiredBytes),
            faceCount: element.count,
            indexCountPerPrimitive: element.indexCountPerPrimitive,
            bytesPerIndex: element.bytesPerIndex
        )
    }

    private func makeMeshSnapshot(
        from raw: ARMeshRawCapture
    ) throws -> ARMeshObservationSnapshot {
        let vertices = try copyVertices(from: raw.vertices)
        let triangleIndices = try copyTriangleIndices(from: raw.faces)
        guard triangleIndices.allSatisfy({ Int($0) < vertices.count }) else {
            throw ARSurfaceObservationError.invalidFaceBuffer
        }
        let classifications = try copyClassifications(
            from: raw.classifications,
            expectedFaceCount: raw.faces.faceCount
        )
        return ARMeshObservationSnapshot(
            anchorID: raw.anchorID,
            transform: raw.transform,
            vertices: vertices,
            triangleIndices: triangleIndices,
            faceClassifications: classifications
        )
    }

    private func copyVertices(
        from source: ARGeometryRawSource
    ) throws -> [SIMD3<Float>] {
        let componentBytes = MemoryLayout<Float>.size
        guard source.count > 0 else {
            return []
        }
        return try source.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw ARSurfaceObservationError.invalidVertexBuffer
            }
            var result = [SIMD3<Float>]()
            result.reserveCapacity(source.count)
            for index in 0..<source.count {
                let byteOffset = source.offset + (source.stride * index)
                guard byteOffset >= 0, byteOffset + (componentBytes * 3) <= rawBuffer.count else {
                    throw ARSurfaceObservationError.invalidVertexBuffer
                }
                let address = baseAddress.advanced(by: byteOffset)
                let x = address.loadUnaligned(as: Float.self)
                let y = address.advanced(by: componentBytes).loadUnaligned(as: Float.self)
                let z = address.advanced(by: componentBytes * 2).loadUnaligned(as: Float.self)
                guard x.isFinite, y.isFinite, z.isFinite else {
                    throw ARSurfaceObservationError.invalidVertexBuffer
                }
                result.append(SIMD3<Float>(x, y, z))
            }
            return result
        }
    }

    private func copyTriangleIndices(
        from element: ARGeometryRawFaces
    ) throws -> [UInt32] {
        let indexCount = element.faceCount * element.indexCountPerPrimitive
        var result = [UInt32]()
        result.reserveCapacity(indexCount)
        try element.data.withUnsafeBytes { rawBuffer in
            guard indexCount == 0 || rawBuffer.baseAddress != nil else {
                throw ARSurfaceObservationError.invalidFaceBuffer
            }
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            for index in 0..<indexCount {
                let address = baseAddress.advanced(by: index * element.bytesPerIndex)
                if element.bytesPerIndex == 2 {
                    result.append(UInt32(address.loadUnaligned(as: UInt16.self)))
                } else {
                    result.append(address.loadUnaligned(as: UInt32.self))
                }
            }
        }
        return result
    }

    private func copyClassifications(
        from source: ARGeometryRawSource?,
        expectedFaceCount: Int
    ) throws -> [ARMeshClassificationSnapshot] {
        guard let source else {
            return []
        }
        guard source.count == expectedFaceCount else {
            throw ARSurfaceObservationError.invalidFaceBuffer
        }

        return try source.data.withUnsafeBytes { rawBuffer in
            guard source.count == 0 || rawBuffer.baseAddress != nil else {
                throw ARSurfaceObservationError.invalidFaceBuffer
            }
            var result = [ARMeshClassificationSnapshot]()
            result.reserveCapacity(source.count)
            guard let baseAddress = rawBuffer.baseAddress else {
                return result
            }
            for index in 0..<source.count {
                let byteOffset = source.offset + (source.stride * index)
                guard byteOffset >= 0, byteOffset + 1 <= rawBuffer.count else {
                    throw ARSurfaceObservationError.invalidFaceBuffer
                }
                let rawValue = baseAddress.advanced(by: byteOffset).load(as: UInt8.self)
                guard let classification = ARMeshClassification(rawValue: Int(rawValue)) else {
                    result.append(.unknown)
                    continue
                }
                result.append(meshClassification(classification))
            }
            return result
        }
    }

    private func planeAlignment(_ value: ARPlaneAnchor.Alignment) -> ARPlaneAlignmentSnapshot {
        switch value {
        case .horizontal: .horizontal
        case .vertical: .vertical
        @unknown default: .unknown
        }
    }

    private func planeClassification(
        _ value: ARPlaneAnchor.Classification
    ) -> ARPlaneClassificationSnapshot {
        switch value {
        case .none: .none
        case .wall: .wall
        case .floor: .floor
        case .ceiling: .ceiling
        case .table: .table
        case .seat: .seat
        case .window: .window
        case .door: .door
        @unknown default: .unknown
        }
    }

    private func meshClassification(
        _ value: ARMeshClassification
    ) -> ARMeshClassificationSnapshot {
        switch value {
        case .none: .none
        case .wall: .wall
        case .floor: .floor
        case .ceiling: .ceiling
        case .table: .table
        case .seat: .seat
        case .window: .window
        case .door: .door
        @unknown default: .unknown
        }
    }
}
