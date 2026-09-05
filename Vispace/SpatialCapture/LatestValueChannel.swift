import Foundation

public enum LatestValueSendResult: Equatable, Sendable {
    case enqueued
    case replacedOlderValue
    case terminated
}

/// A thread-safe, bounded async channel. It retains at most `bufferLimit`
/// unconsumed values per subscriber (one by default), dropping oldest work when
/// a consumer lags. Every stream request creates an independent subscriber so
/// feature controllers cannot steal AR snapshots from one another.
public final class LatestValueChannel<Element: Sendable>: @unchecked Sendable {
    public var stream: AsyncStream<Element> {
        let subscriberID = UUID()
        let pair = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            self?.removeSubscriber(subscriberID)
        }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            pair.continuation.finish()
            return pair.stream
        }
        subscribers[subscriberID] = pair.continuation
        if let latestValue {
            _ = pair.continuation.yield(latestValue)
            hasPendingValueWithoutSubscribers = false
        }
        lock.unlock()
        return pair.stream
    }

    private let bufferLimit: Int
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latestValue: Element?
    private var hasPendingValueWithoutSubscribers = false
    private var isFinished = false

    public init(bufferLimit: Int = 1) {
        self.bufferLimit = max(1, bufferLimit)
    }

    @discardableResult
    public func send(_ value: Element) -> LatestValueSendResult {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return .terminated
        }
        latestValue = value
        guard !subscribers.isEmpty else {
            let result: LatestValueSendResult =
                hasPendingValueWithoutSubscribers
                ? .replacedOlderValue
                : .enqueued
            hasPendingValueWithoutSubscribers = true
            lock.unlock()
            return result
        }

        var droppedValue = false
        var terminatedSubscriberIDs: [UUID] = []
        for (subscriberID, continuation) in subscribers {
            switch continuation.yield(value) {
            case .enqueued:
                break
            case .dropped:
                droppedValue = true
            case .terminated:
                terminatedSubscriberIDs.append(subscriberID)
            @unknown default:
                terminatedSubscriberIDs.append(subscriberID)
            }
        }
        for subscriberID in terminatedSubscriberIDs {
            subscribers.removeValue(forKey: subscriberID)
        }
        hasPendingValueWithoutSubscribers = subscribers.isEmpty
        lock.unlock()
        return droppedValue ? .replacedOlderValue : .enqueued
    }

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuations = Array(subscribers.values)
        subscribers.removeAll(keepingCapacity: false)
        latestValue = nil
        hasPendingValueWithoutSubscribers = false
        lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    deinit {
        finish()
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}

/// Limits costly deep copies before they enter the one-element channel.
final class SnapshotCadenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval?
    private var lastAcceptedTimestamp: TimeInterval?

    init(maximumFramesPerSecond: Double) {
        if maximumFramesPerSecond.isFinite, maximumFramesPerSecond > 0 {
            minimumInterval = 1 / maximumFramesPerSecond
        } else {
            minimumInterval = nil
        }
    }

    func admits(timestamp: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard timestamp.isFinite else {
            return false
        }
        guard let minimumInterval else {
            return false
        }
        guard let lastAcceptedTimestamp else {
            self.lastAcceptedTimestamp = timestamp
            return true
        }

        // ARSession timestamps normally increase monotonically. Treat a reset
        // as a new sequence rather than suppressing every subsequent frame.
        guard timestamp >= lastAcceptedTimestamp else {
            self.lastAcceptedTimestamp = timestamp
            return true
        }
        guard timestamp - lastAcceptedTimestamp >= minimumInterval else {
            return false
        }

        self.lastAcceptedTimestamp = timestamp
        return true
    }

    func reset() {
        lock.lock()
        lastAcceptedTimestamp = nil
        lock.unlock()
    }
}
