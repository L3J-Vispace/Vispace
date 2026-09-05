import Foundation

public enum PlaceMapAssociationError: Error, Equatable, Sendable {
    case invalidPolicy
    case revisionConflict(expected: UInt64, actualBase: UInt64)
    case outOfOrderObservation(previous: UInt64, incoming: UInt64)
    case duplicateCandidate(MapID)
    case tooManyCandidates(maximum: Int)
    case candidateCoordinateFrameConflict(mapID: MapID)
    case sourceMapCoordinateFrameConflict(mapID: MapID)
    case compatibilityConflict(mapID: MapID)
    case observationIdentifierCollision(ObservationID)
    case revisionOverflow
    case observationCounterOverflow
}

/// The fixed coordinate provenance for one place-association attempt.
///
/// A reducer instance is intentionally scoped to one source coordinate frame.
/// Callers start a new reducer when AR tracking establishes a new frame.
public struct PlaceAssociationContext: Codable, Hashable, Sendable {
    public let sourceMapID: MapID?
    public let sourceCoordinateFrameID: CoordinateFrameID

    public init(sourceMapID: MapID?, sourceCoordinateFrameID: CoordinateFrameID) {
        self.sourceMapID = sourceMapID
        self.sourceCoordinateFrameID = sourceCoordinateFrameID
    }
}

/// Evidence supplied by an upstream map-alignment subsystem. This type does
/// not estimate an alignment; it only carries a validated result into the
/// deterministic decision layer.
public enum PlaceCoordinateCompatibilityEvidence: Codable, Hashable, Sendable {
    case unresolved
    case aligned(sourceToCandidate: Transform3D, confidence: ConfidenceScore)
    case incompatible(confidence: ConfidenceScore)
}

/// Once a high-confidence compatibility result is accepted it is never
/// replaced by later evidence. This prevents coordinates from silently moving
/// between frames during one association attempt.
public enum PlaceCoordinateCompatibilityLatch: Codable, Hashable, Sendable {
    case unresolved
    case compatible(sourceToCandidate: Transform3D, confidence: ConfidenceScore)
    case incompatible(confidence: ConfidenceScore)
}

public struct PlaceMapCandidateEvidence: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let placeEvidence: PlaceEvidence
    public let coordinateCompatibility: PlaceCoordinateCompatibilityEvidence

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        placeEvidence: PlaceEvidence,
        coordinateCompatibility: PlaceCoordinateCompatibilityEvidence = .unresolved
    ) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.placeEvidence = placeEvidence
        self.coordinateCompatibility = coordinateCompatibility
    }
}

/// One completed recognition pass. An empty candidate list is meaningful
/// negative evidence and allows the reducer to reach `.new` after repetition.
public struct PlaceAssociationObservation: Codable, Hashable, Sendable {
    public let id: ObservationID
    public let baseRevision: UInt64
    public let sequence: UInt64
    public let candidates: [PlaceMapCandidateEvidence]

    public init(
        id: ObservationID,
        baseRevision: UInt64,
        sequence: UInt64,
        candidates: [PlaceMapCandidateEvidence]
    ) {
        self.id = id
        self.baseRevision = baseRevision
        self.sequence = sequence
        self.candidates = candidates
    }
}

public struct PlaceAssociationPolicy: Hashable, Sendable {
    public let recognitionPolicy: PlaceRecognitionPolicy
    public let confidencePolicy: ConfidencePolicy
    public let ambiguityMargin: ConfidenceScore
    public let minimumNewPlaceConfidence: ConfidenceScore
    public let minimumObservationsForAssociation: UInt
    public let minimumObservationsForNewPlace: UInt
    public let minimumObservationsForMerge: UInt
    public let minimumModalitiesForAssociation: Int
    public let minimumHighModalitiesForMerge: Int
    public let maximumEvidencePerCandidate: Int
    public let maximumTrackedCandidates: Int
    public let maximumEvidenceSequenceAge: UInt64
    public let maximumRememberedObservations: Int

