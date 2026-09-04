import Foundation

public enum SpatialReducerError: Error, Equatable, Sendable {
    case revisionConflict(expected: UInt64, actualBase: UInt64)
    case objectNotFound(ObjectID)
    case insufficientConfidence(ObjectID)
    case cannotDowngradeConfirmedObject(ObjectID)
    case invalidStateTransition(ObjectID)
    case outOfOrderEvent(ObjectID)
    case movementOriginMismatch(ObjectID)
    case invalidTimestamp
    case invalidMovementTolerance
    case snapshotCertaintyMismatch(ObjectID)
    case duplicateSnapshotObject(ObjectID)
    case invalidConfirmedSnapshotConfidence(ObjectID)
}

public enum DeltaApplicationResult: Equatable, Sendable {
    case applied(newRevision: UInt64)
    case alreadyApplied(currentRevision: UInt64)
}

public struct SpatialSnapshot: Codable, Hashable, Sendable {
    public fileprivate(set) var revision: UInt64
    public fileprivate(set) var confirmedObjects: [ObjectID: SpatialObject]
    public fileprivate(set) var provisionalObjects: [ObjectID: SpatialObject]
    public fileprivate(set) var eventHistory: [ObjectEvent]
    public fileprivate(set) var appliedDeltaIDs: Set<SpatialDeltaID>

    public init() {
        revision = 0
        confirmedObjects = [:]
        provisionalObjects = [:]
        eventHistory = []
        appliedDeltaIDs = []
    }

    public init(
        validatingRevision revision: UInt64,
        confirmedObjects: [ObjectID: SpatialObject],
        provisionalObjects: [ObjectID: SpatialObject],
        eventHistory: [ObjectEvent],
        appliedDeltaIDs: Set<SpatialDeltaID>
    ) throws {
        for (id, object) in confirmedObjects where object.certainty != .confirmed {
            throw SpatialReducerError.snapshotCertaintyMismatch(id)
        }
        for (id, object) in provisionalObjects where object.certainty != .provisional {
            throw SpatialReducerError.snapshotCertaintyMismatch(id)
        }
        if let duplicate = Set(confirmedObjects.keys)
            .intersection(provisionalObjects.keys)
            .sorted()
            .first
        {
            throw SpatialReducerError.duplicateSnapshotObject(duplicate)
        }
        self.revision = revision
        self.confirmedObjects = confirmedObjects
        self.provisionalObjects = provisionalObjects
        self.eventHistory = eventHistory
        self.appliedDeltaIDs = appliedDeltaIDs
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case confirmedObjects
        case provisionalObjects
        case eventHistory
        case appliedDeltaIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                validatingRevision: container.decode(UInt64.self, forKey: .revision),
                confirmedObjects: container.decode(
                    [ObjectID: SpatialObject].self,
                    forKey: .confirmedObjects
                ),
                provisionalObjects: container.decode(
                    [ObjectID: SpatialObject].self,
                    forKey: .provisionalObjects
                ),
                eventHistory: container.decode([ObjectEvent].self, forKey: .eventHistory),
                appliedDeltaIDs: container.decode(
                    Set<SpatialDeltaID>.self,
                    forKey: .appliedDeltaIDs
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmedObjects,
                in: container,
                debugDescription: "Snapshot certainty partitions are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(confirmedObjects, forKey: .confirmedObjects)
        try container.encode(provisionalObjects, forKey: .provisionalObjects)
        try container.encode(eventHistory, forKey: .eventHistory)
        try container.encode(appliedDeltaIDs, forKey: .appliedDeltaIDs)
    }
}

/// Reduces versioned deltas atomically. Confirmed and provisional objects are
/// physically separated, preventing medium/low-confidence evidence from
/// leaking into the confirmed spatial view.
public struct SpatialDeltaReducer: Sendable {
    public private(set) var snapshot: SpatialSnapshot
    public let confidencePolicy: ConfidencePolicy
    public let movementOriginTolerance: Double

    public init() {
        snapshot = SpatialSnapshot()
        confidencePolicy = .default
        movementOriginTolerance = 0.05
    }

    public init(
        validating snapshot: SpatialSnapshot,
        confidencePolicy: ConfidencePolicy = .default,
        movementOriginTolerance: Double = 0.05
    ) throws {
        guard movementOriginTolerance.isFinite, movementOriginTolerance >= 0 else {
            throw SpatialReducerError.invalidMovementTolerance
        }
        for (id, object) in snapshot.confirmedObjects {
            guard confidencePolicy.grade(for: object.confidence.identity) == .high,
                confidencePolicy.grade(for: object.confidence.objectState) == .high
            else {
                throw SpatialReducerError.invalidConfirmedSnapshotConfidence(id)
            }
        }
        self.snapshot = snapshot
        self.confidencePolicy = confidencePolicy
        self.movementOriginTolerance = movementOriginTolerance
    }

    @discardableResult
    public mutating func apply(_ delta: SpatialDelta) throws -> DeltaApplicationResult {
        if snapshot.appliedDeltaIDs.contains(delta.id) {
            return .alreadyApplied(currentRevision: snapshot.revision)
        }
        guard delta.baseRevision == snapshot.revision else {
            throw SpatialReducerError.revisionConflict(
                expected: snapshot.revision,
                actualBase: delta.baseRevision
            )
        }

        var working = snapshot
        for event in delta.events {
            try apply(event, to: &working)
            working.eventHistory.append(event)
        }
        working.revision += 1
        working.appliedDeltaIDs.insert(delta.id)
        snapshot = working
        return .applied(newRevision: working.revision)
    }

