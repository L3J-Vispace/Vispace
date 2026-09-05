import Foundation
import VispaceCore

public enum ARGuidanceDirection: String, CaseIterable, Equatable, Sendable {
    case ahead
    case aheadRight
    case right
    case behindRight
    case behind
    case behindLeft
    case left
    case aheadLeft
}

/// A camera-relative, coordinate-only presentation model. It intentionally
/// accepts a target only after the query layer has transformed that target into
/// the active AR coordinate frame; it has no API for resolving map identity.
public struct ARGuidanceProjection: Equatable, Sendable {
    public let distanceMeters: Double
    public let horizontalDistanceMeters: Double
    public let verticalOffsetMeters: Double
    /// Clockwise screen-space direction: zero is straight ahead and positive
    /// values point to the user's right.
    public let bearingRadians: Double
    public let direction: ARGuidanceDirection
    public let isWithinForwardView: Bool
    public let hasArrived: Bool
}

public struct ARGuidanceProjectionPolicy: Equatable, Sendable {
    public let forwardViewHalfAngleRadians: Double
    public let arrivalDistanceMeters: Double
    public let minimumHorizontalVectorMeters: Double

    public init(
        forwardViewHalfAngleRadians: Double = 28 * .pi / 180,
        arrivalDistanceMeters: Double = 0.35,
        minimumHorizontalVectorMeters: Double = 0.001
    ) {
        self.forwardViewHalfAngleRadians = max(
            0,
            min(.pi, forwardViewHalfAngleRadians.isFinite ? forwardViewHalfAngleRadians : 0)
        )
        self.arrivalDistanceMeters = max(
            0,
            arrivalDistanceMeters.isFinite ? arrivalDistanceMeters : 0
        )
        self.minimumHorizontalVectorMeters = max(
            Double.ulpOfOne,
            minimumHorizontalVectorMeters.isFinite ? minimumHorizontalVectorMeters : 0.001
        )
    }

    public static let `default` = Self()
}

/// Converts an already-grounded target into a distance and horizontal bearing
/// using ARKit's camera convention (local -Z is forward, +X is right).
public struct ARGuidanceProjector: Sendable {
    public let policy: ARGuidanceProjectionPolicy

    public init(policy: ARGuidanceProjectionPolicy = .default) {
        self.policy = policy
    }

    public func project(
        target: Vec3,
        cameraTransform: Matrix4x4Snapshot
    ) -> ARGuidanceProjection? {
        let camera = cameraTransform.column3
        let rightAxis = cameraTransform.column0
        let forwardAxis = -cameraTransform.column2
        let finiteValues = [
            camera.x, camera.y, camera.z,
            rightAxis.x, rightAxis.z,
            forwardAxis.x, forwardAxis.z,
        ]
        guard finiteValues.allSatisfy(\.isFinite) else {
            return nil
        }

        let deltaX = target.x - Double(camera.x)
        let deltaY = target.y - Double(camera.y)
        let deltaZ = target.z - Double(camera.z)
        let distance = (deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ).squareRoot()
        let horizontalDistance = (deltaX * deltaX + deltaZ * deltaZ).squareRoot()
        guard distance.isFinite, horizontalDistance.isFinite else {
            return nil
        }

        let rightLength = hypot(Double(rightAxis.x), Double(rightAxis.z))
        let forwardLength = hypot(Double(forwardAxis.x), Double(forwardAxis.z))
        guard rightLength >= policy.minimumHorizontalVectorMeters,
            forwardLength >= policy.minimumHorizontalVectorMeters
        else {
            return nil
        }

        let rightComponent =
            deltaX * Double(rightAxis.x) / rightLength
            + deltaZ * Double(rightAxis.z) / rightLength
        let forwardComponent =
            deltaX * Double(forwardAxis.x) / forwardLength
            + deltaZ * Double(forwardAxis.z) / forwardLength
        let bearing: Double
        if horizontalDistance < policy.minimumHorizontalVectorMeters {
            bearing = 0
        } else {
            bearing = atan2(rightComponent, forwardComponent)
        }

        return ARGuidanceProjection(
            distanceMeters: distance,
            horizontalDistanceMeters: horizontalDistance,
            verticalOffsetMeters: deltaY,
            bearingRadians: bearing,
            direction: direction(for: bearing),
            isWithinForwardView: abs(bearing) <= policy.forwardViewHalfAngleRadians,
            hasArrived: distance <= policy.arrivalDistanceMeters
        )
    }

    private func direction(for bearing: Double) -> ARGuidanceDirection {
        let octant = Int((bearing / (.pi / 4)).rounded())
        switch octant {
        case 0:
            return .ahead
        case 1:
            return .aheadRight
        case 2:
            return .right
        case 3:
            return .behindRight
        case 4, -4:
            return .behind
        case -3:
            return .behindLeft
        case -2:
            return .left
        default:
            return .aheadLeft
        }
    }
}
