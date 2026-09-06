import Foundation
import SwiftUI

struct UserObjectRegistrationOverlay: View {
    @ObservedObject var controller: UserObjectRegistrationController
    let onClose: () -> Void
    let onSearch: (String) -> Void
    @State private var name: String
    @FocusState private var editsName: Bool

    init(controller: UserObjectRegistrationController, initialName: String,
         onClose: @escaping () -> Void, onSearch: @escaping (String) -> Void) {
        self.controller = controller
        self.onClose = onClose
        self.onSearch = onSearch
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
                    Button("닫기", action: onClose)
                        .accessibilityIdentifier("vispace.registration.close")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).font(.callout)
                        .accessibilityIdentifier("vispace.registration.status")
                    if case .saved(let metadata) = controller.state {
                        Button("기억한 위치 검색") {
                            onSearch(metadata.object.displayName ?? name)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        TextField("물체 이름 (예: 내 스피커)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .focused($editsName)
                            .disabled(isBusy)
                            .accessibilityIdentifier("vispace.registration.name")
                        if isBusy {
                            HStack {
                                ProgressView()
                                Text("같은 물체를 계속 비춰 주세요")
                            }
                        } else {
                            Button("현재 위치 기억") {
                                editsName = false
                                controller.start(name: name)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("vispace.registration.capture")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
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
            "가운데 표시를 물체 표면에 맞추고 이름을 입력해 주세요. 직접 등록한 물체는 마지막 확인 위치로 기억합니다. 깊이를 측정할 수 있는 기기가 필요합니다."
        case .collecting:
            "물체 표면의 위치를 확인하고 있어요. 휴대폰을 잠시 고정해 주세요."
        case .saving:
            "확인한 위치를 저장하고 있어요."
        case .saved:
            "이름과 마지막 확인 위치를 기억했어요. 물체를 옮기면 새 위치를 다시 등록해 주세요."
        case .unavailable(let message):
            message
        }
    }
}
