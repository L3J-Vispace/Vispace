/*
 THESIS: A continuous floor ribbon makes the verified walking route readable.
 OWN-WORLD: Translucent cyan, fine white edges, repeated white chevrons.
 STORY: Follow the observed route around turns to its floor destination ring.
 FIRST VIEWPORT: Camera pixels remain visible through a 36 cm ribbon; no new
 panel or animation competes with the real space. The route disappears as soon
 as its controller withdraws the evidence that permits it.
 FORM: Extend the existing camera surface using the user's pinned reference.
 */
import RealityKit
import UIKit

@MainActor
enum ARNavigationRibbonRendering {
    /// One anchor and four batched meshes, regardless of the route's length.
    /// Geometry never smooths across an unverified corner or bridges a gap.
    static func makeAnchor(for path: ARIndoorNavigationPathOutput) throws -> AnchorEntity? {
        guard let geometry = ARNavigationRibbonGeometry.make(
            waypoints: path.waypoints, maximumHalfWidth: path.maximumHalfWidth
        ) else { return nil }
        let anchor = AnchorEntity(world: geometry.origin)
        anchor.name = "vispace-navigation-route"
        var surface = UnlitMaterial(color: .systemCyan)
        surface.blending = .transparent(opacity: .init(floatLiteral: 0.24))
        // Geometry faces up; keep iOS 17's default back-face culling instead
        // of depending on the material culling override added in iOS 18.
        let white = UnlitMaterial(color: .white)
        let cyan = UnlitMaterial(color: .systemCyan)
        for (name, mesh, material) in [
            ("vispace-navigation-ribbon", geometry.surface, surface),
            ("vispace-navigation-edges", geometry.borders, white),
            ("vispace-navigation-chevrons", geometry.chevrons, white),
            ("vispace-navigation-destination", geometry.destination, cyan)
        ] where !mesh.triangleIndices.isEmpty {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = MeshBuffer(mesh.positions)
            descriptor.primitives = .triangles(mesh.triangleIndices)
            let model = ModelEntity(
                mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
            model.name = name
            anchor.addChild(model)
        }
        return anchor
    }
}
