import RealityKit

@MainActor
protocol CameraSessionControlling: AnyObject {
    func attach(to view: ARView)
    func detach(from view: ARView)
    func activate()
    func deactivate()
    func enterBackground()
    func setDisplayGeometry(_ geometry: FrameDisplayGeometry)
}
