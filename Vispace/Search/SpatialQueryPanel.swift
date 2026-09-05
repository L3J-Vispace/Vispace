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
    @State private var editsFurniture = false
    @State private var selectedFurniture: FurnitureKind = .sofa
    @State private var editsObjectName = false
    @State private var objectNameDraft = ""

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
        .sheet(isPresented: $editsFurniture) {
            FurnitureDimensionEditor(kind: selectedFurniture) { dimensions in
                dismissAll()
                placementController.evaluate(selectedFurniture, dimensions: dimensions)
            }
        }
        .sheet(isPresented: $editsObjectName) {
            ObjectNameEditor(name: objectNameDraft) { name in
                navigationController.clearRoute()
                queryController.renameSelectedObject(name)
            }
        }
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
        let command = SpatialCommandParser().parse(query)
        if case .placement(let kind) = command {
            dismissAll()
            selectedFurniture = kind
            editsFurniture = true
        } else {
            rejection = interaction.perform(command)
        }
    }

    @ViewBuilder
    private func placementButton(title: String, kind: FurnitureKind) -> some View {
        Button(title) {
            queryIsFocused = false
            selectedFurniture = kind
            editsFurniture = true
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
        let observedAt = presentation.result.selectedCandidate?.record.metadata.object.lastSeenAt
        let dateText = observedAt.map {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
        }
        return VStack(alignment: .leading, spacing: 8) {
            messageCard(
                message: presentation.message + (dateText.map { "\n마지막 관측: \($0)" } ?? ""),
                systemImage: presentation.canStartARGuidance ? "location.fill" : "info.circle.fill"
            )
            if presentation.result.candidates.count > 1 {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(presentation.result.candidates.enumerated()), id: \.element.record.metadata.object.id) { index, candidate in
                            Button {
                                navigationController.clearRoute()
                                queryController.selectCandidate(objectID: candidate.record.metadata.object.id,
                                    mapID: candidate.record.metadata.mapID)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(candidate.record.metadata.object.displayLabel) · 후보 \(index + 1)")
                                        .font(.subheadline.weight(.semibold))
                                    Text(candidateDescription(candidate))
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("vispace.query.candidate.\(index)")
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
            if let selected = presentation.result.selectedCandidate {
                HStack {
                    if queryController.canRenameObjects && selected.record.metadata.object.presence != .removed {
                        Button(selected.record.metadata.object.displayName == nil ? "이름 지정" : "이름 변경") {
                            objectNameDraft = selected.record.metadata.object.displayName ?? ""
                            editsObjectName = true
                        }
                        .accessibilityIdentifier("vispace.query.rename")
                    }
                    Spacer()
                    Button("다른 후보 다시 보기") {
                        query = selected.record.metadata.object.semanticLabel
                        navigationController.clearRoute()
                        queryController.submit(query)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .foregroundStyle(.white)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: 520)
    }

    private func candidateDescription(_ candidate: GroundedSpatialObjectCandidate) -> String {
        let map = candidate.matchesCurrentMap == true ? "현재 공간" : "다른 저장 공간"
        let date = Date(timeIntervalSince1970: candidate.record.metadata.object.lastSeenAt)
            .formatted(date: .abbreviated, time: .shortened)
        let state = candidate.hasFutureObservationTime ? "마지막 관측 \(date) · 기록 시각 확인 필요"
            : (candidate.confidenceGrade == .low ? "마지막 관측 \(date) · 위치 신뢰 낮음" : "마지막 관측 \(date)")
        return "\(map) · \(state)"
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

private struct ObjectNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let onSave: (String) -> Void

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (trimmed.count <= SpatialObject.maximumDisplayNameLength
            && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && trimmed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("예: 창가 의자", text: $name)
                    .accessibilityIdentifier("vispace.query.name.field")
                Text("이름은 선택한 물체에만 저장돼요. 빈칸으로 저장하면 지정한 이름을 지워요. 자동 인식 종류는 유지됩니다.")
                    .font(.footnote)
                if !isValid { Text("줄바꿈 없이 64자 이내의 이름을 입력해 주세요.").foregroundStyle(.red) }
            }
            .navigationTitle("물체 이름")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { dismiss(); onSave(name) }
                        .disabled(!isValid)
                        .accessibilityIdentifier("vispace.query.name.save")
                }
            }
        }
    }
}

private struct FurnitureDimensionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let kind: FurnitureKind
    let onEvaluate: (FurnitureDimensions) -> Void
    @State private var width = ""
    @State private var depth = ""
    @State private var height = ""

    private var dimensions: FurnitureDimensions? {
        guard let width = FurnitureDimensionInput.parse(width, locale: locale),
            let depth = FurnitureDimensionInput.parse(depth, locale: locale),
            let height = FurnitureDimensionInput.parse(height, locale: locale)
        else { return nil }
        return try? FurnitureDimensions(kind: kind, width: width, depth: depth, height: height)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("placement.dimensions.metres") {
                    dimension("placement.width", value: $width)
                    dimension("placement.depth", value: $depth)
                    dimension("placement.height", value: $height)
                }
                Section {
                    Text("placement.dimensions.detail")
                }
            }
            .navigationTitle("placement.dimensions.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("data.delete.confirm.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("placement.evaluate") {
                        guard let dimensions else { return }
                        dismiss()
                        onEvaluate(dimensions)
                    }
                    .disabled(dimensions == nil)
                    .accessibilityIdentifier("vispace.placement.evaluate")
                }
            }
            .onAppear {
                let defaults = ARFurnitureDefaults.dimensions(for: kind)
                width = defaults.width.formatted(.number.locale(locale))
                depth = defaults.depth.formatted(.number.locale(locale))
                height = defaults.height.formatted(.number.locale(locale))
            }
        }
    }

    private func dimension(_ title: LocalizedStringKey, value: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
        }
    }
}

/// Validates the complete visible input before localized numeric conversion.
/// NumberFormatter alone can accept a numeric prefix of malformed pasted text.
enum FurnitureDimensionInput {
    static func parse(_ raw: String, locale: Locale = .current) -> Double? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.usesGroupingSeparator = false
        let parts = input.components(separatedBy: formatter.decimalSeparator ?? ".")
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ part in
                !part.isEmpty && part.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
            }),
            let value = formatter.number(from: input)?.doubleValue,
            value.isFinite, (0.1...10).contains(value)
        else { return nil }
        return value
    }
}
