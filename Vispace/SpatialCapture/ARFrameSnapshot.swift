@preconcurrency import ARKit
import CoreVideo
import Foundation
import simd

/// Stable identity shared by a lightweight pose and its optional image snapshot.
public struct ARFrameID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
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

public enum ARLimitedTrackingReasonSnapshot: String, Sendable {
    case excessiveMotion
    case insufficientFeatures
    case initializing
    case relocalizing
    case unknown
}

public enum ARTrackingStateSnapshot: Sendable {
    case unavailable
    case limited(ARLimitedTrackingReasonSnapshot)
    case normal
}

public enum ARWorldMappingStatusSnapshot: String, Sendable {
    case notAvailable
    case limited
    case extending
    case mapped
    case unknown
}

/// Lightweight, value-only data that is safe to hand to a latest-value stream.
public struct ARPoseSnapshot: Sendable {
    public let id: ARFrameID
    public let timestamp: TimeInterval
    public let cameraTransform: Matrix4x4Snapshot
    public let trackingState: ARTrackingStateSnapshot
    public let worldMappingStatus: ARWorldMappingStatusSnapshot

    public init(
        id: ARFrameID,
        timestamp: TimeInterval,
        cameraTransform: Matrix4x4Snapshot,
        trackingState: ARTrackingStateSnapshot,
        worldMappingStatus: ARWorldMappingStatusSnapshot
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.trackingState = trackingState
        self.worldMappingStatus = worldMappingStatus
    }
}

/// Owns a deep copy of a Core Video buffer. The copy is never mutated after
/// initialization. `CVPixelBuffer` has no checked Sendable conformance, so this
/// narrowly scoped wrapper documents and enforces unique ownership by API.
public final class ImmutablePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    public let dimensions: ImageDimensions
    public let pixelFormat: OSType

    fileprivate init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        dimensions = ImageDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    }
}

public struct ARDepthSnapshot: Sendable {
    public let depthMap: ImmutablePixelBuffer
    public let confidenceMap: ImmutablePixelBuffer?

    public init(
        depthMap: ImmutablePixelBuffer,
        confidenceMap: ImmutablePixelBuffer?
    ) {
        self.depthMap = depthMap
        self.confidenceMap = confidenceMap
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
    public let sceneDepth: ARDepthSnapshot?
    public let smoothedSceneDepth: ARDepthSnapshot?

    public init(
        pose: ARPoseSnapshot,
        imageOrientation: FrameImageOrientation,
        capturedImage: ImmutablePixelBuffer,
        cameraIntrinsics: Matrix3x3Snapshot,
        cameraImageDimensions: ImageDimensions,
        sceneDepth: ARDepthSnapshot?,
        smoothedSceneDepth: ARDepthSnapshot?
    ) {
        self.pose = pose
        self.imageOrientation = imageOrientation
        self.capturedImage = capturedImage
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraImageDimensions = cameraImageDimensions
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
}

/// Copies all data needed after an ARSession callback returns. The source
/// `ARFrame` itself never crosses a concurrency boundary.
public struct ARFrameSnapshotAdapter: Sendable {
    public init() {}

    public func makePose(from frame: ARFrame, id: ARFrameID = ARFrameID()) -> ARPoseSnapshot {
        ARPoseSnapshot(
            id: id,
            timestamp: frame.timestamp,
            cameraTransform: Matrix4x4Snapshot(frame.camera.transform),
            trackingState: trackingState(from: frame.camera.trackingState),
            worldMappingStatus: mappingStatus(from: frame.worldMappingStatus)
        )
    }

    public func makeSnapshot(
        from frame: ARFrame,
        id: ARFrameID = ARFrameID(),
        imageOrientation: FrameImageOrientation
    ) throws -> ARFrameSnapshot {
        let pose = makePose(from: frame, id: id)
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
            sceneDepth: sceneDepth,
            smoothedSceneDepth: smoothedSceneDepth
        )
    }

    private func copyDepth(_ source: ARDepthData?) throws -> ARDepthSnapshot? {
        guard let source else {
            return nil
        }

        let depthMap = try copyPixelBuffer(source.depthMap)
        let confidenceMap = try source.confidenceMap.map { confidenceMap in
            try copyPixelBuffer(confidenceMap)
        }
        return ARDepthSnapshot(
            depthMap: depthMap,
            confidenceMap: confidenceMap
        )
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