    public init(
        recognitionPolicy: PlaceRecognitionPolicy = .default,
        confidencePolicy: ConfidencePolicy = .default,
        ambiguityMargin: ConfidenceScore = ConfidenceScore(clamping: 0.10),
        minimumNewPlaceConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.80),
        minimumObservationsForAssociation: UInt = 2,
        minimumObservationsForNewPlace: UInt = 2,
        minimumObservationsForMerge: UInt = 3,
        minimumModalitiesForAssociation: Int = 2,
        minimumHighModalitiesForMerge: Int = 3,
        maximumEvidencePerCandidate: Int = 8,
        maximumTrackedCandidates: Int = 12,
        maximumEvidenceSequenceAge: UInt64 = 24,
        maximumRememberedObservations: Int = 64
    ) throws {
        let modalityCount = 6
        let maximumAllowedEvidencePerCandidate = 256
        let maximumAllowedTrackedCandidates = 128
        let maximumAllowedRememberedObservations = 1_024
        guard minimumObservationsForAssociation > 0,
            minimumObservationsForNewPlace > 0,
            minimumObservationsForMerge >= minimumObservationsForAssociation,
            minimumModalitiesForAssociation >= 2,
            minimumModalitiesForAssociation <= modalityCount,
            minimumHighModalitiesForMerge >= minimumModalitiesForAssociation,
            minimumHighModalitiesForMerge <= modalityCount,
            maximumEvidencePerCandidate > 0,
            maximumEvidencePerCandidate <= maximumAllowedEvidencePerCandidate,
            maximumTrackedCandidates > 0,
            maximumTrackedCandidates <= maximumAllowedTrackedCandidates,
            maximumEvidenceSequenceAge > 0,
            maximumRememberedObservations > 0,
            maximumRememberedObservations <= maximumAllowedRememberedObservations,
            minimumObservationsForAssociation <= UInt(maximumEvidencePerCandidate),
            minimumObservationsForNewPlace <= UInt(maximumEvidencePerCandidate),
            minimumObservationsForMerge <= UInt(maximumEvidencePerCandidate),
            confidencePolicy.grade(for: minimumNewPlaceConfidence) == .high
        else {
            throw PlaceMapAssociationError.invalidPolicy
        }

        self.recognitionPolicy = recognitionPolicy
        self.confidencePolicy = confidencePolicy
        self.ambiguityMargin = ambiguityMargin
        self.minimumNewPlaceConfidence = minimumNewPlaceConfidence
        self.minimumObservationsForAssociation = minimumObservationsForAssociation
        self.minimumObservationsForNewPlace = minimumObservationsForNewPlace
        self.minimumObservationsForMerge = minimumObservationsForMerge
        self.minimumModalitiesForAssociation = minimumModalitiesForAssociation
        self.minimumHighModalitiesForMerge = minimumHighModalitiesForMerge
        self.maximumEvidencePerCandidate = maximumEvidencePerCandidate
        self.maximumTrackedCandidates = maximumTrackedCandidates
        self.maximumEvidenceSequenceAge = maximumEvidenceSequenceAge
        self.maximumRememberedObservations = maximumRememberedObservations
    }

    public static let `default` = try! Self()
}

public struct PlaceCandidateEvidenceSample: Codable, Hashable, Sendable {
    public let observationID: ObservationID
    public let sequence: UInt64
    public let evidence: PlaceEvidence

    public init(observationID: ObservationID, sequence: UInt64, evidence: PlaceEvidence) {
        self.observationID = observationID
        self.sequence = sequence
        self.evidence = evidence
    }
}

public struct PlaceAssociationCandidateState: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public fileprivate(set) var compatibility: PlaceCoordinateCompatibilityLatch
    public fileprivate(set) var evidence: [PlaceCandidateEvidenceSample]
    public fileprivate(set) var lastObservedSequence: UInt64

    fileprivate init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        compatibility: PlaceCoordinateCompatibilityLatch = .unresolved,
        evidence: [PlaceCandidateEvidenceSample] = [],
        lastObservedSequence: UInt64
    ) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.compatibility = compatibility
        self.evidence = evidence
        self.lastObservedSequence = lastObservedSequence
    }
}

public struct PlaceAssociationCandidateEvaluation: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let compatibility: PlaceCoordinateCompatibilityLatch
    public let evidenceCount: UInt
    public let aggregateEvidence: PlaceEvidence
    public let recognition: PlaceRecognitionResult
    /// Modalities whose aggregate grade is at least medium.
    public let supportingModalityCount: Int
    /// Modalities whose aggregate grade is high.
    public let highModalityCount: Int

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        compatibility: PlaceCoordinateCompatibilityLatch,
        evidenceCount: UInt,
        aggregateEvidence: PlaceEvidence,
        recognition: PlaceRecognitionResult,
        supportingModalityCount: Int,
        highModalityCount: Int
    ) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.compatibility = compatibility
        self.evidenceCount = evidenceCount
        self.aggregateEvidence = aggregateEvidence
        self.recognition = recognition
        self.supportingModalityCount = supportingModalityCount
        self.highModalityCount = highModalityCount
    }
}

