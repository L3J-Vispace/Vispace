import SwiftUI
import VispaceCore

struct SpatialQueryPanel: View {
    @ObservedObject var queryController: SpatialObjectQueryController
    @ObservedObject var relationQueryController: SpatialRelationQueryController
    @ObservedObject var placementController: FurniturePlacementController
    @ObservedObject var navigationController: IndoorNavigationController
    let onManageData: () -> Void
    @FocusState private var queryIsFocused: Bool
    @State private var query = ""
    @State private var rejection: SpatialCommandRejection?

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            if let rejection {
                messageCard(message: rejectionMessage(rejection), systemImage: "info.circle.fill")
            } else if let presentation = navigationController.latestPresentation {
                messageCard(
                    message: presentation.message,
                    systemImage: presentation.canRenderPath
                        ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                        : "exclamationmark.triangle.fill"
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let presentation = placementController.latestPresentation {
                messageCard(
                    message: presentation.message,
                    systemImage: presentation.disposition == .feasible
                        ? "checkmark.seal.fill"
                        : "info.circle.fill"
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let presentation = relationQueryController.latestPresentation {
                messageCard(
                    message: presentation.message,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let relationMessage = relationStateMessage {
                messageCard(
                    message: relationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let presentation = queryController.latestPresentation {
                resultCard(presentation)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if case .failed(let message) = queryController.state {
                messageCard(message: message, systemImage: "exclamationmark.triangle.fill")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("query.placeholder", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
                    .submitLabel(.search)
                    .focused($queryIsFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("vispace.query.field")

                Button {
                    queryIsFocused = false
                    dismissAll()
                    onManageData()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("data.title"))
                .accessibilityIdentifier("vispace.data.settings")

                Menu {
                    placementButton(title: "소파", kind: .sofa)
                    placementButton(title: "침대", kind: .bed)
                    placementButton(title: "책상", kind: .desk)
                } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.title3)
                }
                .accessibilityLabel("가구 배치 확인")
                .accessibilityIdentifier("vispace.placement.menu")

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("query.searching"))
                } else if !query.isEmpty {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("query.submit"))
                    .accessibilityIdentifier("vispace.query.submit")
                }
            }
            .padding(.leading, 15)
            .padding(.trailing, 10)
            .frame(minHeight: 50)
            // Camera luminance must not wash out the query or settings controls.
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.2), value: queryController.latestPresentation)
    }

    private var isSearching: Bool {
        if case .searching = queryController.state {
            return true
        }
        if case .searching = relationQueryController.state {
            return true
        }
        if case .evaluating = placementController.state {
            return true
        }
        if navigationController.state == .routing {
            return true
        }
        return false
    }

    private var relationStateMessage: String? {
        switch relationQueryController.state {
        case .unavailable(let message), .failed(let message):
            return message
        case .idle, .searching, .result:
            return nil
        }
    }

    private var interaction: SpatialInteractionCoordinator {
        SpatialInteractionCoordinator(
            cancelObjectQuery: { queryController.cancelCurrentQuery() },
            cancelRelationQuery: { relationQueryController.cancelCurrentQuery() },
            cancelPlacement: { placementController.cancelCurrentEvaluation() },
            clearRoute: { navigationController.clearRoute() },
            submitObjectQuery: { queryController.submit($0) },
            submitRelationQuery: { relationQueryController.submit($0) },
            evaluatePlacement: { placementController.evaluate($0) }
        )
    }

    private func submit() {
        queryIsFocused = false
        rejection = interaction.perform(SpatialCommandParser().parse(query))
    }

    @ViewBuilder
    private func placementButton(title: String, kind: FurnitureKind) -> some View {
        Button(title) {
            queryIsFocused = false
            rejection = interaction.perform(.placement(kind))
        }
        .accessibilityIdentifier("vispace.placement.\(kind.rawValue)")
    }

    private func dismissAll() {
        rejection = nil
        interaction.dismiss()
    }

    private func rejectionMessage(_ reason: SpatialCommandRejection) -> String {
        switch reason {
        case .empty: String(localized: "command.empty")
        case .tooLong: String(localized: "command.tooLong")
        case .ambiguousFurniture: String(localized: "command.ambiguousFurniture")
        case .negatedPlacement: String(localized: "command.negatedPlacement")
        case .unsupportedFurniture: String(localized: "command.unsupportedFurniture")
        }
    }

    private func resultCard(
        _ presentation: SpatialObjectQueryPresentation
    ) -> some View {
        messageCard(
            message: presentation.message,
            systemImage: presentation.canStartARGuidance
                ? "location.fill"
                : "info.circle.fill"
        )
    }

    private func messageCard(message: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismissAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.72))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("query.dismissResult"))
            .accessibilityIdentifier("vispace.query.dismiss")
        }
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vispace.query.result")
    }
}
