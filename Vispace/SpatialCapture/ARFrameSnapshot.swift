@preconcurrency import ARKit
import CoreVideo
import Foundation
import UIKit
import VispaceCore
import simd

/// Stable identity shared by a lightweight pose and its optional image snapshot.
public struct ARFrameID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identifies the exact ARSession attachment and run that produced a frame.
/// Coordinate-frame identifiers can intentionally survive relocalization, so
/// they are not sufficient on their own to reject buffered work from an older
/// session run.
public struct ARSessionFrameToken: Equatable, Hashable, Sendable {
    public let sessionRunGeneration: UInt64
    public let attachmentEpoch: UInt64

    public init(sessionRunGeneration: UInt64, attachmentEpoch: UInt64) {
        self.sessionRunGeneration = sessionRunGeneration
        self.attachmentEpoch = attachmentEpoch
    }
}

/// EXIF orientation values used by Vision. The AR layer receives this value
/// from the presentation layer instead of reading UIKit state off the main actor.
public enum FrameImageOrientation: UInt32, CaseIterable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8
}

public struct ImageDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Matrix3x3Snapshot: Equatable, Sendable {
    public let column0: SIMD3<Float>
    public let column1: SIMD3<Float>
    public let column2: SIMD3<Float>

    public init(_ value: simd_float3x3) {
        column0 = value.columns.0
        column1 = value.columns.1
        column2 = value.columns.2
    }

    public var simdValue: simd_float3x3 {
        simd_float3x3(columns: (column0, column1, column2))
    }
}

public struct Matrix4x4Snapshot: Equatable, Sendable {
    public let column0: SIMD4<Float>
    public let column1: SIMD4<Float>
    public let column2: SIMD4<Float>
    public let column3: SIMD4<Float>

    public init(_ value: simd_float4x4) {
        column0 = value.columns.0
        column1 = value.columns.1
        column2 = value.columns.2
        column3 = value.columns.3
    }

    public var simdValue: simd_float4x4 {
        simd_float4x4(columns: (column0, column1, column2, column3))
    }
}

public enum ARLimitedTrackingReasonSnapshot: String, Equatable, Hashable, Sendable {
    case excessiveMotion
    case insufficientFeatures
    case initializing
    case relocalizing
    case unknown
}

public enum ARTrackingStateSnapshot: Equatable, Hashable, Sendable {
    case unavailable
    case limited(ARLimitedTrackingReasonSnapshot)
    case normal
}

public enum ARWorldMappingStatusSnapshot: String, Equatable, Hashable, Sendable {
    case notAvailable
    case limited
    case extending
    case mapped
    case unknown
}

/// Lightweight, value-only data that is safe to hand to a latest-value stream.
public struct ARPoseSnapshot: Equatable, Sendable {
    public let id: ARFrameID
    public let sessionToken: ARSessionFrameToken
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let coordinateFrameStatus: ARCaptureIdentity.Status
    /// Wall-clock capture time used for durable last-seen ordering across
    /// launches. `timestamp` remains ARKit's monotonic session time.
    public let capturedAt: TimeInterval
    public let timestamp: TimeInterval
    public let cameraTransform: Matrix4x4Snapshot
    public let trackingState: ARTrackingStateSnapshot
    public let worldMappingStatus: ARWorldMappingStatusSnapshot

    public init(
        id: ARFrameID,
        sessionToken: ARSessionFrameToken,
        coordinateFrameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        mapID: MapID?,
        coordinateFrameStatus: ARCaptureIdentity.Status,
        capturedAt: TimeInterval,
        timestamp: TimeInterval,
        cameraTransform: Matrix4x4Snapshot,
        trackingState: ARTrackingStateSnapshot,
        worldMappingStatus: ARWorldMappingStatusSnapshot
    ) {
        self.id = id
        self.sessionToken = sessionToken
        self.coordinateFrameID = coordinateFrameID
        self.segmentID = segmentID
        self.mapID = mapID
        self.coordinateFrameStatus = coordinateFrameStatus
        self.capturedAt = capturedAt
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.trackingState = trackingState
        self.worldMappingStatus = worldMappingStatus
    }
}

public enum FrameInterfaceOrientation: String, CaseIterable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    fileprivate var uiInterfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

public struct ViewportSizeSnapshot: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isUsable: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    fileprivate var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

