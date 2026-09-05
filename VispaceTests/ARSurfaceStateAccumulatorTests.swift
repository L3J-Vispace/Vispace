import XCTest
import simd

@testable import Vispace

final class ARSurfaceStateAccumulatorTests: XCTestCase {
    func testUnrelatedDeltaAndAuthoritativeReplayDoNotRefreshOldSurface() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .confirmed)
        let firstID = UUID()
        let secondID = UUID()
        func observation(_ id: UUID, at timestamp: TimeInterval) -> ARSurfaceObservation {
            ARSurfaceObservation(
                coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
                mapID: identity.mapID, coordinateFrameStatus: identity.status,
                timestamp: timestamp, change: .updated,
                payload: .plane(ARPlaneObservationSnapshot(
                    anchorID: id, transform: Matrix4x4Snapshot(matrix_identity_float4x4), center: .zero,
                    extent: SIMD3<Float>(2, 0, 2), extentRotationOnYAxis: 0, boundaryVertices: [],
                    alignment: .horizontal, classification: .floor
                ))
            )
        }
        _ = accumulator.applying([observation(firstID, at: 1)])
        let updated = try XCTUnwrap(accumulator.applying([observation(secondID, at: 10)]))
        XCTAssertEqual(updated.anchorObservedAt[firstID], 1)
        XCTAssertFalse(updated.hasFreshSurfaces(at: 10, maximumAge: 5))
        let replay = try XCTUnwrap(accumulator.applying(ARSurfaceObservationBatch(
            captureIdentity: identity, timestamp: 11,
            observations: [observation(firstID, at: 11), observation(secondID, at: 11)],
            failures: [], isAuthoritative: true
        )))
        XCTAssertEqual(replay.anchorObservedAt[firstID], 1)
        XCTAssertEqual(replay.anchorObservedAt[secondID], 10)
        XCTAssertNil(accumulator.applying([observation(firstID, at: 9)]))
    }

    func testAuthoritativeStatePreservesRemovalAcrossDroppedRevisions() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let plane = ARPlaneObservationSnapshot(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(2, 0, 3),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-1, 0, -1.5),
                SIMD3<Float>(1, 0, -1.5),
                SIMD3<Float>(1, 0, 1.5),
                SIMD3<Float>(-1, 0, 1.5),
            ],
            alignment: .horizontal,
            classification: .floor
        )
        let added = ARSurfaceObservation(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            timestamp: 1,
            change: .added,
            payload: .plane(plane)
        )
        let removed = ARSurfaceObservation(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            timestamp: 2,
            change: .removed,
            payload: .removed(anchorID: anchorID, kind: .plane)
        )

        let first = try XCTUnwrap(accumulator.applying([added]))
        let final = try XCTUnwrap(accumulator.applying([removed]))

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.planes[anchorID], plane)
        XCTAssertEqual(final.revision, 2)
        XCTAssertTrue(final.planes.isEmpty)
    }

    func testNewCoordinateFrameResetsSurfaceStateAndRevision() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let firstIdentity = ARCaptureIdentity(status: .confirmed)
        let secondIdentity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let firstPlane = ARPlaneObservationSnapshot(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(1, 0, 1),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-0.5, 0, -0.5),
                SIMD3<Float>(0.5, 0, -0.5),
                SIMD3<Float>(0.5, 0, 0.5),
                SIMD3<Float>(-0.5, 0, 0.5),
            ],
            alignment: .horizontal,
            classification: .floor
        )
        _ = accumulator.applying([
            ARSurfaceObservation(
                coordinateFrameID: firstIdentity.coordinateFrameID,
                segmentID: firstIdentity.segmentID,
                mapID: firstIdentity.mapID,
                coordinateFrameStatus: firstIdentity.status,
                timestamp: 1,
                change: .added,
                payload: .plane(firstPlane)
            )
        ])
        let second = try XCTUnwrap(
            accumulator.applying([
                ARSurfaceObservation(
                    coordinateFrameID: secondIdentity.coordinateFrameID,
                    segmentID: secondIdentity.segmentID,
                    mapID: secondIdentity.mapID,
                    coordinateFrameStatus: secondIdentity.status,
                    timestamp: 2,
                    change: .removed,
                    payload: .removed(anchorID: UUID(), kind: .mesh)
                )
            ])
        )

        XCTAssertEqual(second.coordinateFrameID, secondIdentity.coordinateFrameID)
        XCTAssertEqual(second.revision, 1)
        XCTAssertTrue(second.planes.isEmpty)
    }

    func testFailedAnchorMarksStateIncompleteUntilAValidUpdateArrives() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let plane = ARPlaneObservationSnapshot(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(1, 0, 1),
            extentRotationOnYAxis: 0,
            boundaryVertices: [],
            alignment: .horizontal,
            classification: .floor
        )
        let observation = ARSurfaceObservation(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            timestamp: 1,
            change: .added,
            payload: .plane(plane)
        )
        _ = accumulator.applying([observation])

        let incomplete = try XCTUnwrap(
            accumulator.applying(
                ARSurfaceObservationBatch(
                    captureIdentity: identity,
                    timestamp: 2,
                    observations: [],
                    failures: [
                        ARSurfaceObservationFailure(
                            anchorID: anchorID,
                            error: .invalidVertexBuffer
                        )
                    ]
                )
            )
        )
        // Replaying geometry from before the failed read cannot clear the
        // failure or attest that the anchor has been observed again.
        XCTAssertNil(accumulator.applying([observation]))
        let recovered = try XCTUnwrap(accumulator.applying([
            ARSurfaceObservation(
                coordinateFrameID: identity.coordinateFrameID,
                segmentID: identity.segmentID,
                mapID: identity.mapID,
                coordinateFrameStatus: identity.status,
                timestamp: 3,
                change: .updated,
                payload: .plane(plane)
            )
        ]))

        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.unresolvedFailures.first?.anchorID, anchorID)
        XCTAssertEqual(incomplete.planes[anchorID], plane)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.anchorObservedAt[anchorID], 3)
    }

    func testAuthoritativeSnapshotRemovesAnchorsMissingFromLatestFrame() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let plane = ARPlaneObservationSnapshot(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(1, 0, 1),
            extentRotationOnYAxis: 0,
            boundaryVertices: [],
            alignment: .horizontal,
            classification: .floor
        )
        _ = accumulator.applying([
            ARSurfaceObservation(
                coordinateFrameID: identity.coordinateFrameID,
                segmentID: identity.segmentID,
                mapID: identity.mapID,
                coordinateFrameStatus: identity.status,
                timestamp: 1,
                change: .added,
                payload: .plane(plane)
            )
        ])

        let empty = try XCTUnwrap(
            accumulator.applying(
                ARSurfaceObservationBatch(
                    captureIdentity: identity,
                    timestamp: 2,
                    observations: [],
                    failures: [],
                    isAuthoritative: true
                )
            )
        )

        XCTAssertEqual(empty.revision, 2)
        XCTAssertTrue(empty.planes.isEmpty)
        XCTAssertTrue(empty.meshes.isEmpty)
        XCTAssertTrue(empty.isComplete)
    }

    func testRelocalizingSurfaceStateFailsClosedEvenWithoutGeometryFailures() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .relocalizing)

        let state = try XCTUnwrap(
            accumulator.applying(
                ARSurfaceObservationBatch(
                    captureIdentity: identity,
                    timestamp: 2,
                    observations: [],
                    failures: [],
                    isAuthoritative: true
                )
            )
        )

        XCTAssertTrue(state.isCurrentSessionData)
        XCTAssertFalse(state.isComplete)
    }

    func testInvalidatedStateClearsGeometryAndFailsClosed() throws {
        let accumulator = ARSurfaceStateAccumulator()
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let plane = ARPlaneObservationSnapshot(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(1, 0, 1),
            extentRotationOnYAxis: 0,
            boundaryVertices: [],
            alignment: .horizontal,
            classification: .floor
        )
        _ = accumulator.applying([
            ARSurfaceObservation(
                coordinateFrameID: identity.coordinateFrameID,
                segmentID: identity.segmentID,
                mapID: identity.mapID,
                coordinateFrameStatus: identity.status,
                timestamp: 1,
                change: .added,
                payload: .plane(plane)
            )
        ])

        let invalid = accumulator.invalidated(
            captureIdentity: identity,
            timestamp: 2
        )

        XCTAssertFalse(invalid.isCurrentSessionData)
        XCTAssertFalse(invalid.isComplete)
        XCTAssertEqual(invalid.revision, 0)
        XCTAssertTrue(invalid.planes.isEmpty)
        XCTAssertTrue(invalid.meshes.isEmpty)
    }

    func testRawMeshBytesDecodeOffTheARKitDelegateQueue() throws {
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let raw = makeRawMeshCapture(
            anchorID: anchorID,
            triangleIndices: [0, 1, 2]
        )

        let batch = ARSurfaceObservationAdapter().makeObservations(
            from: ARSurfaceRawCaptureBatch(
                captureIdentity: identity,
                timestamp: 3,
                captures: [
                    ARSurfaceRawCapture(
                        anchorID: anchorID,
                        change: .updated,
                        payload: .mesh(raw)
                    )
                ],
                failures: [],
                isAuthoritative: true
            )
        )

        XCTAssertTrue(batch.failures.isEmpty)
        let observation = try XCTUnwrap(batch.observations.first)
        guard case .mesh(let mesh) = observation.payload else {
            return XCTFail("Expected a decoded mesh observation.")
        }
        XCTAssertEqual(
            mesh.vertices,
            [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        )
        XCTAssertEqual(mesh.triangleIndices, [0, 1, 2])
    }

    func testRawMeshRejectsTriangleIndexOutsideCopiedVertices() {
        let identity = ARCaptureIdentity(status: .confirmed)
        let anchorID = UUID()
        let raw = makeRawMeshCapture(
            anchorID: anchorID,
            triangleIndices: [0, 1, 3]
        )

        let batch = ARSurfaceObservationAdapter().makeObservations(
            from: ARSurfaceRawCaptureBatch(
                captureIdentity: identity,
                timestamp: 4,
                captures: [
                    ARSurfaceRawCapture(
                        anchorID: anchorID,
                        change: .updated,
                        payload: .mesh(raw)
                    )
                ],
                failures: [],
                isAuthoritative: true
            )
        )

        XCTAssertTrue(batch.observations.isEmpty)
        XCTAssertEqual(
            batch.failures,
            [ARSurfaceObservationFailure(anchorID: anchorID, error: .invalidFaceBuffer)]
        )
    }

    private func makeRawMeshCapture(
        anchorID: UUID,
        triangleIndices: [UInt16]
    ) -> ARMeshRawCapture {
        var vertices = Data([0xFF])
        for vertex in [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
        ] {
            append(vertex.x, to: &vertices)
            append(vertex.y, to: &vertices)
            append(vertex.z, to: &vertices)
            vertices.append(contentsOf: [0, 0, 0, 0])
        }
        var faces = Data()
        for index in triangleIndices {
            append(index, to: &faces)
        }
        return ARMeshRawCapture(
            anchorID: anchorID,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            vertices: ARGeometryRawSource(
                data: vertices,
                offset: 1,
                stride: 16,
                count: 3
            ),
            faces: ARGeometryRawFaces(
                data: faces,
                faceCount: 1,
                indexCountPerPrimitive: 3,
                bytesPerIndex: 2
            ),
            classifications: nil
        )
    }

    private func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