public enum PlaceAssociationOutcome: String, Codable, Hashable, Sendable {
    case known
    case overlapping
    case new
    case ambiguous
}

/// A command proposal, not an implementation of visual relocalization or map
/// fusion. The app integration layer must execute and independently verify it.
public enum PlaceMapMutationDecision: Codable, Hashable, Sendable {
    case associateExisting(targetMapID: MapID)
    case mergeMaps(
        sourceMapID: MapID,
        targetMapID: MapID,
        sourceToTarget: Transform3D
    )
    case createNewMap
    case deferDecision
}

public enum PlaceAssociationDecisionReason: String, Codable, Hashable, Sendable {
    case recognizedKnownPlace
    case recognizedPartialOverlap
    case noCandidateMatch
    case insufficientRepeatedEvidence
    case insufficientIndependentModalities
    case insufficientNoMatchConfidence
    case coordinateCompatibilityUnresolved
    case competingCandidates
}

public struct PlaceAssociationDecision: Codable, Hashable, Sendable {
    public let outcome: PlaceAssociationOutcome
    public let mutation: PlaceMapMutationDecision
    public let selectedMapID: MapID?
    public let candidateMapIDs: [MapID]
    /// For known/overlapping/ambiguous this is the leading match score. For a
    /// new place it is confidence in the absence of a match.
    public let confidence: ConfidenceScore
    public let grade: ConfidenceGrade
    public let reason: PlaceAssociationDecisionReason

    public init(
        outcome: PlaceAssociationOutcome,
        mutation: PlaceMapMutationDecision,
        selectedMapID: MapID?,
        candidateMapIDs: [MapID],
        confidence: ConfidenceScore,
        grade: ConfidenceGrade,
        reason: PlaceAssociationDecisionReason
    ) {
        self.outcome = outcome
        self.mutation = mutation
        self.selectedMapID = selectedMapID
        self.candidateMapIDs = candidateMapIDs
        self.confidence = confidence
        self.grade = grade
        self.reason = reason
    }
}

public struct PlaceAssociationSnapshot: Equatable, Sendable {
    public fileprivate(set) var revision: UInt64
    public fileprivate(set) var latestSequence: UInt64?
    public fileprivate(set) var completedObservationCount: UInt64
    public fileprivate(set) var candidates: [MapID: PlaceAssociationCandidateState]
    public fileprivate(set) var latestObservedCandidateIDs: Set<MapID>
    public fileprivate(set) var latestAbsenceConfidence: ConfidenceScore
    fileprivate var recentNoMatchEvidence: [PlaceNoMatchEvidenceSample]
    fileprivate var appliedObservationFingerprints: [ObservationID: PlaceObservationFingerprint]
    fileprivate var appliedObservationOrder: [ObservationID]

    /// Exact replay deduplication is intentionally bounded. Replaying an older
    /// event falls through to revision validation instead of retaining its full
    /// candidate payload forever.
    public var rememberedObservationCount: Int {
        appliedObservationFingerprints.count
    }

    public var recentNoMatchObservationCount: Int {
        recentNoMatchEvidence.count
    }

    fileprivate init() {
        revision = 0
        latestSequence = nil
        completedObservationCount = 0
        candidates = [:]
        latestObservedCandidateIDs = []
        latestAbsenceConfidence = .zero
        recentNoMatchEvidence = []
        appliedObservationFingerprints = [:]
        appliedObservationOrder = []
    }
}

private struct PlaceNoMatchEvidenceSample: Equatable, Sendable {
    let observationID: ObservationID
    let sequence: UInt64
    let confidence: ConfidenceScore
}

/// Compact, deterministic tombstone for exact idempotency checks. Four
/// independent 64-bit accumulators keep collision probability negligible
/// without retaining image-derived candidate payloads or adding CryptoKit to
/// the platform-neutral package.
private struct PlaceObservationFingerprint: Equatable, Sendable {
    let first: UInt64
    let second: UInt64
    let third: UInt64
    let fourth: UInt64
}

public enum PlaceAssociationApplicationResult: Equatable, Sendable {
    case applied(newRevision: UInt64, decision: PlaceAssociationDecision)
    case alreadyApplied(currentRevision: UInt64, decision: PlaceAssociationDecision)
}

/// Stateful, platform-neutral reducer for safe place association and map-merge
/// proposals. It deliberately consumes already-computed evidence and does not
/// claim to perform image retrieval, VIO relocalization, or map fusion.
public struct PlaceMapAssociationReducer: Sendable {
    public let context: PlaceAssociationContext
    public let policy: PlaceAssociationPolicy
    public private(set) var snapshot: PlaceAssociationSnapshot