public struct FrameDisplayGeometry: Equatable, Sendable {
    public let orientation: FrameInterfaceOrientation
    public let viewportSize: ViewportSizeSnapshot

    public init(
        orientation: FrameInterfaceOrientation,
        viewportSize: ViewportSizeSnapshot
    ) {
        self.orientation = orientation
        self.viewportSize = viewportSize
    }
}

public struct AffineTransformSnapshot: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(_ transform: CGAffineTransform) {
        a = transform.a
        b = transform.b
        c = transform.c
        d = transform.d
        tx = transform.tx
        ty = transform.ty
    }

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

public struct ARDisplayTransformSnapshot: Equatable, Sendable {
    /// Transform from normalized camera-image coordinates into normalized
    /// viewport coordinates for the recorded orientation and viewport size.
    public let imageToViewport: AffineTransformSnapshot
    public let geometry: FrameDisplayGeometry

    public init(imageToViewport: CGAffineTransform, geometry: FrameDisplayGeometry) {
        self.imageToViewport = AffineTransformSnapshot(imageToViewport)
        self.geometry = geometry
    }
}

/// Owns a deep copy of a Core Video buffer. The copy is never mutated after
/// initialization. `CVPixelBuffer` has no checked Sendable conformance, so this
/// narrowly scoped wrapper documents and enforces unique ownership by API.
public final class ImmutablePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    public let dimensions: ImageDimensions
    public let pixelFormat: OSType

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        dimensions = ImageDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    }
}

public struct ARDepthSnapshot: Equatable, Sendable {
    public let dimensions: ImageDimensions
    public let depthMeters: [Float]
    public let confidence: [UInt8]?

    public init(
        dimensions: ImageDimensions,
        depthMeters: [Float],
        confidence: [UInt8]?
    ) {
        self.dimensions = dimensions
        self.depthMeters = depthMeters
        self.confidence = confidence
    }
}

/// In-memory-only perception input. This type deliberately has no Codable or
/// persistence conformance: raw camera pixels must never be written to disk.
public struct ARFrameSnapshot: Sendable {
    public let pose: ARPoseSnapshot
    public let imageOrientation: FrameImageOrientation
    public let capturedImage: ImmutablePixelBuffer
    public let cameraIntrinsics: Matrix3x3Snapshot
    public let cameraImageDimensions: ImageDimensions
    public let displayTransform: ARDisplayTransformSnapshot?
    public let sceneDepth: ARDepthSnapshot?
    public let smoothedSceneDepth: ARDepthSnapshot?

    public init(
        pose: ARPoseSnapshot,
        imageOrientation: FrameImageOrientation,
        capturedImage: ImmutablePixelBuffer,
        cameraIntrinsics: Matrix3x3Snapshot,
        cameraImageDimensions: ImageDimensions,
        displayTransform: ARDisplayTransformSnapshot?,
        sceneDepth: ARDepthSnapshot?,
        smoothedSceneDepth: ARDepthSnapshot?
    ) {
        self.pose = pose
        self.imageOrientation = imageOrientation
        self.capturedImage = capturedImage
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraImageDimensions = cameraImageDimensions
        self.displayTransform = displayTransform
        self.sceneDepth = sceneDepth
        self.smoothedSceneDepth = smoothedSceneDepth
    }
}

public enum ARFrameSnapshotError: Error, Equatable, Sendable {
    case pixelBufferCreationFailed(CVReturn)
    case sourceLockFailed(CVReturn)
    case destinationLockFailed(CVReturn)
    case planeCountMismatch(source: Int, destination: Int)
    case destinationPlaneTooSmall(
        plane: Int,
        requiredWidth: Int,
        actualWidth: Int,
        requiredHeight: Int,
        actualHeight: Int
    )
    case destinationRowBytesTooSmall(plane: Int, required: Int, actual: Int)
    case missingBaseAddress(plane: Int)
    case unsupportedDepthPixelFormat(OSType)
    case unsupportedConfidencePixelFormat(OSType)
    case depthBufferShapeMismatch
}

/// Copies all data needed after an ARSession callback returns. The source
/// `ARFrame` itself never crosses a concurrency boundary.
public struct ARFrameSnapshotAdapter: Sendable {
    public init() {}

