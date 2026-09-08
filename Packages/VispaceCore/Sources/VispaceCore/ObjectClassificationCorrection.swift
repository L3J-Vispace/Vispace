import Foundation

/// An explicit user correction, separate from detector label fluctuations.
/// The expected revision binds the action to the record the user reviewed.
public struct ObjectClassificationCorrection: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let expectedSemanticLabel: String
    public let expectedTemporalRevision: UInt64?
    public let semanticLabel: String
    public let displayName: String?

    public init(
        objectID: ObjectID, expectedSemanticLabel: String,
        expectedTemporalRevision: UInt64?, semanticLabel: String,
        displayName: String?
    ) throws {
        let normalized = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.count <= 64,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            normalized.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        else { throw SpatialObjectError.emptySemanticLabel }
        self.objectID = objectID
        self.expectedSemanticLabel = expectedSemanticLabel
        self.expectedTemporalRevision = expectedTemporalRevision
        self.semanticLabel = normalized
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case objectID, expectedSemanticLabel, expectedTemporalRevision, semanticLabel, displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            objectID: c.decode(ObjectID.self, forKey: .objectID),
            expectedSemanticLabel: c.decode(String.self, forKey: .expectedSemanticLabel),
            expectedTemporalRevision: c.decodeIfPresent(UInt64.self, forKey: .expectedTemporalRevision),
            semanticLabel: c.decode(String.self, forKey: .semanticLabel),
            displayName: c.decodeIfPresent(String.self, forKey: .displayName))
    }
}