    public init(
        context: PlaceAssociationContext,
        policy: PlaceAssociationPolicy = .default
    ) {
        self.context = context
        self.policy = policy
        snapshot = PlaceAssociationSnapshot()
    }

    /// Replays an event set in stable sequence/ID order. Every event still has
    /// to carry the correct base revision, so missing or duplicated log entries
    /// fail closed.
    public static func replay(
        context: PlaceAssociationContext,
        policy: PlaceAssociationPolicy = .default,
        observations: [PlaceAssociationObservation]
    ) throws -> Self {
        var reducer = Self(context: context, policy: policy)
        var uniqueObservations: [ObservationID: PlaceAssociationObservation] = [:]
        var fingerprints: [ObservationID: PlaceObservationFingerprint] = [:]
        for observation in observations {
            let fingerprint = Self.fingerprint(of: observation)
            if let existing = fingerprints[observation.id], existing != fingerprint {
                throw PlaceMapAssociationError.observationIdentifierCollision(observation.id)
            }
            uniqueObservations[observation.id] = observation
            fingerprints[observation.id] = fingerprint
        }
        let ordered = uniqueObservations.values.sorted(by: Self.observationOrder)
        for observation in ordered {
            _ = try reducer.apply(observation)
        }
        return reducer
    }

    @discardableResult
    public mutating func apply(
        _ observation: PlaceAssociationObservation
    ) throws -> PlaceAssociationApplicationResult {
        let fingerprint = Self.fingerprint(of: observation)
        if let existing = snapshot.appliedObservationFingerprints[observation.id] {
            guard existing == fingerprint else {
                throw PlaceMapAssociationError.observationIdentifierCollision(observation.id)
            }
            return .alreadyApplied(currentRevision: snapshot.revision, decision: decision())
        }

        guard observation.baseRevision == snapshot.revision else {
            throw PlaceMapAssociationError.revisionConflict(
                expected: snapshot.revision,
                actualBase: observation.baseRevision
            )
        }
        if let latestSequence = snapshot.latestSequence {
            guard observation.sequence > latestSequence else {
                throw PlaceMapAssociationError.outOfOrderObservation(
                    previous: latestSequence,
                    incoming: observation.sequence
                )
            }
        }

        let candidateIDs = observation.candidates.map(\.mapID)
        guard Set(candidateIDs).count == candidateIDs.count else {
            let duplicate = candidateIDs.sorted().first { id in
                candidateIDs.filter { $0 == id }.count > 1
            }!
            throw PlaceMapAssociationError.duplicateCandidate(duplicate)
        }
        var working = snapshot
        pruneEvidence(currentSequence: observation.sequence, in: &working)
        evictExpiredCandidatesIfNeeded(
            incomingCandidateIDs: Set(candidateIDs),
            from: &working
        )

        let newCandidateIDs = Set(candidateIDs).subtracting(working.candidates.keys)
        guard
            working.candidates.count + newCandidateIDs.count
                <= policy.maximumTrackedCandidates
        else {
            throw PlaceMapAssociationError.tooManyCandidates(
                maximum: policy.maximumTrackedCandidates
            )
        }

        for candidate in observation.candidates.sorted(by: { $0.mapID < $1.mapID }) {
            try apply(
                candidate,
                observationID: observation.id,
                sequence: observation.sequence,
                to: &working
            )
        }
        updateRecentNoMatchEvidence(for: observation, in: &working)

        let (nextRevision, revisionOverflow) = working.revision.addingReportingOverflow(1)
        guard !revisionOverflow else {
            throw PlaceMapAssociationError.revisionOverflow
        }
        let (nextObservationCount, observationOverflow) =
            working.completedObservationCount.addingReportingOverflow(1)
        guard !observationOverflow else {
            throw PlaceMapAssociationError.observationCounterOverflow
        }

        working.revision = nextRevision
        working.latestSequence = observation.sequence
        working.completedObservationCount = nextObservationCount
        working.latestObservedCandidateIDs = Set(candidateIDs)
        working.appliedObservationFingerprints[observation.id] = fingerprint
        working.appliedObservationOrder.append(observation.id)
        if working.appliedObservationOrder.count > policy.maximumRememberedObservations {
            let overflow =
                working.appliedObservationOrder.count - policy.maximumRememberedObservations
            let evicted = working.appliedObservationOrder.prefix(overflow)
            working.appliedObservationOrder.removeFirst(overflow)
            for observationID in evicted {
                working.appliedObservationFingerprints.removeValue(forKey: observationID)
            }
        }
        snapshot = working

        return .applied(newRevision: snapshot.revision, decision: decision())
    }