    public func makePose(
        from frame: ARFrame,
        id: ARFrameID = ARFrameID(),
        sessionToken: ARSessionFrameToken,
        capturedAt: TimeInterval,
        captureIdentity: ARCaptureIdentity
    ) -> ARPoseSnapshot {
        ARPoseSnapshot(
            id: id,
            sessionToken: sessionToken,
            coordinateFrameID: captureIdentity.coordinateFrameID,
            segmentID: captureIdentity.segmentID,
            mapID: captureIdentity.mapID,
            coordinateFrameStatus: captureIdentity.status,
            capturedAt: capturedAt,
            timestamp: frame.timestamp,
            cameraTransform: Matrix4x4Snapshot(frame.camera.transform),
            trackingState: trackingState(from: frame.camera.trackingState),
            worldMappingStatus: mappingStatus(from: frame.worldMappingStatus)
        )
    }

    public func makeSnapshot(
        from frame: ARFrame,
        id: ARFrameID = ARFrameID(),
        imageOrientation: FrameImageOrientation,
        sessionToken: ARSessionFrameToken,
        capturedAt: TimeInterval,
        captureIdentity: ARCaptureIdentity,
        displayGeometry: FrameDisplayGeometry?
    ) throws -> ARFrameSnapshot {
        let pose = makePose(
            from: frame,
            id: id,
            sessionToken: sessionToken,
            capturedAt: capturedAt,
            captureIdentity: captureIdentity
        )
        let image = try copyPixelBuffer(frame.capturedImage)
        let sceneDepth = try copyDepth(frame.sceneDepth)
        let smoothedSceneDepth = try copyDepth(frame.smoothedSceneDepth)

        return ARFrameSnapshot(
            pose: pose,
            imageOrientation: imageOrientation,
            capturedImage: image,
            cameraIntrinsics: Matrix3x3Snapshot(frame.camera.intrinsics),
            cameraImageDimensions: ImageDimensions(
                width: Int(frame.camera.imageResolution.width),
                height: Int(frame.camera.imageResolution.height)
            ),
            displayTransform: displayGeometry.flatMap { geometry in
                guard geometry.viewportSize.isUsable else {
                    return nil
                }
                return ARDisplayTransformSnapshot(
                    imageToViewport: frame.displayTransform(
                        for: geometry.orientation.uiInterfaceOrientation,
                        viewportSize: geometry.viewportSize.cgSize
                    ),
                    geometry: geometry
                )
            },
            sceneDepth: sceneDepth,
            smoothedSceneDepth: smoothedSceneDepth
        )
    }

