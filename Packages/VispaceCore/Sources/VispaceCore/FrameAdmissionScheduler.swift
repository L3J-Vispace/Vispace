import Foundation

public struct FrameDescriptor: Codable, Hashable, Sendable {
    public let id: FrameID
    public let sequenceNumber: UInt64
    public let timestamp: TimeInterval

    public init(id: FrameID = FrameID(), sequenceNumber: UInt64, timestamp: TimeInterval) throws {
        guard timestamp.isFinite, timestamp >= 0 else {
            throw FrameAdmissionError.invalidTimestamp
        }
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sequenceNumber
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(FrameID.self, forKey: .id),
                sequenceNumber: container.decode(UInt64.self, forKey: .sequenceNumber),
                timestamp: container.decode(TimeInterval.self, forKey: .timestamp)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Frame timestamp must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sequenceNumber, forKey: .sequenceNumber)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct FrameAdmissionPolicy: Codable, Hashable, Sendable {
    public let minimumStartInterval: TimeInterval
    public let maximumFrameAge: TimeInterval

    public init(minimumStartInterval: TimeInterval, maximumFrameAge: TimeInterval) throws {
        guard minimumStartInterval.isFinite, minimumStartInterval >= 0,
            maximumFrameAge.isFinite, maximumFrameAge >= 0
        else {
            throw FrameAdmissionError.invalidPolicy
        }
        self.minimumStartInterval = minimumStartInterval
        self.maximumFrameAge = maximumFrameAge
    }

    public static let latestOnly = try! FrameAdmissionPolicy(
        minimumStartInterval: 0,
        maximumFrameAge: 0.25
    )

    private enum CodingKeys: String, CodingKey {
        case minimumStartInterval
        case maximumFrameAge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                minimumStartInterval: container.decode(
                    TimeInterval.self,
                    forKey: .minimumStartInterval
                ),
                maximumFrameAge: container.decode(TimeInterval.self, forKey: .maximumFrameAge)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .minimumStartInterval,
                in: container,
                debugDescription: "Frame policy intervals must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minimumStartInterval, forKey: .minimumStartInterval)
        try container.encode(maximumFrameAge, forKey: .maximumFrameAge)
    }
}

public enum FrameDropReason: Codable, Hashable, Sendable {
    case stale
    case outOfOrder
    case superseded
}

public struct DroppedFrame: Codable, Hashable, Sendable {
    public let frame: FrameDescriptor
    public let reason: FrameDropReason

    public init(frame: FrameDescriptor, reason: FrameDropReason) {
        self.frame = frame
        self.reason = reason
    }
}

public enum FrameOfferResult: Codable, Hashable, Sendable {
    case started(FrameDescriptor)
    case queued(FrameDescriptor, dropped: DroppedFrame?)
    case dropped(DroppedFrame)
}

public enum FrameAdmissionError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidPolicy
    case noFrameInFlight
    case unexpectedCompletion(expected: FrameID, actual: FrameID)
}

public struct FrameAdmissionStatistics: Codable, Hashable, Sendable {
    public fileprivate(set) var startedCount: UInt64 = 0
    public fileprivate(set) var staleDropCount: UInt64 = 0
    public fileprivate(set) var outOfOrderDropCount: UInt64 = 0
    public fileprivate(set) var supersededDropCount: UInt64 = 0

    public init() {}
}

/// Pure admission state machine for an expensive single-flight processor.
/// When processing falls behind, only the newest pending frame survives.
public struct FrameAdmissionScheduler: Sendable {
    public let policy: FrameAdmissionPolicy
    public private(set) var inFlight: FrameDescriptor?
    public private(set) var pendingLatest: FrameDescriptor?
    public private(set) var statistics = FrameAdmissionStatistics()

    private var newestOfferedSequence: UInt64?
    private var lastStartTime: TimeInterval?

    public init(policy: FrameAdmissionPolicy = .latestOnly) {
        self.policy = policy
    }

    public mutating func offer(_ frame: FrameDescriptor, now: TimeInterval) -> FrameOfferResult {
        guard now.isFinite, now >= 0 else {
            return recordDrop(frame, reason: .stale)
        }
        guard newestOfferedSequence.map({ frame.sequenceNumber > $0 }) ?? true else {
            return recordDrop(frame, reason: .outOfOrder)
        }
        newestOfferedSequence = frame.sequenceNumber

        guard age(of: frame, at: now) <= policy.maximumFrameAge else {
            return recordDrop(frame, reason: .stale)
        }

        if inFlight == nil, cadenceAllowsStart(at: now) {
            // A newer arrival can win the cadence race before poll drains the
            // queue. Never run the older pending frame after this one.
            if pendingLatest != nil {
                pendingLatest = nil
                statistics.supersededDropCount += 1
            }
            start(frame, at: now)
            return .started(frame)
        }

        let replaced = pendingLatest.map {
            DroppedFrame(frame: $0, reason: .superseded)
        }
        if replaced != nil {
            statistics.supersededDropCount += 1
        }
        pendingLatest = frame
        return .queued(frame, dropped: replaced)
    }

    /// Completes only the currently admitted frame. A mismatched completion is
    /// rejected without altering state. The newest eligible pending frame starts
    /// immediately and is returned.
    @discardableResult
    public mutating func complete(_ frameID: FrameID, now: TimeInterval) throws -> FrameDescriptor? {
        guard now.isFinite, now >= 0 else {
            throw FrameAdmissionError.invalidTimestamp
        }
        guard let current = inFlight else {
            throw FrameAdmissionError.noFrameInFlight
        }
        guard current.id == frameID else {
            throw FrameAdmissionError.unexpectedCompletion(expected: current.id, actual: frameID)
        }
        inFlight = nil
        return startPendingIfEligible(at: now)
    }

    /// Starts a cadence-delayed pending frame once it becomes eligible.
    @discardableResult
    public mutating func poll(now: TimeInterval) -> FrameDescriptor? {
        startPendingIfEligible(at: now)
    }

    private mutating func startPendingIfEligible(at now: TimeInterval) -> FrameDescriptor? {
        guard now.isFinite, now >= 0, inFlight == nil, let pending = pendingLatest
        else {
            return nil
        }

        guard age(of: pending, at: now) <= policy.maximumFrameAge else {
            pendingLatest = nil
            _ = recordDrop(pending, reason: .stale)
            return nil
        }
        guard cadenceAllowsStart(at: now) else {
            return nil
        }

        pendingLatest = nil
        start(pending, at: now)
        return pending
    }

    private func cadenceAllowsStart(at now: TimeInterval) -> Bool {
        guard let lastStartTime else {
            return true
        }
        return now - lastStartTime >= policy.minimumStartInterval
    }

    private func age(of frame: FrameDescriptor, at now: TimeInterval) -> TimeInterval {
        Swift.max(0, now - frame.timestamp)
    }

    private mutating func start(_ frame: FrameDescriptor, at now: TimeInterval) {
        inFlight = frame
        lastStartTime = now
        statistics.startedCount += 1
    }

    private mutating func recordDrop(
        _ frame: FrameDescriptor,
        reason: FrameDropReason
    ) -> FrameOfferResult {
        switch reason {
        case .stale:
            statistics.staleDropCount += 1
        case .outOfOrder:
            statistics.outOfOrderDropCount += 1
        case .superseded:
            statistics.supersededDropCount += 1
        }
        return .dropped(DroppedFrame(frame: frame, reason: reason))
    }
}
