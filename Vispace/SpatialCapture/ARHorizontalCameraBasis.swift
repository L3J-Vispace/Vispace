import Foundation

/// A gravity-level heading for world-aligned AR sessions. ARKit's raw camera
/// +X follows the device's long axis, so it is not portrait screen-right.
/// Project optical forward (-Z) onto the ground and derive right as forward
/// cross world-up. Leave the original camera transform intact for depth work.
struct ARHorizontalCameraBasis: Sendable {
    let forwardX: Double
    let forwardZ: Double
    let rightX: Double
    let rightZ: Double

    init?(
        cameraTransform: Matrix4x4Snapshot,
        minimumHorizontalLength: Double = 0.001
    ) {
        let forward = -cameraTransform.column2
        let length = hypot(Double(forward.x), Double(forward.z))
        let columns = [
            cameraTransform.column0, cameraTransform.column1,
            cameraTransform.column2, cameraTransform.column3,
        ]
        guard columns.allSatisfy({ column in (0..<4).allSatisfy { column[$0].isFinite } }),
            minimumHorizontalLength.isFinite, minimumHorizontalLength > 0,
            length.isFinite, length >= minimumHorizontalLength
        else { return nil }

        forwardX = Double(forward.x) / length
        forwardZ = Double(forward.z) / length
        rightX = -forwardZ
        rightZ = forwardX
    }

    var yawRadians: Double { atan2(rightZ, rightX) }
}