    private func copyDepth(_ source: ARDepthData?) throws -> ARDepthSnapshot? {
        guard let source else {
            return nil
        }

        let depthMap = source.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            throw ARFrameSnapshotError.unsupportedDepthPixelFormat(
                CVPixelBufferGetPixelFormatType(depthMap)
            )
        }
        let depthMeters: [Float] = try copySinglePlaneValues(
            from: depthMap,
            elementType: Float.self
        )
        let confidence: [UInt8]?
        if let confidenceMap = source.confidenceMap {
            guard CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 else {
                throw ARFrameSnapshotError.unsupportedConfidencePixelFormat(
                    CVPixelBufferGetPixelFormatType(confidenceMap)
                )
            }
            guard
                CVPixelBufferGetWidth(confidenceMap) == width,
                CVPixelBufferGetHeight(confidenceMap) == height
            else {
                throw ARFrameSnapshotError.depthBufferShapeMismatch
            }
            confidence = try copySinglePlaneValues(
                from: confidenceMap,
                elementType: UInt8.self
            )
        } else {
            confidence = nil
        }
        return ARDepthSnapshot(
            dimensions: ImageDimensions(width: width, height: height),
            depthMeters: depthMeters,
            confidence: confidence
        )
    }

    private func copySinglePlaneValues<Element>(
        from source: CVPixelBuffer,
        elementType: Element.Type
    ) throws -> [Element] {
        let lockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw ARFrameSnapshotError.sourceLockFailed(lockStatus)
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let requiredRowBytes = width * MemoryLayout<Element>.stride
        guard bytesPerRow >= requiredRowBytes else {
            throw ARFrameSnapshotError.destinationRowBytesTooSmall(
                plane: 0,
                required: requiredRowBytes,
                actual: bytesPerRow
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(source) else {
            throw ARFrameSnapshotError.missingBaseAddress(plane: 0)
        }

        var values = [Element]()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let rowAddress = baseAddress.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: Element.self)
            values.append(contentsOf: UnsafeBufferPointer(start: rowAddress, count: width))
        }
        return values
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) throws -> ImmutablePixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes: CFDictionary =
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary

        var destination: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &destination
        )
        guard createStatus == kCVReturnSuccess, let destination else {
            throw ARFrameSnapshotError.pixelBufferCreationFailed(createStatus)
        }

        let sourcePlaneCount = CVPixelBufferGetPlaneCount(source)
        let destinationPlaneCount = CVPixelBufferGetPlaneCount(destination)
        guard sourcePlaneCount == destinationPlaneCount else {
            throw ARFrameSnapshotError.planeCountMismatch(
                source: sourcePlaneCount,
                destination: destinationPlaneCount
            )
        }

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw ARFrameSnapshotError.sourceLockFailed(sourceLockStatus)
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            throw ARFrameSnapshotError.destinationLockFailed(destinationLockStatus)
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(destination, []) }

        if sourcePlaneCount == 0 {
            try copyPlane(
                source: source,
                destination: destination,
                plane: nil
            )
        } else {
            for plane in 0..<sourcePlaneCount {
                try copyPlane(
                    source: source,
                    destination: destination,
                    plane: plane
                )
            }
        }

        CVBufferPropagateAttachments(source, destination)
        return ImmutablePixelBuffer(pixelBuffer: destination)
    }

    private func copyPlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int?
    ) throws {
        let sourceBaseAddress: UnsafeMutableRawPointer?
        let destinationBaseAddress: UnsafeMutableRawPointer?
        let sourceBytesPerRow: Int
        let destinationBytesPerRow: Int
        let sourceWidth: Int
        let destinationWidth: Int
        let sourceHeight: Int
        let destinationHeight: Int

        if let plane {
            sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane)
            destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
            destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
            sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
            destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
        } else {
            sourceBaseAddress = CVPixelBufferGetBaseAddress(source)
            destinationBaseAddress = CVPixelBufferGetBaseAddress(destination)
            sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            sourceWidth = CVPixelBufferGetWidth(source)
            destinationWidth = CVPixelBufferGetWidth(destination)
            sourceHeight = CVPixelBufferGetHeight(source)
            destinationHeight = CVPixelBufferGetHeight(destination)
        }

        let planeIndex = plane ?? 0
        guard destinationWidth >= sourceWidth, destinationHeight >= sourceHeight else {
            throw ARFrameSnapshotError.destinationPlaneTooSmall(
                plane: planeIndex,
                requiredWidth: sourceWidth,
                actualWidth: destinationWidth,
                requiredHeight: sourceHeight,
                actualHeight: destinationHeight
            )
        }
        // Copying a whole source row preserves multi-byte and bi-planar sample
        // layouts without guessing bytes-per-pixel from the OSType. Requiring
        // the destination stride to hold that row fails closed before writes.
        guard destinationBytesPerRow >= sourceBytesPerRow else {
            throw ARFrameSnapshotError.destinationRowBytesTooSmall(
                plane: planeIndex,
                required: sourceBytesPerRow,
                actual: destinationBytesPerRow
            )
        }
        guard let sourceBaseAddress, let destinationBaseAddress else {
            throw ARFrameSnapshotError.missingBaseAddress(plane: planeIndex)
        }

        for row in 0..<sourceHeight {
            let sourceRow = sourceBaseAddress.advanced(by: row * sourceBytesPerRow)
            let destinationRow = destinationBaseAddress.advanced(by: row * destinationBytesPerRow)
            destinationRow.copyMemory(from: sourceRow, byteCount: sourceBytesPerRow)
        }
    }

    private func trackingState(from state: ARCamera.TrackingState) -> ARTrackingStateSnapshot {
        switch state {
        case .notAvailable:
            return .unavailable
        case .limited(let reason):
            let snapshotReason: ARLimitedTrackingReasonSnapshot =
                switch reason {
                case .excessiveMotion: .excessiveMotion
                case .insufficientFeatures: .insufficientFeatures
                case .initializing: .initializing
                case .relocalizing: .relocalizing
                @unknown default: .unknown
                }
            return .limited(snapshotReason)
        case .normal:
            return .normal
        }
    }

    private func mappingStatus(from status: ARFrame.WorldMappingStatus) -> ARWorldMappingStatusSnapshot {
        switch status {
        case .notAvailable: .notAvailable
        case .limited: .limited
        case .extending: .extending
        case .mapped: .mapped
        @unknown default: .unknown
        }
    }
}
