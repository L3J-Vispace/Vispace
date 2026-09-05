import SwiftUI

struct SpatialDataSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: SpatialDataManagementController
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("data.storage.section") {
                    Label("data.storage.local", systemImage: "iphone")
                    Label("data.storage.rawFrames", systemImage: "video.slash")
                    Label("data.storage.retention", systemImage: "clock.arrow.circlepath")
                }

                Section {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("data.delete.action", systemImage: "trash")
                    }
                    .disabled(controller.state == .deleting)
                    .accessibilityIdentifier("vispace.data.delete")

                    if controller.state == .deleting {
                        HStack {
                            ProgressView()
                            Text("data.delete.progress")
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("data.delete.detail")
                }

                if controller.state == .deleted {
                    Section {
                        Label("data.delete.success", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("vispace.data.delete.success")
                    }
                } else if case .failed(let message) = controller.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("vispace.data.delete.failure")
                    }
                }
            }
            .navigationTitle("data.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("data.done") {
                        dismiss()
                    }
                    .disabled(controller.state == .deleting)
                }
            }
            .confirmationDialog(
                "data.delete.confirm.title",
                isPresented: $confirmsDeletion,
                titleVisibility: .visible
            ) {
                Button("data.delete.confirm.action", role: .destructive) {
                    controller.deleteAllSpatialData()
                }
                .accessibilityIdentifier("vispace.data.delete.confirm")
                Button("data.delete.confirm.cancel", role: .cancel) {}
            } message: {
                Text("data.delete.confirm.message")
            }
            .onDisappear {
                controller.clearStatus()
            }
            .interactiveDismissDisabled(controller.state == .deleting)
        }
    }
}