    public func candidateEvaluations() -> [PlaceAssociationCandidateEvaluation] {
        snapshot.candidates.values
            .map(evaluate)
            .sorted(by: Self.evaluationOrder)
    }

    public func decision() -> PlaceAssociationDecision {
        let evaluations = candidateEvaluations()
        let active = evaluations.filter { evaluation in
            snapshot.latestObservedCandidateIDs.contains(evaluation.mapID)
                && evaluation.evidenceCount > 0
                && !evaluation.compatibility.isIncompatible
        }
        let potentialMatches = active.filter {
            $0.recognition.classification != .new
        }

        guard let leadingPotential = potentialMatches.first else {
            guard
                snapshot.recentNoMatchEvidence.count
                    >= Int(policy.minimumObservationsForNewPlace)
            else {
                let reason: PlaceAssociationDecisionReason =
                    snapshot.latestAbsenceConfidence >= policy.minimumNewPlaceConfidence
                    ? .insufficientRepeatedEvidence
                    : .insufficientNoMatchConfidence
                return ambiguousDecision(
                    candidates: active,
                    reason: reason
                )
            }
            let recentEvidence = snapshot.recentNoMatchEvidence.suffix(
                Int(policy.minimumObservationsForNewPlace)
            )
            let noMatchConfidence = ConfidenceScore(
                clamping: recentEvidence.reduce(0) { $0 + $1.confidence.value }
                    / Double(recentEvidence.count)
            )
            guard noMatchConfidence >= policy.minimumNewPlaceConfidence else {
                return ambiguousDecision(
                    candidates: active,
                    reason: .insufficientNoMatchConfidence
                )
            }
            return PlaceAssociationDecision(
                outcome: .new,
                mutation: .createNewMap,
                selectedMapID: nil,
                candidateMapIDs: [],
                confidence: noMatchConfidence,
                grade: policy.confidencePolicy.grade(for: noMatchConfidence),
                reason: .noCandidateMatch
            )
        }

        guard leadingPotential.evidenceCount >= policy.minimumObservationsForAssociation else {
            return ambiguousDecision(
                candidates: potentialMatches,
                reason: .insufficientRepeatedEvidence
            )
        }
        guard
            leadingPotential.supportingModalityCount
                >= policy.minimumModalitiesForAssociation
        else {
            return ambiguousDecision(
                candidates: potentialMatches,
                reason: .insufficientIndependentModalities
            )
        }

        let qualified = potentialMatches.filter {
            $0.evidenceCount >= policy.minimumObservationsForAssociation
                && $0.supportingModalityCount >= policy.minimumModalitiesForAssociation
        }
        if qualified.count > 1 {
            let difference =
                qualified[0].recognition.aggregateScore.value
                - qualified[1].recognition.aggregateScore.value
            if difference < policy.ambiguityMargin.value {
                return ambiguousDecision(
                    candidates: qualified,
                    reason: .competingCandidates
                )
            }
        }

        guard leadingPotential.compatibility.isCompatible else {
            return ambiguousDecision(
                candidates: potentialMatches,
                reason: .coordinateCompatibilityUnresolved
            )
        }

        switch leadingPotential.recognition.classification {
        case .known:
            return selectedDecision(
                outcome: .known,
                evaluation: leadingPotential,
                reason: .recognizedKnownPlace
            )
        case .overlapping:
            return selectedDecision(
                outcome: .overlapping,
                evaluation: leadingPotential,
                reason: .recognizedPartialOverlap
            )
        case .new:
            // Filtered above. Keeping this branch explicit makes future enum
            // additions fail at compile time rather than changing behavior.
            return ambiguousDecision(
                candidates: potentialMatches,
                reason: .insufficientRepeatedEvidence
            )
        }
    }

