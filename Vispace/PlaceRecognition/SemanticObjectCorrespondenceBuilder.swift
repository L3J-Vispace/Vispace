import Foundation
import VispaceCore

public enum SemanticObjectCorrespondenceBuilderError: Error, Equatable, Sendable {
    case sameMap(MapID)
    case sameCoordinateFrame(CoordinateFrameID)
    case insufficientCorrespondences(minimum: Int, actual: Int)
}

/// Identifies the exact persisted map and coordinate frame from which
/// semantic alignment landmarks may be selected.
public struct SemanticObjectCorrespondenceEndpoint: Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID

    public init(mapID: MapID, coordinateFrameID: CoordinateFrameID) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
    }
}

/// Builds explicit cross-frame identity evidence from persisted objects.
///
/// This component deliberately does not estimate a transform. A label is
/// usable only when it identifies exactly one eligible object in each frame;
/// repeated labels such as multiple chairs are excluded instead of guessed.
public struct SemanticObjectCorrespondenceBuilder: Sendable {
    public static let minimumCorrespondenceCount = 3
    public static let maximumCorrespondenceCount = 64

    public let confidencePolicy: ConfidencePolicy

    public init(confidencePolicy: ConfidencePolicy = .default) {
        self.confidencePolicy = confidencePolicy
    }

    public func build(
        source: SemanticObjectCorrespondenceEndpoint,
        target: SemanticObjectCorrespondenceEndpoint,
        from objects: [SpatialObjectMetadata]
    ) throws -> [CoordinateFrameAlignmentCorrespondence] {
        guard source.mapID != target.mapID else {
            throw SemanticObjectCorrespondenceBuilderError.sameMap(source.mapID)
        }
        guard source.coordinateFrameID != target.coordinateFrameID else {
            throw SemanticObjectCorrespondenceBuilderError.sameCoordinateFrame(
                source.coordinateFrameID
            )
        }

        let sourceObjects = eligibleObjects(for: source, from: objects)
        let targetObjects = eligibleObjects(for: target, from: objects)
        let sourceByLabel = objectsByNormalizedLabel(sourceObjects)
        let targetByLabel = objectsByNormalizedLabel(targetObjects)

        let uniqueSharedLabels = sourceByLabel.keys
            .filter { label in
                sourceByLabel[label]?.count == 1 && targetByLabel[label]?.count == 1
            }
            .sorted()
            .prefix(Self.maximumCorrespondenceCount)

        let correspondences = try uniqueSharedLabels.map { label in
            // The cardinality checks above make these lookups total. Keeping
            // the optional binding local avoids any force unwrap at this
            // persistence boundary if this implementation changes later.
            guard let sourceObject = sourceByLabel[label]?.first,
                let targetObject = targetByLabel[label]?.first
            else {
                throw
                    SemanticObjectCorrespondenceBuilderError
                    .insufficientCorrespondences(
                        minimum: Self.minimumCorrespondenceCount,
                        actual: 0
                    )
            }

            return try CoordinateFrameAlignmentCorrespondence(
                source: CoordinateFrameAlignmentSourcePoint(
                    objectID: sourceObject.object.id,
                    coordinateFrameID: sourceObject.position.coordinateFrameID,
                    semanticLabel: label,
                    position: sourceObject.position.value
                ),
                target: CoordinateFrameAlignmentTargetPoint(
                    objectID: targetObject.object.id,
                    coordinateFrameID: targetObject.position.coordinateFrameID,
                    semanticLabel: label,
                    position: targetObject.position.value
                ),
                identityConfidence: conservativeIdentityConfidence(
                    sourceObject.object,
                    targetObject.object
                )
            )
        }

        guard correspondences.count >= Self.minimumCorrespondenceCount else {
            throw SemanticObjectCorrespondenceBuilderError.insufficientCorrespondences(
                minimum: Self.minimumCorrespondenceCount,
                actual: correspondences.count
            )
        }
        return correspondences
    }

    private func eligibleObjects(
        for endpoint: SemanticObjectCorrespondenceEndpoint,
        from objects: [SpatialObjectMetadata]
    ) -> [SpatialObjectMetadata] {
        objects.filter { metadata in
            metadata.mapID == endpoint.mapID
                && metadata.position.coordinateFrameID == endpoint.coordinateFrameID
                && metadata.object.certainty == .confirmed
                && metadata.object.presence != .removed
                && confidencePolicy.grade(for: metadata.object.confidence.semantic) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.geometry) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.identity) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.objectState) == .high
        }
    }

    private func objectsByNormalizedLabel(
        _ objects: [SpatialObjectMetadata]
    ) -> [String: [SpatialObjectMetadata]] {
        Dictionary(grouping: objects, by: { normalizedLabel($0.object.semanticLabel) })
    }

    private func normalizedLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func conservativeIdentityConfidence(
        _ source: SpatialObject,
        _ target: SpatialObject
    ) -> ConfidenceScore {
        [
            source.confidence.semantic,
            source.confidence.geometry,
            source.confidence.identity,
            source.confidence.objectState,
            target.confidence.semantic,
            target.confidence.geometry,
            target.confidence.identity,
            target.confidence.objectState,
        ].min() ?? .zero
    }
}
