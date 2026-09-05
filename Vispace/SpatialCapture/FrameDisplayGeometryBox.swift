import Foundation

final class FrameDisplayGeometryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: FrameDisplayGeometry?

    var value: FrameDisplayGeometry? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