    private mutating func apply(
        _ candidate: PlaceMapCandidateEvidence,
        observationID: ObservationID,
        sequence: UInt64,
        to state: inout PlaceAssociationSnapshot
    ) throws {
        if let sourceMapID = context.sourceMapID,
            sourceMapID == candidate.mapID,
            context.sourceCoordinateFrameID != candidate.coordinateFrameID
        {
            throw PlaceMapAssociationError.sourceMapCoordinateFrameConflict(
                mapID: candidate.mapID
            )
        }

        var candidateState =
            state.candidates[candidate.mapID]
            ?? PlaceAssociationCandidateState(
                mapID: candidate.mapID,
                coordinateFrameID: candidate.coordinateFrameID,
                lastObservedSequence: sequence
            )
        guard candidateState.coordinateFrameID == candidate.coordinateFrameID else {
            throw PlaceMapAssociationError.candidateCoordinateFrameConflict(
                mapID: candidate.mapID
            )
        }

        candidateState.compatibility = try compatibilityLatch(
            current: candidateState.compatibility,
            candidate: candidate
        )
        candidateState.evidence.append(
            PlaceCandidateEvidenceSample(
                observationID: observationID,
                sequence: sequence,
                evidence: candidate.placeEvidence
            )
        )
        candidateState.lastObservedSequence = sequence
        candidateState.evidence.sort(by: Self.sampleOrder)
        if candidateState.evidence.count > policy.maximumEvidencePerCandidate {
            candidateState.evidence.removeFirst(
                candidateState.evidence.count - policy.maximumEvidencePerCandidate
            )
        }
        state.candidates[candidate.mapID] = candidateState
    }

    private func compatibilityLatch(
        current: PlaceCoordinateCompatibilityLatch,
        candidate: PlaceMapCandidateEvidence
    ) throws -> PlaceCoordinateCompatibilityLatch {
        if candidate.coordinateFrameID == context.sourceCoordinateFrameID {
            if case .aligned(let transform, _) = candidate.coordinateCompatibility,
                transform != .identity
            {
                throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
            }
            if case .incompatible(let confidence) = candidate.coordinateCompatibility,
                policy.confidencePolicy.grade(for: confidence) == .high
            {
                throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
            }
            if case .incompatible = current {
                throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
            }
            return .compatible(sourceToCandidate: .identity, confidence: .one)
        }

        switch candidate.coordinateCompatibility {
        case .unresolved:
            return current

        case .aligned(let transform, let confidence):
            guard policy.confidencePolicy.grade(for: confidence) == .high else {
                return current
            }
            switch current {
            case .unresolved:
                return .compatible(sourceToCandidate: transform, confidence: confidence)
            case .compatible(let latchedTransform, _):
                guard latchedTransform == transform else {
                    throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
                }
                return current
            case .incompatible:
                throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
            }

        case .incompatible(let confidence):
            guard policy.confidencePolicy.grade(for: confidence) == .high else {
                return current
            }
            switch current {
            case .unresolved:
                return .incompatible(confidence: confidence)
            case .incompatible:
                return current
            case .compatible:
                throw PlaceMapAssociationError.compatibilityConflict(mapID: candidate.mapID)
            }
        }
    }

    private func pruneEvidence(
        currentSequence: UInt64,
        in state: inout PlaceAssociationSnapshot
    ) {
        let cutoff =
            currentSequence > policy.maximumEvidenceSequenceAge
            ? currentSequence - policy.maximumEvidenceSequenceAge
            : 0
        for mapID in state.candidates.keys {
            state.candidates[mapID]?.evidence.removeAll { sample in
                sample.sequence < cutoff
            }
        }
        state.recentNoMatchEvidence.removeAll { sample in
            sample.sequence < cutoff
        }
    }

    /// Removes only candidates whose complete evidence window has expired.
    /// Compatibility is latched for the lifetime of that active window; if an
    /// evicted map reappears, it must earn fresh repeated evidence and a fresh
    /// high-confidence alignment before any merge can be proposed.
    private func evictExpiredCandidatesIfNeeded(
        incomingCandidateIDs: Set<MapID>,
        from state: inout PlaceAssociationSnapshot
    ) {
        let newCandidateCount = incomingCandidateIDs.subtracting(state.candidates.keys).count
        let overflow = state.candidates.count + newCandidateCount - policy.maximumTrackedCandidates
        guard overflow > 0 else {
            return
        }

        let evictable = state.candidates.values
            .filter { candidate in
                candidate.evidence.isEmpty && !incomingCandidateIDs.contains(candidate.mapID)
            }
            .sorted { lhs, rhs in
                if lhs.lastObservedSequence != rhs.lastObservedSequence {
                    return lhs.lastObservedSequence < rhs.lastObservedSequence
                }
                return lhs.mapID < rhs.mapID
            }
        for candidate in evictable.prefix(overflow) {
            state.candidates.removeValue(forKey: candidate.mapID)
        }
    }

