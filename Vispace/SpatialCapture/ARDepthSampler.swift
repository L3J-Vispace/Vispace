import Foundation
import VispaceCore
import simd

public enum ARDepthConfidence: UInt8, CaseIterable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ARDepthSource: String, Equatable, Hashable, Sendable {
    case raw
    case smoothed
}

public enum ARDepthUnavailableReason: Equatable, Sendable {
    case depthNotSupportedOrUnavailable
    case pointOutsideImage
    case malformedDepthGrid
    case confidenceUnavailable
    case insufficientConfidence
    case invalidDepth
    case invalidIntrinsics
    case coordinateFrameUnconfirmed
    case trackingNotNormal
}

public struct ARDepthSample: Equatable, Sendable {
    public let frameID: ARFrameID
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let coordinateFrameStatus: ARCaptureIdentity.Status
    public let trackingState: ARTrackingStateSnapshot
    public let timestamp: TimeInterval
    public let source: ARDepthSource
    public let depthPixel: SIMD2<Int>
    public let depthMeters: Float
    public let confidence: ARDepthConfidence
    public let cameraPosition: SIMD3<Float>
    public let worldPosition: SIMD3<Float>
    public let uncertainty: SpatialPositionUncertainty
}

public enum ARDepthSamplingResult: Equatable, Sendable {
    case sample(ARDepthSample)
    case unavailable(ARDepthUnavailableReason)
}

public struct ARDepthSampler: Sendable {
    public let minimumConfidence: ARDepthConfidence
    public let neighborhoodRadius: Int

    public init(
        minimumConfidence: ARDepthConfidence = .medium,
        neighborhoodRadius: Int = 1
    ) {
        self.minimumConfidence = minimumConfidence
        self.neighborhoodRadius = max(0, neighborhoodRadius)
    }

