import Foundation
import SwiftUI
import VispaceCore

struct UserObjectRegistrationOverlay: View {
    @ObservedObject var controller: UserObjectRegistrationController
    let onClose: () -> Void
    let onSearch: (String) -> Void
    let distanceDescription: (SpatialObjectMetadata) -> String
    @State private var name: String
    @State private var selectedObject: SpatialObjectMetadata?
    @State private var showsExistingObjects = false
    @FocusState private var editsName: Bool

    init(controller: UserObjectRegistrationController, initialName: String,
         distanceDescription: @escaping (SpatialObjectMetadata) -> String = { _ in "" },
         onClose: @escaping () -> Void, onSearch: @escaping (String) -> Void) {
        self.controller = controller
        self.onClose = onClose
        self.onSearch = onSearch
        self.distanceDescription = distanceDescription
        _name = State(initialValue: initialName)
    }

    var body: some View {
        ZStack {
            // The center matches ARKit's full camera viewport, including safe areas.
            GeometryReader { geometry in
                Image(systemName: "scope")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black, radius: 3)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack {
                HStack {
                    Text("물체 위치 직접 기억").font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Text("닫기")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("vispace.registration.close")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Spacer()
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).font(.callout)
                        .accessibilityIdentifier("vispace.registration.status")
                    if case .saved(let metadata) = controller.state {
                        Button("기억한 위치 검색") {
                            onSearch(metadata.object.displayName ?? name)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("기존 물체 위치 바꾸기") { showsExistingObjects = true }
                            .accessibilityIdentifier("vispace.registration.choose-existing")
                        if let message = controller.spatialRefreshMessage {
                            Text(message).font(.callout)
                            Button("주변 물체 정보 다시 확인") {
                                controller.refreshSpatialRelationships()
                            }
                            .accessibilityIdentifier("vispace.registration.refresh")
                        }
                    } else {
                        if !isBusy && !controller.canRetrySave {
                            Button("기존 물체 위치 바꾸기") {
                                editsName = false
                                showsExistingObjects = true
                            }
                            .accessibilityIdentifier("vispace.registration.choose-existing")
                            if let selectedObject {
                                Text("선택한 기록: \(selectedObject.object.displayLabel)")
                                    .font(.subheadline.weight(.semibold))
                                Text("마지막 확인 \(Date(timeIntervalSince1970: selectedObject.object.lastSeenAt).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                Button("다른 새 물체로 등록") {
                                    controller.cancel()
                                    self.selectedObject = nil
                                }
                                .accessibilityIdentifier("vispace.registration.choose-new")
                            }
                        }
                        TextField("물체 이름 (예: 내 스피커)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .focused($editsName)
                            .submitLabel(.done)
                            .onSubmit { editsName = false }
                            .disabled(isBusy || controller.canRetrySave || selectedObject != nil)
                            .accessibilityIdentifier("vispace.registration.name")
                        if isBusy {
                            HStack {
                                ProgressView()
                                Text("같은 물체를 계속 비춰 주세요")
                            }
                        } else {
                            Button(controller.canRetrySave ? "저장 다시 시도"
                                : (selectedObject == nil ? "현재 위치 기억" : "선택한 물체 위치 바꾸기")) {
                                editsName = false
                                if controller.canRetrySave { controller.retrySave() }
                                else { controller.start(name: name, replacing: selectedObject) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("vispace.registration.capture")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                }
                .frame(maxHeight: 420)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("vispace.registration.form")
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
        .sheet(isPresented: $showsExistingObjects) {
            UserRegisteredObjectPicker(controller: controller, distanceDescription: distanceDescription) { selected in
                controller.cancel()
                selectedObject = selected
                name = selected.object.displayName ?? ""
                showsExistingObjects = false
            }
        }
    }

    private var isBusy: Bool {
        switch controller.state {
        case .collecting, .saving: true
        case .idle, .saved, .unavailable: false
        }
    }

    private var message: String {
        switch controller.state {
        case .idle:
            selectedObject == nil
                ? "가운데 표시를 물체 표면에 맞추고 이름을 입력해 주세요. 직접 등록한 물체는 마지막 확인 위치로 기억합니다. 깊이를 측정할 수 있는 기기가 필요합니다."
                : "선택한 물체 표면에 가운데 표시를 맞춰 주세요. 기존 기록의 이름을 유지하고 마지막 확인 위치를 바꿉니다."
        case .collecting:
            "물체 표면의 위치를 확인하고 있어요. 휴대폰을 잠시 고정해 주세요."
        case .saving:
            "확인한 위치를 저장하고 있어요."
        case .saved:
            "이름과 마지막 확인 위치를 기억했어요. 물체를 옮기면 ‘기존 물체 위치 바꾸기’에서 이 기록을 선택해 주세요."
        case .unavailable(let message):
            message
        }
    }
}

private struct UserRegisteredObjectPicker: View {
    @ObservedObject var controller: UserObjectRegistrationController
    let distanceDescription: (SpatialObjectMetadata) -> String
    let onSelect: (SpatialObjectMetadata) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var objects: [SpatialObjectMetadata] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.existingObjects.filter {
            query.isEmpty || $0.object.displayLabel.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("현재 공간에 직접 등록한 기록이에요. 위치를 바꿀 같은 물체를 선택하세요. 이름이 같아도 자동으로 합치지 않아요.")
                }
                if let message = controller.existingObjectsMessage {
                    Text(message)
                    Button("다시 불러오기") { Task { await controller.loadExistingObjects() } }
                } else if objects.isEmpty {
                    Text("선택할 직접 등록 기록이 없어요.")
                }
                ForEach(objects, id: \.object.id) { metadata in
                    Button {
                        onSelect(metadata)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(metadata.object.displayLabel).font(.headline)
                            Text("마지막 확인 \(Date(timeIntervalSince1970: metadata.object.lastSeenAt).formatted(date: .abbreviated, time: .standard))")
                            Text(distanceDescription(metadata))
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("vispace.registration.existing.\(metadata.object.id)")
                }
            }
            .searchable(text: $search, prompt: "등록한 물체 이름")
            .navigationTitle("위치를 바꿀 물체")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
            .task { await controller.loadExistingObjects() }
        }
    }
}