    private func updateRecentNoMatchEvidence(
        for observation: PlaceAssociationObservation,
        in state: inout PlaceAssociationSnapshot
    ) {
        let recognizer = PlaceRecognizer(
            policy: policy.recognitionPolicy,
            confidencePolicy: policy.confidencePolicy
        )
        let compatibleCandidates = observation.candidates.filter { candidate in
            !(state.candidates[candidate.mapID]?.compatibility.isIncompatible ?? false)
        }
        let results = compatibleCandidates.map {
            recognizer.classify($0.placeEvidence)
        }
        let bestMatchConfidence = results.map(\.aggregateScore).max() ?? .zero
        let absenceConfidence = ConfidenceScore(clamping: 1 - bestMatchConfidence.value)
        state.latestAbsenceConfidence = absenceConfidence

        let containsPotentialMatch = results.contains {
            $0.classification != .new
        }
        guard !containsPotentialMatch,
            absenceConfidence >= policy.minimumNewPlaceConfidence
        else {
            state.recentNoMatchEvidence.removeAll(keepingCapacity: true)
            return
        }

        state.recentNoMatchEvidence.append(
            PlaceNoMatchEvidenceSample(
                observationID: observation.id,
                sequence: observation.sequence,
                confidence: absenceConfidence
            )
        )
        if state.recentNoMatchEvidence.count > policy.maximumEvidencePerCandidate {
            state.recentNoMatchEvidence.removeFirst(
                state.recentNoMatchEvidence.count - policy.maximumEvidencePerCandidate
            )
        }
    }

    private func evaluate(
        _ state: PlaceAssociationCandidateState
    ) -> PlaceAssociationCandidateEvaluation {
        let aggregate = averagedEvidence(state.evidence.map(\.evidence))
        let recognition = PlaceRecognizer(
            policy: policy.recognitionPolicy,
            confidencePolicy: policy.confidencePolicy
        ).classify(aggregate)
        let modalityGrades = modalityScores(aggregate).map {
            policy.confidencePolicy.grade(for: $0)
        }
        return PlaceAssociationCandidateEvaluation(
            mapID: state.mapID,
            coordinateFrameID: state.coordinateFrameID,
            compatibility: state.compatibility,
            evidenceCount: UInt(state.evidence.count),
            aggregateEvidence: aggregate,
            recognition: recognition,
            supportingModalityCount: modalityGrades.filter { $0 >= .medium }.count,
            highModalityCount: modalityGrades.filter { $0 == .high }.count
        )
    }

    private func averagedEvidence(_ evidence: [PlaceEvidence]) -> PlaceEvidence {
        guard !evidence.isEmpty else {
            return PlaceEvidence(
                visual: .zero,
                geometry: .zero,
                structure: .zero,
                poseConsistency: .zero,
                objectLayout: .zero,
                spatialOverlap: .zero
            )
        }
        let divisor = Double(evidence.count)
        return PlaceEvidence(
            visual: ConfidenceScore(clamping: evidence.reduce(0) { $0 + $1.visual.value } / divisor),
            geometry: ConfidenceScore(clamping: evidence.reduce(0) { $0 + $1.geometry.value } / divisor),
            structure: ConfidenceScore(clamping: evidence.reduce(0) { $0 + $1.structure.value } / divisor),
            poseConsistency: ConfidenceScore(
                clamping: evidence.reduce(0) { $0 + $1.poseConsistency.value } / divisor
            ),
            objectLayout: ConfidenceScore(
                clamping: evidence.reduce(0) { $0 + $1.objectLayout.value } / divisor
            ),
            spatialOverlap: ConfidenceScore(
                clamping: evidence.reduce(0) { $0 + $1.spatialOverlap.value } / divisor
            )
        )
    }

    private func modalityScores(_ evidence: PlaceEvidence) -> [ConfidenceScore] {
        [
            evidence.visual,
            evidence.geometry,
            evidence.structure,
            evidence.poseConsistency,
            evidence.objectLayout,
            evidence.spatialOverlap,
        ]
    }

    private func selectedDecision(
        outcome: PlaceAssociationOutcome,
        evaluation: PlaceAssociationCandidateEvaluation,
        reason: PlaceAssociationDecisionReason
    ) -> PlaceAssociationDecision {
        PlaceAssociationDecision(
            outcome: outcome,
            mutation: mutationDecision(for: evaluation),
            selectedMapID: evaluation.mapID,
            candidateMapIDs: [evaluation.mapID],
            confidence: evaluation.recognition.aggregateScore,
            grade: evaluation.recognition.grade,
            reason: reason
        )
    }

