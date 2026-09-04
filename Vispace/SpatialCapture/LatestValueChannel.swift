import Foundation

public enum LatestValueSendResult: Equatable, Sendable {
    case enqueued
    case replacedOlderValue
    case terminated
}

/// A thread-safe, bounded async channel. It retains at most `bufferLimit`
/// unconsumed values (one by default), dropping oldest work when a consumer lags.
public final class LatestValueChannel<Element: Sendable>: @unchecked Sendable {
    public let stream: AsyncStream<Element>

    private let continuation: AsyncStream<Element>.Continuation

    public init(bufferLimit: Int = 1) {
        let pair = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    public func send(_ value: Element) -> LatestValueSendResult {
        switch continuation.yield(value) {
        case .enqueued:
            return .enqueued
        case .dropped:
            return .replacedOlderValue
        case .terminated:
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
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
