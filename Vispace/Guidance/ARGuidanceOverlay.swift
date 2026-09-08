import SwiftUI
import VispaceCore

struct ARGuidanceOverlay: View {
    @ObservedObject var controller: ARGuidanceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let target = controller.target,
            let projection = controller.latestProjection
        {
            GeometryReader { geometry in
                ZStack {
                    if projection.hasArrived {
                        arrivedMarker
                    } else if !projection.isWithinForwardView {
                        directionalArrow(projection, in: geometry.size)
                    }

                    VStack {
                        guidanceLabel(target: target, projection: projection)
                        Spacer()
                    }
                    .padding(.top, max(12, geometry.safeAreaInsets.top + 8))
                    .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    accessibilityDescription(target: target, projection: projection)
                )
            }
            .allowsHitTesting(false)
        }
    }

    private var arrivedMarker: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .yellow)
            Text("guidance.arrived")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
    }

    private func directionalArrow(
        _ projection: ARGuidanceProjection,
        in size: CGSize
    ) -> some View {
        Image(systemName: "location.north.circle.fill")
            .font(.system(size: 68, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, .yellow)
            .rotationEffect(.radians(projection.bearingRadians))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: projection.bearingRadians
            )
            .position(x: size.width / 2, y: size.height * 0.43)
    }

    private func guidanceLabel(
        target: ARGuidanceTarget,
        projection: ARGuidanceProjection
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: target.representsLastSeenLocation ? "clock.arrow.circlepath" : "scope")
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(ARGuidancePresentation.displayLabel(for: target))
                    .font(.headline)
                    .lineLimit(1)
                Text(distanceText(projection.distanceMeters))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.82))
            }

            confidenceBadge(target.confidenceGrade)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.black.opacity(0.7), in: Capsule())
        .frame(maxWidth: 420)
    }

    private func confidenceBadge(_ grade: ConfidenceGrade) -> some View {
        Text(confidenceText(grade))
            .font(.caption2.weight(.bold))
            .foregroundStyle(grade == .high ? .black : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                grade == .high ? Color.yellow : Color.orange,
                in: Capsule()
            )
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1 {
            return String(
                format: String(localized: "guidance.distance.centimeters.format"),
                Int((meters * 100).rounded())
            )
        }
        return String(
            format: String(localized: "guidance.distance.meters.format"),
            meters
        )
    }

    private func confidenceText(_ grade: ConfidenceGrade) -> String {
        switch grade {
        case .high:
            return String(localized: "confidence.high")
        case .medium:
            return String(localized: "confidence.medium")
        case .low:
            return String(localized: "confidence.low")
        }
    }

    private func accessibilityDescription(
        target: ARGuidanceTarget,
        projection: ARGuidanceProjection
    ) -> String {
        if projection.hasArrived {
            return String(
                format: String(localized: "guidance.accessibility.arrived.format"),
                ARGuidancePresentation.displayLabel(for: target)
            )
        }
        return String(
            format: String(localized: "guidance.accessibility.direction.format"),
            ARGuidancePresentation.displayLabel(for: target),
            localizedDirection(projection.direction),
            distanceText(projection.distanceMeters)
        )
    }

    private func localizedDirection(_ direction: ARGuidanceDirection) -> String {
        String(localized: String.LocalizationValue("guidance.direction.\(direction.rawValue)"))
    }
}

/// Names belong to presentation; the target's semantic label remains unchanged
/// for source-record validation, identity matching, and navigation evidence.
enum ARGuidancePresentation {
    static func displayLabel(for target: ARGuidanceTarget) -> String {
        if let source = target.sourceMetadata,
            source.object.id == target.objectID,
            source.object.semanticLabel == target.semanticLabel,
            let displayName = source.object.displayName {
            return displayName
        }
        if target.semanticLabel == UserObjectRegistrationAccumulator.semanticLabel {
            return "직접 등록한 물체"
        }
        return ObjectSemanticCatalog.default.displayName(for: target.semanticLabel)
    }
}
