import SwiftUI
import VispaceCore

struct SpatialQueryPanel: View {
    @ObservedObject var perceptionController: SpatialPerceptionController
    @ObservedObject var queryController: SpatialObjectQueryController
    @ObservedObject var relationQueryController: SpatialRelationQueryController
    @ObservedObject var placementController: FurniturePlacementController
    @ObservedObject var navigationController: IndoorNavigationController
    let onManageData: () -> Void
    let distanceDescription: (Vec3) -> String
    var onRegisterObject: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var queryIsFocused: Bool
    @State private var query = ""
    @State private var rejection: SpatialCommandRejection?
    @State private var editsFurniture = false
    @State private var selectedFurniture: FurnitureKind = .sofa
    @State private var editsObjectName = false
    @State private var objectNameDraft = ""
    @State private var requiresObjectName = false
    @State private var editsClassification = false
    @State private var classificationDraft = ""
    @State private var classificationTarget: SpatialObjectMetadata?
    @State private var reviewsIdentity = false

    var body: some View {
        VStack(spacing: 10) {
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }

            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    resultContent
                        .frame(maxWidth: .infinity)
                }
            } else {
                resultContent
            }

            queryControls
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: queryController.latestPresentation)
        .onChange(of: perceptionController.metrics.promotedObjects) { _, _ in
            queryController.refreshUnresolvedQueryAfterObservation()
        }
        .sheet(isPresented: $editsFurniture) {
            FurnitureDimensionEditor(kind: selectedFurniture) { dimensions in
                dismissAll()
                placementController.evaluate(selectedFurniture, dimensions: dimensions)
            }
        }
        .sheet(isPresented: $editsObjectName) {
            ObjectNameEditor(name: objectNameDraft, requiresName: requiresObjectName) { name in
                navigationController.clearRoute()
                queryController.renameSelectedObject(name)
            }
        }
        .sheet(isPresented: $editsClassification) {
            ObjectClassificationEditor(label: classificationDraft) { label in
                guard let classificationTarget else { return }
                navigationController.clearRoute()
                queryController.correctSelectedClassification(label, expected: classificationTarget)
            }
        }
        .sheet(isPresented: $reviewsIdentity) {
            ObjectIdentityReviewScreen(
                controller: perceptionController, distanceDescription: distanceDescription)
        }
    }

    private var queryControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 2) {
                    queryInput
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        queryActions
                    }
                }
            } else {
                HStack(spacing: 4) {
                    queryInput
                    queryActions
                }
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 10)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .frame(minHeight: 50)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 25))
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        }
    }

    private var queryInput: some View {
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
                .frame(minWidth: 44, minHeight: 44)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var queryActions: some View {
        Button {
            queryIsFocused = false
            dismissAll()
            onManageData()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("data.title"))
        .accessibilityIdentifier("vispace.data.settings")

        if !perceptionController.identityConfirmationCandidates.isEmpty {
            Button {
                queryIsFocused = false; reviewsIdentity = true
            } label: {
                Image(systemName: "link.badge.plus")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("query.identityReview"))
            .accessibilityIdentifier("vispace.identity.review")
        }

        Menu {
            Button("query.registerObject") {
                queryIsFocused = false
                dismissAll()
                onRegisterObject("")
            }
            Divider()
            placementButton(title: "placement.kind.sofa", kind: .sofa)
            placementButton(title: "placement.kind.bed", kind: .bed)
            placementButton(title: "placement.kind.desk", kind: .desk)
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("query.objectTools"))
        .accessibilityIdentifier("vispace.placement.menu")

        if isSearching {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("query.searching"))
                .frame(minWidth: 44, minHeight: 44)
        } else if !query.isEmpty {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("query.submit"))
            .accessibilityIdentifier("vispace.query.submit")
        }
    }

    @ViewBuilder
    private var resultContent: some View {
    if let rejection {
        messageCard(message: rejectionMessage(rejection), systemImage: "info.circle.fill")
    } else if let presentation = navigationController.latestPresentation {
        VStack(spacing: 8) {
            messageCard(
                message: presentation.message,
                systemImage: presentation.canRenderPath
                    ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                    : "exclamationmark.triangle.fill"
            )
            if [.noPath, .invalidated].contains(navigationController.state),
                queryController.canRefreshSelectedNavigation,
                let target = queryController.latestGroundedTarget {
                Button {
                    queryIsFocused = false
                    if queryController.refreshSelectedNavigation(target) {
                        navigationController.clearRoute()
                    }
                } label: {
                    Label("query.retryRoute", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(uiColor: .systemCyan))
                .foregroundStyle(.black)
                .accessibilityHint(Text("query.routeRetryHint"))
                .accessibilityIdentifier("vispace.navigation.retry")
            }
        }
        .frame(maxWidth: 520)
        .transition(resultTransition)
    } else if let presentation = placementController.latestPresentation {
        messageCard(
            message: presentation.message,
            systemImage: presentation.disposition == .feasible
                ? "checkmark.seal.fill"
                : "info.circle.fill"
        )
        .transition(resultTransition)
    } else if let presentation = relationQueryController.latestPresentation {
        VStack(alignment: .leading, spacing: 8) {
            messageCard(
                message: presentation.message,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            if let target = presentation.result.ambiguousTargets.first {
                ForEach(Array(target.candidates.enumerated()), id: \.element.objectID) {
                    index, candidate in
                    Button {
                        relationQueryController.selectTarget(
                            mention: target.mention, objectID: candidate.objectID)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(candidate.name) · 후보 \(index + 1)")
                            if let position = candidate.position {
                                Text(distanceDescription(position)).font(.caption)
                            }
                            if let time = candidate.lastSeenAt {
                                Text(
                                    "마지막 관측 \(Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened))"
                                )
                                .font(.caption)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vispace.relation.candidate.\(index)")
                }
            }
        }
        .transition(resultTransition)
    } else if let relationMessage = relationStateMessage {
        messageCard(
            message: relationMessage,
            systemImage: "exclamationmark.triangle.fill"
        )
        .transition(resultTransition)
    } else if let presentation = queryController.latestPresentation {
        resultCard(presentation)
            .transition(resultTransition)
    } else if case .failed(let message) = queryController.state {
        messageCard(message: message, systemImage: "exclamationmark.triangle.fill")
            .transition(resultTransition)
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
            submitRelationQuery: { queryController.submit($0, onRelationQuery: { relationQueryController.submit($0) }) },
            evaluatePlacement: { placementController.evaluate($0) }
        )
    }

    private func submit() {
        queryIsFocused = false
        perceptionController.requestFreshRecognition()
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
    private func placementButton(title: LocalizedStringKey, kind: FurnitureKind) -> some View {
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

    private var resultTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
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
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let snapshot = perceptionController.liveSearchSnapshot
                let live = [.notFound, .lowConfidence].contains(presentation.result.status)
                    ? snapshot?.matches(labels: presentation.result.matchedSemanticLabels,
                                        now: ProcessInfo.processInfo.systemUptime).first : nil
                messageCard(
                    message: live.flatMap { snapshot?.message(for: $0) }
                        ?? (presentation.message + (dateText.map { "\n마지막 관측: \($0)" } ?? "")),
                    systemImage: presentation.canStartARGuidance ? "location.fill" : "info.circle.fill"
                )
            }
            if presentation.result.status == .notFound || presentation.result.status == .lowConfidence {
                Button("이 물체 위치 직접 기억") {
                    let label = presentation.result.matchedSemanticLabels.first.map {
                        ObjectSemanticCatalog.default.displayName(for: $0)
                    } ?? ""
                    queryIsFocused = false
                    dismissAll()
                    onRegisterObject(label)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("vispace.object.register")
            }
            if queryController.canNavigateToSelectedObject,
                let target = queryController.latestGroundedTarget {
                Button {
                    queryIsFocused = false
                    if queryController.navigateToSelectedObject(target) {
                        navigationController.clearRoute()
                    }
                } label: {
                    Label("query.navigate", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(uiColor: .systemCyan))
                .foregroundStyle(.black)
                .accessibilityHint(Text("query.routeStartHint"))
                .accessibilityIdentifier("vispace.query.navigate")
            }
            if presentation.result.totalCandidateCount > 1 {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(queryController.visibleCandidates.enumerated()), id: \.element.record.metadata.object.id) { index, candidate in
                            Button {
                                navigationController.clearRoute()
                                queryController.selectCandidate(objectID: candidate.record.metadata.object.id,
                                    mapID: candidate.record.metadata.mapID)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(candidate.record.metadata.object.displayName ?? ObjectSemanticCatalog.default.displayName(for: candidate.record.metadata.object.semanticLabel)) · 후보 \(queryController.candidatePageOffset + index + 1)")
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
                            .accessibilityIdentifier("vispace.query.candidate.\(queryController.candidatePageOffset + index)")
                        }
                    }
                }
                .frame(maxHeight: 190)
                if presentation.result.totalCandidateCount > presentation.result.candidates.count {
                    HStack {
                        Button { queryController.showCandidatePage(next: false) } label: {
                            Text("이전 후보").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(!queryController.canShowPreviousCandidatePage)
                        .accessibilityIdentifier("vispace.query.candidates.previous")
                        Spacer()
                        Text("\(queryController.candidatePageOffset + 1)–\(queryController.candidatePageOffset + queryController.visibleCandidates.count) / \(presentation.result.totalCandidateCount)")
                        Spacer()
                        Button { queryController.showCandidatePage(next: true) } label: {
                            Text("다음 후보").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(!queryController.canShowNextCandidatePage)
                        .accessibilityIdentifier("vispace.query.candidates.next")
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let selected = presentation.result.selectedCandidate {
                HStack {
                    if queryController.canRenameObjects && selected.record.metadata.object.presence != .removed {
                        Button(selected.record.metadata.object.displayName == nil ? "이름 지정" : "이름 변경") {
                            objectNameDraft = selected.record.metadata.object.displayName ?? ""
                            requiresObjectName = selected.record.metadata.object.semanticLabel
                                == UserObjectRegistrationAccumulator.semanticLabel
                            editsObjectName = true
                        }
                        .accessibilityIdentifier("vispace.query.rename")
                    }
                    if queryController.canCorrectClassification && selected.matchesCurrentMap == true
                        && selected.record.metadata.object.presence != .removed
                        && selected.record.metadata.object.semanticLabel != "user_registered_object"
                    {
                        Button("종류 정정") {
                            classificationDraft = selected.record.metadata.object.semanticLabel
                            classificationTarget = selected.record.metadata
                            editsClassification = true
                        }
                        .accessibilityIdentifier("vispace.query.classification")
                    }
                    Spacer()
                    Button("다른 후보 다시 보기") {
                        let object = selected.record.metadata.object
                        query = object.semanticLabel == "user_registered_object"
                            ? (object.displayName ?? "직접 등록한 물체")
                            : ObjectSemanticCatalog.default.displayName(for: object.semanticLabel)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        messageIcon(systemImage)
                        Spacer()
                        dismissResultButton
                    }
                    messageText(message)
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    messageIcon(systemImage)
                    messageText(message)
                    dismissResultButton
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vispace.query.result")
    }

    private func messageIcon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.yellow)
            .accessibilityHidden(true)
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dismissResultButton: some View {
        Button { dismissAll() } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white.opacity(0.72))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("query.dismissResult"))
        .accessibilityIdentifier("vispace.query.dismiss")
    }
}

private struct ObjectNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    var requiresName = false
    let onSave: (String) -> Void

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty && !requiresName) || (!trimmed.isEmpty && trimmed.count <= SpatialObject.maximumDisplayNameLength
            && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && trimmed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("예: 창가 의자", text: $name)
                    .accessibilityIdentifier("vispace.query.name.field")
                Text(requiresName
                     ? "직접 등록한 물체는 이 이름으로 검색해요. 이름을 비워 둘 수는 없어요."
                     : "이름은 선택한 물체에만 저장돼요. 빈칸으로 저장하면 지정한 이름을 지워요. 자동 인식 종류는 유지됩니다.")
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