    private func mutationDecision(
        for evaluation: PlaceAssociationCandidateEvaluation
    ) -> PlaceMapMutationDecision {
        guard let sourceMapID = context.sourceMapID,
            sourceMapID != evaluation.mapID
        else {
            return .associateExisting(targetMapID: evaluation.mapID)
        }
        guard evaluation.evidenceCount >= policy.minimumObservationsForMerge,
            evaluation.recognition.grade == .high,
            evaluation.highModalityCount >= policy.minimumHighModalitiesForMerge,
            case .compatible(let sourceToCandidate, _) = evaluation.compatibility
        else {
            return .deferDecision
        }
        return .mergeMaps(
            sourceMapID: sourceMapID,
            targetMapID: evaluation.mapID,
            sourceToTarget: sourceToCandidate
        )
    }

    private func ambiguousDecision(
        candidates: [PlaceAssociationCandidateEvaluation],
        reason: PlaceAssociationDecisionReason
    ) -> PlaceAssociationDecision {
        let confidence = candidates.first?.recognition.aggregateScore ?? .zero
        return PlaceAssociationDecision(
            outcome: .ambiguous,
            mutation: .deferDecision,
            selectedMapID: nil,
            candidateMapIDs: candidates.map(\.mapID),
            confidence: confidence,
            grade: policy.confidencePolicy.grade(for: confidence),
            reason: reason
        )
    }

    private static func observationOrder(
        _ lhs: PlaceAssociationObservation,
        _ rhs: PlaceAssociationObservation
    ) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.id < rhs.id
    }

    private static func sampleOrder(
        _ lhs: PlaceCandidateEvidenceSample,
        _ rhs: PlaceCandidateEvidenceSample
    ) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.observationID < rhs.observationID
    }

    private static func evaluationOrder(
        _ lhs: PlaceAssociationCandidateEvaluation,
        _ rhs: PlaceAssociationCandidateEvaluation
    ) -> Bool {
        if lhs.recognition.aggregateScore != rhs.recognition.aggregateScore {
            return lhs.recognition.aggregateScore > rhs.recognition.aggregateScore
        }
        return lhs.mapID < rhs.mapID
    }

    private static func fingerprint(
        of observation: PlaceAssociationObservation
    ) -> PlaceObservationFingerprint {
        var builder = PlaceFingerprintBuilder()
        builder.append("vispace-place-observation-v1")
        builder.append(observation.baseRevision)
        builder.append(observation.sequence)
        builder.append(UInt64(observation.candidates.count))
        for candidate in observation.candidates.sorted(by: { $0.mapID < $1.mapID }) {
            builder.append(candidate.mapID.description)
            builder.append(candidate.coordinateFrameID.description)
            builder.append(candidate.placeEvidence.visual.value)
            builder.append(candidate.placeEvidence.geometry.value)
            builder.append(candidate.placeEvidence.structure.value)
            builder.append(candidate.placeEvidence.poseConsistency.value)
            builder.append(candidate.placeEvidence.objectLayout.value)
            builder.append(candidate.placeEvidence.spatialOverlap.value)
            switch candidate.coordinateCompatibility {
            case .unresolved:
                builder.append(UInt64(0))
            case .aligned(let transform, let confidence):
                builder.append(UInt64(1))
                for element in transform.rowMajorElements {
                    builder.append(element)
                }
                builder.append(confidence.value)
            case .incompatible(let confidence):
                builder.append(UInt64(2))
                builder.append(confidence.value)
            }
        }
        return builder.finalize()
    }
}

private struct PlaceFingerprintBuilder {
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private var first: UInt64 = 0xcbf2_9ce4_8422_2325
    private var second: UInt64 = 0x8422_2325_cbf2_9ce4
    private var third: UInt64 = 0x9e37_79b1_85eb_ca87
    private var fourth: UInt64 = 0xd6e8_feb8_6659_fd93

    mutating func append(_ value: String) {
        let bytes = Array(value.utf8)
        append(UInt64(bytes.count))
        for byte in bytes {
            append(byte)
        }
    }

    mutating func append(_ value: Double) {
        let normalized = value == 0 ? 0.0 : value
        append(normalized.bitPattern)
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func finalize() -> PlaceObservationFingerprint {
        PlaceObservationFingerprint(
            first: first,
            second: second,
            third: third,
            fourth: fourth
        )
    }

    private mutating func append(_ byte: UInt8) {
        first = (first ^ UInt64(byte)) &* Self.prime
        second = (second ^ UInt64(byte)) &* Self.prime
        third = (third ^ UInt64(byte)) &* Self.prime
        fourth = (fourth ^ UInt64(byte)) &* Self.prime
    }
}

extension PlaceCoordinateCompatibilityLatch {
    fileprivate var isCompatible: Bool {
        if case .compatible = self {
            return true
        }
        return false
    }

    fileprivate var isIncompatible: Bool {
        if case .incompatible = self {
            return true
        }
        return false
    }
}
