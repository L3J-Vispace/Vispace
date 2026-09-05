import Foundation
import VispaceCore

public enum PlaceCoordinateAlignmentResolutionError: Error, Equatable, Sendable {
    case invalidMapRelationship
    case unresolvedResolutionCarriesAlignment
    case identityResolutionCarriesValidatedAlignment
    case invalidIdentityEvidence
    case missingValidatedAlignment
    case alignmentFrameDirectionMismatch
    case alignmentEvidenceMismatch
}

/// A coordinate-compatibility decision and the validation artifact that
/// justifies it. A cross-frame `.aligned` result can never exist without the
/// exact high-confidence estimator result from which its transform and
/// confidence were copied.
public struct PlaceCoordinateAlignmentResolution: Hashable, Sendable {
    public let sourceMapID: MapID?
    public let targetMapID: MapID
    public let sourceCoordinateFrameID: CoordinateFrameID
    public let targetCoordinateFrameID: CoordinateFrameID
    public let evidence: PlaceCoordinateCompatibilityEvidence
    public let validatedAlignment: CoordinateFrameAlignmentResult?

    public init(
        sourceMapID: MapID?,
        targetMapID: MapID,
        sourceCoordinateFrameID: CoordinateFrameID,
        targetCoordinateFrameID: CoordinateFrameID,
        evidence: PlaceCoordinateCompatibilityEvidence,
        validatedAlignment: CoordinateFrameAlignmentResult?
    ) throws {
        switch evidence {
        case .unresolved, .incompatible:
            guard validatedAlignment == nil else {
                throw PlaceCoordinateAlignmentResolutionError
                    .unresolvedResolutionCarriesAlignment
            }

        case .aligned(let sourceToCandidate, let confidence):
            guard let sourceMapID, sourceMapID != targetMapID else {
                throw PlaceCoordinateAlignmentResolutionError.invalidMapRelationship
            }

            if sourceCoordinateFrameID == targetCoordinateFrameID {
                guard validatedAlignment == nil else {
                    throw PlaceCoordinateAlignmentResolutionError
                        .identityResolutionCarriesValidatedAlignment
                }
                guard sourceToCandidate == .identity, confidence == .one else {
                    throw PlaceCoordinateAlignmentResolutionError.invalidIdentityEvidence
                }
            } else {
                guard let validatedAlignment else {
                    throw PlaceCoordinateAlignmentResolutionError.missingValidatedAlignment
                }
                guard
                    validatedAlignment.sourceCoordinateFrameID
                        == sourceCoordinateFrameID,
                    validatedAlignment.targetCoordinateFrameID
                        == targetCoordinateFrameID
                else {
                    throw PlaceCoordinateAlignmentResolutionError
                        .alignmentFrameDirectionMismatch
                }
                guard validatedAlignment.sourceToTarget == sourceToCandidate,
                    validatedAlignment.confidence == confidence
                else {
                    throw PlaceCoordinateAlignmentResolutionError.alignmentEvidenceMismatch
                }
            }
        }

        self.sourceMapID = sourceMapID
        self.targetMapID = targetMapID
        self.sourceCoordinateFrameID = sourceCoordinateFrameID
        self.targetCoordinateFrameID = targetCoordinateFrameID
        self.evidence = evidence
        self.validatedAlignment = validatedAlignment
    }
}

/// Resolves whether coordinates from the active capture can be related to a
/// persisted candidate map. It never searches for approximate object pairings:
/// only unique, confirmed, high-confidence semantic identities admitted by
/// `SemanticObjectCorrespondenceBuilder` may reach the estimator.
public struct PlaceCoordinateAlignmentResolver: Sendable {
    public let correspondenceBuilder: SemanticObjectCorrespondenceBuilder
    public let estimator: CoordinateFrameAlignmentEstimator

    public init(
        correspondenceBuilder: SemanticObjectCorrespondenceBuilder = .init(),
        estimator: CoordinateFrameAlignmentEstimator = .init()
    ) {
        self.correspondenceBuilder = correspondenceBuilder
        self.estimator = estimator
    }

    public func resolve(
        current snapshot: ARSurfaceStateSnapshot,
        candidate: PlaceFingerprintRecord,
        objects: [SpatialObjectMetadata]
    ) -> PlaceCoordinateAlignmentResolution {
        let unresolved = unresolvedResolution(snapshot: snapshot, candidate: candidate)

        guard snapshot.isComplete,
            let sourceMapID = snapshot.mapID,
            sourceMapID != candidate.mapID
        else {
            return unresolved
        }

        if snapshot.coordinateFrameID == candidate.coordinateFrameID {
            return try! PlaceCoordinateAlignmentResolution(
                sourceMapID: sourceMapID,
                targetMapID: candidate.mapID,
                sourceCoordinateFrameID: snapshot.coordinateFrameID,
                targetCoordinateFrameID: candidate.coordinateFrameID,
                evidence: .aligned(sourceToCandidate: .identity, confidence: .one),
                validatedAlignment: nil
            )
        }

        do {
            // `SpatialObjectMetadata` does not currently retain the capture
            // segment in which presence was observed, so exact source-segment
            // freshness cannot yet be proven here. Requiring `.visible` for
            // source landmarks is the conservative available proxy. Target
            // landmarks are durable historical evidence and remain eligible
            // while the builder's confirmed/non-removed checks admit them.
            let alignmentObjects = objects.filter { metadata in
                guard metadata.mapID == sourceMapID,
                    metadata.position.coordinateFrameID
                        == snapshot.coordinateFrameID
                else {
                    return true
                }
                return metadata.object.presence == .visible
            }
            let correspondences = try correspondenceBuilder.build(
                source: SemanticObjectCorrespondenceEndpoint(
                    mapID: sourceMapID,
                    coordinateFrameID: snapshot.coordinateFrameID
                ),
                target: SemanticObjectCorrespondenceEndpoint(
                    mapID: candidate.mapID,
                    coordinateFrameID: candidate.coordinateFrameID
                ),
                from: alignmentObjects
            )
            let alignment = try estimator.estimate(correspondences: correspondences)
            return try PlaceCoordinateAlignmentResolution(
                sourceMapID: sourceMapID,
                targetMapID: candidate.mapID,
                sourceCoordinateFrameID: snapshot.coordinateFrameID,
                targetCoordinateFrameID: candidate.coordinateFrameID,
                evidence: .aligned(
                    sourceToCandidate: alignment.sourceToTarget,
                    confidence: alignment.confidence
                ),
                validatedAlignment: alignment
            )
        } catch {
            // Insufficient, ambiguous, degenerate, low-confidence, or
            // high-residual evidence is deliberately indistinguishable from
            // unresolved compatibility at this boundary. No transform is
            // guessed or persisted.
            return unresolved
        }
    }

    private func unresolvedResolution(
        snapshot: ARSurfaceStateSnapshot,
        candidate: PlaceFingerprintRecord
    ) -> PlaceCoordinateAlignmentResolution {
        try! PlaceCoordinateAlignmentResolution(
            sourceMapID: snapshot.mapID,
            targetMapID: candidate.mapID,
            sourceCoordinateFrameID: snapshot.coordinateFrameID,
            targetCoordinateFrameID: candidate.coordinateFrameID,
            evidence: .unresolved,
            validatedAlignment: nil
        )
    }
}
