import SwiftUI
import VispaceCore

struct ObjectIdentityReviewScreen: View {
    @ObservedObject var controller: SpatialPerceptionController
    let distanceDescription: (Vec3) -> String
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("관측 중인 물체와 이전 기록이 같은 실물일 때만 연결하세요. 물체가 카메라에 계속 보이도록 해 주세요.")
                    if let message { Text(message).accessibilityIdentifier("vispace.identity.status") }
                }
                ForEach(controller.identityConfirmationCandidates) { candidate in
                    Section {
                        Text(
                            "현재 \(candidate.observedMetadata.object.displayLabel) · \(distanceDescription(candidate.observedMetadata.position.value))"
                        )
                        ForEach(candidate.existingCandidates, id: \.object.id) { existing in
                            Button {
                                perform {
                                    try await controller.confirmObservedObjectIdentity(
                                        candidateID: candidate.id,
                                        existingObjectID: existing.object.id,
                                        expectedTemporalRevision: existing.object.temporalRevision)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("‘\(existing.object.displayLabel)’ 기록에 연결")
                                    Text("저장 위치 \(distanceDescription(existing.position.value))")
                                    Text(
                                        "마지막 관측 \(Date(timeIntervalSince1970: existing.object.lastSeenAt).formatted(date: .abbreviated, time: .shortened))"
                                    )
                                }
                            }.disabled(isSaving)
                        }
                        Button("이전 물체와 다른 새 물체예요") {
                            perform {
                                try await controller.acceptObservedObjectAsNew(candidateID: candidate.id)
                            }
                        }.disabled(isSaving)
                    }
                }
                if controller.identityConfirmationCandidates.isEmpty && message == nil {
                    Text("지금 연결을 검토할 물체가 없어요. 이동한 물체를 카메라에 보여 주세요.")
                }
            }
            .navigationTitle("물체 기록 연결")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await action()
                message = "확인을 받았어요. 저장을 마칠 수 있도록 물체를 계속 비춰 주세요. 저장 문제가 있으면 카메라에 표시됩니다."
            } catch {
                message = "관측이나 기존 기록이 바뀌어 연결하지 않았어요. 현재 후보를 다시 확인해 주세요."
            }
        }
    }
}

struct ObjectClassificationEditor: View {
    @State var label: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private var normalized: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        !normalized.isEmpty && normalized.count <= 64
            && normalized.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("올바른 물체 종류", text: $label)
                    .accessibilityIdentifier("vispace.query.classification.field")
                Text("같은 실물의 종류를 잘못 인식했을 때만 정정하세요. 지정한 이름과 이전 위치 이력은 유지돼요. 카메라 인식 모델의 지원 종류가 추가되는 기능은 아닙니다.")
                if !isValid { Text("줄바꿈 없이 1~64자로 입력해 주세요.") }
            }
            .navigationTitle("물체 종류 정정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("정정 저장") {
                        onSave(normalized)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("vispace.query.classification.save")
                }
            }
        }
    }
}
