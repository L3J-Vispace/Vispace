import SwiftUI

struct FirstRunOnboardingScreen: View {
    let onStart: () -> Void

    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("onboarding.productName")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        Text("onboarding.title")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($isTitleFocused)
                            .accessibilityIdentifier("vispace.onboarding.title")

                        Text("onboarding.summary")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("vispace.onboarding.summary")
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        Text("onboarding.features.title")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)

                        GuidanceRow(
                            symbol: "magnifyingglass",
                            identifier: "vispace.onboarding.memory.title",
                            title: "onboarding.memory.title",
                            detail: "onboarding.memory.detail"
                        )

                        GuidanceRow(
                            symbol: "sparkle.magnifyingglass",
                            identifier: "vispace.onboarding.ask.title",
                            title: "onboarding.ask.title",
                            detail: "onboarding.ask.detail"
                        )

                        GuidanceRow(
                            symbol: "point.topleft.down.to.point.bottomright.curvepath",
                            identifier: "vispace.onboarding.guide.title",
                            title: "onboarding.guide.title",
                            detail: "onboarding.guide.detail"
                        )
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        Text("onboarding.gettingStarted.title")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)

                        GuidanceRow(
                            symbol: "iphone",
                            identifier: "vispace.onboarding.scan.title",
                            title: "onboarding.scan.title",
                            detail: "onboarding.scan.detail"
                        )
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        Text("onboarding.data.title")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)

                        GuidanceRow(
                            symbol: "lock.shield",
                            identifier: "vispace.onboarding.privacy.title",
                            title: "onboarding.privacy.title",
                            detail: "onboarding.privacy.detail"
                        )

                        GuidanceRow(
                            symbol: "internaldrive",
                            identifier: "vispace.onboarding.storage.title",
                            title: "onboarding.storage.title",
                            detail: "onboarding.storage.detail"
                        )
                    }

                    Label(
                        "onboarding.permissionNotice",
                        systemImage: "camera.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vispace.onboarding.permissionNotice")
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button("onboarding.start", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color(uiColor: .systemBackground))
                    .accessibilityIdentifier("vispace.onboarding.start")
            }
        }
        .onAppear {
            isTitleFocused = true
        }
    }
}

private struct GuidanceRow: View {
    let symbol: String
    let identifier: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier(identifier)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