    private func apply(_ event: ObjectEvent, to state: inout SpatialSnapshot) throws {
        switch event {
        case .upsert(let object):
            try upsert(object, into: &state)

        case .observed(let objectID, let at, let position, let bounds, let confidence):
            try validateTimestamp(at)
            if var object = state.confirmedObjects[objectID] {
                guard confidencePolicy.grade(for: confidence.identity) == .high,
                    confidencePolicy.grade(for: confidence.objectState) == .high
                else {
                    throw SpatialReducerError.insufficientConfidence(objectID)
                }
                try validateMutable(object, eventTime: at)
                object.position = position
                object.bounds = bounds
                object.presence = .visible
                object.lastSeenAt = at
                object.stateUpdatedAt = at
                object.confidence = confidence
                state.confirmedObjects[objectID] = object
            } else if var object = state.provisionalObjects[objectID] {
                try validateMutable(object, eventTime: at)
                object.position = position
                object.bounds = bounds
                object.presence = .visible
                object.lastSeenAt = at
                object.stateUpdatedAt = at
                object.confidence = confidence
                state.provisionalObjects[objectID] = object
            } else {
                throw SpatialReducerError.objectNotFound(objectID)
            }

        case .becameNotVisible(let objectID, let at):
            try mutateExisting(objectID, state: &state, at: at) { object in
                guard object.presence == .visible || object.presence == .notVisible else {
                    throw SpatialReducerError.invalidStateTransition(objectID)
                }
                object.presence = .notVisible
            }

        case .becameLastSeen(let objectID, let at):
            try mutateExisting(objectID, state: &state, at: at) { object in
                guard object.presence == .notVisible || object.presence == .lastSeen else {
                    throw SpatialReducerError.invalidStateTransition(objectID)
                }
                object.presence = .lastSeen
            }

        case .moved(let objectID, let from, let to, let at, let confidence):
            try validateTimestamp(at)
            guard var object = state.confirmedObjects[objectID] else {
                throw SpatialReducerError.objectNotFound(objectID)
            }
            try validateMutable(object, eventTime: at)
            guard confidencePolicy.grade(for: confidence) == .high else {
                throw SpatialReducerError.insufficientConfidence(objectID)
            }
            guard object.position.distance(to: from) <= movementOriginTolerance else {
                throw SpatialReducerError.movementOriginMismatch(objectID)
            }
            object.position = to
            object.presence = .visible
            object.lastSeenAt = at
            object.stateUpdatedAt = at
            object.confidence.objectState = confidence
            state.confirmedObjects[objectID] = object

        case .removed(let objectID, let at, let confidence):
            try validateTimestamp(at)
            guard var object = state.confirmedObjects[objectID] else {
                throw SpatialReducerError.objectNotFound(objectID)
            }
            try validateMutable(object, eventTime: at)
            guard confidencePolicy.grade(for: confidence) == .high else {
                throw SpatialReducerError.insufficientConfidence(objectID)
            }
            object.presence = .removed
            object.stateUpdatedAt = at
            object.confidence.objectState = confidence
            state.confirmedObjects[objectID] = object

        case .discardProvisional(let objectID):
            guard state.provisionalObjects.removeValue(forKey: objectID) != nil else {
                throw SpatialReducerError.objectNotFound(objectID)
            }
        }
    }

    private func upsert(_ object: SpatialObject, into state: inout SpatialSnapshot) throws {
        switch object.certainty {
        case .provisional:
            guard state.confirmedObjects[object.id] == nil else {
                throw SpatialReducerError.cannotDowngradeConfirmedObject(object.id)
            }
            if let existing = state.provisionalObjects[object.id],
                object.stateUpdatedAt < existing.stateUpdatedAt
            {
                throw SpatialReducerError.outOfOrderEvent(object.id)
            }
            state.provisionalObjects[object.id] = object

        case .confirmed:
            guard confidencePolicy.grade(for: object.confidence.identity) == .high,
                confidencePolicy.grade(for: object.confidence.objectState) == .high
            else {
                throw SpatialReducerError.insufficientConfidence(object.id)
            }
            let existingTimestamp =
                state.confirmedObjects[object.id]?.stateUpdatedAt
                ?? state.provisionalObjects[object.id]?.stateUpdatedAt
            if let existingTimestamp, object.stateUpdatedAt < existingTimestamp {
                throw SpatialReducerError.outOfOrderEvent(object.id)
            }
            state.provisionalObjects.removeValue(forKey: object.id)
            state.confirmedObjects[object.id] = object
        }
    }

    private func mutateExisting(
        _ objectID: ObjectID,
        state: inout SpatialSnapshot,
        at time: TimeInterval,
        mutation: (inout SpatialObject) throws -> Void
    ) throws {
        try validateTimestamp(time)
        if var object = state.confirmedObjects[objectID] {
            try validateMutable(object, eventTime: time)
            try mutation(&object)
            object.stateUpdatedAt = time
            state.confirmedObjects[objectID] = object
            return
        }
        if var object = state.provisionalObjects[objectID] {
            try validateMutable(object, eventTime: time)
            try mutation(&object)
            object.stateUpdatedAt = time
            state.provisionalObjects[objectID] = object
            return
        }
        throw SpatialReducerError.objectNotFound(objectID)
    }

    private func validateMutable(_ object: SpatialObject, eventTime: TimeInterval) throws {
        guard object.presence != .removed else {
            throw SpatialReducerError.invalidStateTransition(object.id)
        }
        guard eventTime >= object.stateUpdatedAt else {
            throw SpatialReducerError.outOfOrderEvent(object.id)
        }
    }

    private func validateTimestamp(_ value: TimeInterval) throws {
        guard value.isFinite, value >= 0 else {
            throw SpatialReducerError.invalidTimestamp
        }
    }
}