    /// Samples a normalized top-left-origin camera-image point, filters depth
    /// by ARKit confidence, rejects invalid values, and returns a world-space
    /// point in the snapshot's explicitly identified coordinate frame.
    public func sample(
        normalizedImagePoint: SIMD2<Float>,
        in snapshot: ARFrameSnapshot,
        prefersSmoothedDepth: Bool = true
    ) -> ARDepthSamplingResult {
        guard
            normalizedImagePoint.x.isFinite,
            normalizedImagePoint.y.isFinite,
            (0...1).contains(normalizedImagePoint.x),
            (0...1).contains(normalizedImagePoint.y)
        else {
            return .unavailable(.pointOutsideImage)
        }
        guard snapshot.pose.coordinateFrameStatus == .confirmed else {
            return .unavailable(.coordinateFrameUnconfirmed)
        }
        guard snapshot.pose.trackingState == .normal else {
            return .unavailable(.trackingNotNormal)
        }

        let selection: (ARDepthSnapshot, ARDepthSource)?
        if prefersSmoothedDepth, let smoothed = snapshot.smoothedSceneDepth {
            selection = (smoothed, .smoothed)
        } else if let raw = snapshot.sceneDepth {
            selection = (raw, .raw)
        } else if let smoothed = snapshot.smoothedSceneDepth {
            selection = (smoothed, .smoothed)
        } else {
            selection = nil
        }
        guard let (depth, source) = selection else {
            return .unavailable(.depthNotSupportedOrUnavailable)
        }

        let width = depth.dimensions.width
        let height = depth.dimensions.height
        let (pixelCount, pixelCountOverflows) = width.multipliedReportingOverflow(by: height)
        guard
            width > 0,
            height > 0,
            !pixelCountOverflows,
            depth.depthMeters.count == pixelCount,
            depth.confidence?.count == nil || depth.confidence?.count == pixelCount
        else {
            return .unavailable(.malformedDepthGrid)
        }
        guard let confidenceValues = depth.confidence else {
            return .unavailable(.confidenceUnavailable)
        }

        let centerX = min(width - 1, Int((normalizedImagePoint.x * Float(width)).rounded(.down)))
        let centerY = min(height - 1, Int((normalizedImagePoint.y * Float(height)).rounded(.down)))
        // Clamp each offset before arithmetic: even Int.max is a valid caller
        // supplied radius and must not overflow while clipping to the grid.
        let lowerX = centerX - min(centerX, neighborhoodRadius)
        let upperX = centerX + min(width - 1 - centerX, neighborhoodRadius)
        let lowerY = centerY - min(centerY, neighborhoodRadius)
        let upperY = centerY + min(height - 1 - centerY, neighborhoodRadius)

        var candidates:
            [(
                x: Int,
                y: Int,
                meters: Float,
                confidence: ARDepthConfidence
            )] = []
        for y in lowerY...upperY {
            for x in lowerX...upperX {
                let index = (y * width) + x
                guard
                    let confidence = ARDepthConfidence(rawValue: confidenceValues[index]),
                    confidence >= minimumConfidence
                else {
                    continue
                }
                let meters = depth.depthMeters[index]
                guard meters.isFinite, meters > 0 else {
                    continue
                }
                candidates.append((x, y, meters, confidence))
            }
        }
        guard !candidates.isEmpty else {
            let hasSufficientConfidence = (lowerY...upperY).contains { y in
                (lowerX...upperX).contains { x in
                    guard
                        let value = ARDepthConfidence(
                            rawValue: confidenceValues[(y * width) + x]
                        )
                    else {
                        return false
                    }
                    return value >= minimumConfidence
                }
            }
            return .unavailable(hasSufficientConfidence ? .invalidDepth : .insufficientConfidence)
        }

        candidates.sort { lhs, rhs in
            if lhs.meters != rhs.meters {
                return lhs.meters < rhs.meters
            }
            if lhs.y != rhs.y {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }
        let selected = candidates[candidates.count / 2]
        let depthMeters = selected.meters
        let confidence = selected.confidence

        let imageWidth = snapshot.cameraImageDimensions.width
        let imageHeight = snapshot.cameraImageDimensions.height
        guard imageWidth > 0, imageHeight > 0 else {
            return .unavailable(.invalidIntrinsics)
        }
        let intrinsics = snapshot.cameraIntrinsics.simdValue
        let scaleX = Float(width) / Float(imageWidth)
        let scaleY = Float(height) / Float(imageHeight)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        guard
            fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite,
            fx > .ulpOfOne, fy > .ulpOfOne
        else {
            return .unavailable(.invalidIntrinsics)
        }

        // Project the texel that supplied the median, rather than moving a
        // neighboring surface onto the requested center ray. ARKit camera
        // intrinsics use pixel coordinates directly (no half-texel offset).
        let u = Float(selected.x)
        let v = Float(selected.y)
        let cameraPosition = SIMD3<Float>(
            ((u - cx) / fx) * depthMeters,
            -((v - cy) / fy) * depthMeters,
            -depthMeters
        )
        let homogeneousWorld =
            snapshot.pose.cameraTransform.simdValue
            * SIMD4<Float>(cameraPosition, 1)
        guard
            homogeneousWorld.x.isFinite,
            homogeneousWorld.y.isFinite,
            homogeneousWorld.z.isFinite,
            homogeneousWorld.w.isFinite,
            abs(homogeneousWorld.w) > .ulpOfOne
        else {
            return .unavailable(.invalidIntrinsics)
        }
        let worldPosition = homogeneousWorld.xyz / homogeneousWorld.w
        guard worldPosition.x.isFinite, worldPosition.y.isFinite, worldPosition.z.isFinite else {
            return .unavailable(.invalidIntrinsics)
        }

        let uncertainty: SpatialPositionUncertainty =
            switch confidence {
            case .low: .lowConfidenceDepth
            case .medium: .mediumConfidenceDepth
            case .high: .highConfidenceDepth
            }
        return .sample(
            ARDepthSample(
                frameID: snapshot.pose.id,
                coordinateFrameID: snapshot.pose.coordinateFrameID,
                segmentID: snapshot.pose.segmentID,
                mapID: snapshot.pose.mapID,
                coordinateFrameStatus: snapshot.pose.coordinateFrameStatus,
                trackingState: snapshot.pose.trackingState,
                timestamp: snapshot.pose.timestamp,
                source: source,
                depthPixel: SIMD2<Int>(selected.x, selected.y),
                depthMeters: depthMeters,
                confidence: confidence,
                cameraPosition: cameraPosition,
                worldPosition: worldPosition,
                uncertainty: uncertainty
            )
        )
    }
}

extension SIMD4 where Scalar == Float {
    fileprivate var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}
