import Foundation

public enum GeometryError: Error, Equatable, Sendable {
    case nonFiniteValue
    case invalidMatrixElementCount(expected: Int, actual: Int)
    case invalidBounds
    case nonInvertibleHomogeneousCoordinate
}

public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) throws {
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw GeometryError.nonFiniteValue
        }
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = try! Vec3(x: 0, y: 0, z: 0)

    public static func + (lhs: Self, rhs: Self) -> Self {
        // Finite inputs can overflow only at extreme, non-spatial magnitudes.
        // Keep operators convenient while validated initializers guard boundaries.
        try! Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        try! Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: Self, rhs: Double) -> Self {
        try! Self(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    public func dot(_ other: Self) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public var squaredLength: Double {
        dot(self)
    }

    public var length: Double {
        squaredLength.squareRoot()
    }

    public func distance(to other: Self) -> Double {
        (self - other).length
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case z
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y),
                z: container.decode(Double.self, forKey: .z)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Vector components must be finite."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(z, forKey: .z)
    }
}

/// A row-major 4x4 homogeneous transform. Values are intentionally independent
/// of simd and ARKit so the domain package also runs on Linux.
public struct Transform3D: Hashable, Sendable {
    public static let elementCount = 16

    private let storage: [Double]

    public init(rowMajorElements: [Double]) throws {
        guard rowMajorElements.count == Self.elementCount else {
            throw GeometryError.invalidMatrixElementCount(
                expected: Self.elementCount,
                actual: rowMajorElements.count
            )
        }
        guard rowMajorElements.allSatisfy(\.isFinite) else {
            throw GeometryError.nonFiniteValue
        }
        storage = rowMajorElements
    }

    public static let identity = try! Transform3D(rowMajorElements: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    public static func translation(_ value: Vec3) -> Self {
        try! Self(rowMajorElements: [
            1, 0, 0, value.x,
            0, 1, 0, value.y,
            0, 0, 1, value.z,
            0, 0, 0, 1,
        ])
    }

    public var rowMajorElements: [Double] {
        storage
    }

    public subscript(row: Int, column: Int) -> Double {
        precondition((0..<4).contains(row) && (0..<4).contains(column))
        return storage[(row * 4) + column]
    }

    public var translation: Vec3 {
        try! Vec3(x: self[0, 3], y: self[1, 3], z: self[2, 3])
    }

    public func transformed(_ point: Vec3) throws -> Vec3 {
        let x = self[0, 0] * point.x + self[0, 1] * point.y + self[0, 2] * point.z + self[0, 3]
        let y = self[1, 0] * point.x + self[1, 1] * point.y + self[1, 2] * point.z + self[1, 3]
        let z = self[2, 0] * point.x + self[2, 1] * point.y + self[2, 2] * point.z + self[2, 3]
        let w = self[3, 0] * point.x + self[3, 1] * point.y + self[3, 2] * point.z + self[3, 3]

        guard w.isFinite, abs(w) > .ulpOfOne else {
            throw GeometryError.nonInvertibleHomogeneousCoordinate
        }
        return try Vec3(x: x / w, y: y / w, z: z / w)
    }

    public static func * (lhs: Self, rhs: Self) -> Self {
        var values = Array(repeating: 0.0, count: Self.elementCount)
        for row in 0..<4 {
            for column in 0..<4 {
                values[(row * 4) + column] = (0..<4).reduce(0.0) { partial, index in
                    partial + lhs[row, index] * rhs[index, column]
                }
            }
        }
        return try! Self(rowMajorElements: values)
    }
}

extension Transform3D: Codable {
    private enum CodingKeys: String, CodingKey {
        case rowMajorElements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([Double].self, forKey: .rowMajorElements)
        do {
            try self.init(rowMajorElements: values)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .rowMajorElements,
                in: container,
                debugDescription: "Expected 16 finite row-major transform elements."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage, forKey: .rowMajorElements)
    }
}

public struct AABB: Codable, Hashable, Sendable {
    public let min: Vec3
    public let max: Vec3

    public init(min: Vec3, max: Vec3) throws {
        guard min.x <= max.x, min.y <= max.y, min.z <= max.z else {
            throw GeometryError.invalidBounds
        }
        self.min = min
        self.max = max
    }

    public var center: Vec3 {
        (min + max) * 0.5
    }

    public var size: Vec3 {
        max - min
    }

    public var volume: Double {
        let dimensions = size
        return dimensions.x * dimensions.y * dimensions.z
    }

    public func contains(_ point: Vec3) -> Bool {
        point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }

    public func contains(_ other: Self) -> Bool {
        contains(other.min) && contains(other.max)
    }

    public func intersects(_ other: Self) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
            && min.z <= other.max.z && max.z >= other.min.z
    }

    public func intersection(with other: Self) -> Self? {
        let lower = try! Vec3(
            x: Swift.max(min.x, other.min.x),
            y: Swift.max(min.y, other.min.y),
            z: Swift.max(min.z, other.min.z)
        )
        let upper = try! Vec3(
            x: Swift.min(max.x, other.max.x),
            y: Swift.min(max.y, other.max.y),
            z: Swift.min(max.z, other.max.z)
        )
        return try? Self(min: lower, max: upper)
    }

    public func intersectionOverUnion(with other: Self) -> Double {
        guard let overlap = intersection(with: other) else {
            return 0
        }
        let intersectionVolume = overlap.volume
        let unionVolume = volume + other.volume - intersectionVolume
        return unionVolume > 0 ? intersectionVolume / unionVolume : 0
    }

    /// Minimum Euclidean separation between two boxes. Intersecting or touching
    /// boxes have zero separation.
    public func distance(to other: Self) -> Double {
        let dx = Swift.max(0, Swift.max(other.min.x - max.x, min.x - other.max.x))
        let dy = Swift.max(0, Swift.max(other.min.y - max.y, min.y - other.max.y))
        let dz = Swift.max(0, Swift.max(other.min.z - max.z, min.z - other.max.z))
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private enum CodingKeys: String, CodingKey {
        case min
        case max
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                min: container.decode(Vec3.self, forKey: .min),
                max: container.decode(Vec3.self, forKey: .max)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .min,
                in: container,
                debugDescription: "AABB minimum values must not exceed maximum values."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(min, forKey: .min)
        try container.encode(max, forKey: .max)
    }
}

public struct PoseSample: Codable, Hashable, Sendable {
    public let frameID: FrameID
    public let timestamp: TimeInterval
    public let transform: Transform3D
    public let trackingConfidence: ConfidenceScore

    public init(
        frameID: FrameID,
        timestamp: TimeInterval,
        transform: Transform3D,
        trackingConfidence: ConfidenceScore
    ) throws {
        guard timestamp.isFinite, timestamp >= 0 else {
            throw GeometryError.nonFiniteValue
        }
        self.frameID = frameID
        self.timestamp = timestamp
        self.transform = transform
        self.trackingConfidence = trackingConfidence
    }

    private enum CodingKeys: String, CodingKey {
        case frameID
        case timestamp
        case transform
        case trackingConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                frameID: container.decode(FrameID.self, forKey: .frameID),
                timestamp: container.decode(TimeInterval.self, forKey: .timestamp),
                transform: container.decode(Transform3D.self, forKey: .transform),
                trackingConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .trackingConfidence
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Pose timestamp must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameID, forKey: .frameID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(transform, forKey: .transform)
        try container.encode(trackingConfidence, forKey: .trackingConfidence)
    }
}
