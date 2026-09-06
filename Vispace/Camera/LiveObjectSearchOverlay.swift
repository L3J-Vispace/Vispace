import SwiftUI
import VispaceCore

/// Image-space candidates can help a user find a visible object before a
/// durable 3D location exists. These rectangles never drive AR navigation.
struct LiveObjectSearchOverlay: View {
    @ObservedObject var perceptionController: SpatialPerceptionController
    @ObservedObject var queryController: SpatialObjectQueryController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            GeometryReader { geometry in
                if let result = queryController.latestPresentation?.result,
                   [.notFound, .lowConfidence].contains(result.status),
                   let snapshot = perceptionController.liveSearchSnapshot {
                    let matches = snapshot.matches(labels: result.matchedSemanticLabels,
                                                   now: ProcessInfo.processInfo.systemUptime)
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, detection in
                        if let rect = snapshot.viewportBounds(for: detection) {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.yellow, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                                .frame(width: rect.width * geometry.size.width,
                                       height: rect.height * geometry.size.height)
                                .position(x: rect.midX * geometry.size.width,
                                          y: rect.midY * geometry.size.height)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}
