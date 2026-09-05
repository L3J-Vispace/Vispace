import SwiftUI
import VispaceCore

struct SpatialDataSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: SpatialDataManagementController
    @State private var confirmsDeletion = false
    @State private var selectedPlace: MapID?
    @State private var confirmsPlaceDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("data.storage.section") {
                    Label("data.storage.local", systemImage: "iphone")
                    Label("data.storage.rawFrames", systemImage: "video.slash")
                    Label("data.storage.retention", systemImage: "clock.arrow.circlepath")
                }

                if let overview = controller.overview {
                    Section("data.storage.usage") {
                        LabeledContent("data.storage.used", value: ByteCountFormatter.string(fromByteCount: overview.usedBytes, countStyle: .file))
                        LabeledContent("data.storage.available", value: ByteCountFormatter.string(fromByteCount: overview.availableBytes, countStyle: .file))
                        Text("data.storage.budget")
                    }
                    Section("data.places.title") {
                        ForEach(overview.places) { place in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(String(place.id.description.prefix(8)))
                                    Text(Date(timeIntervalSince1970: place.updatedAt), format: .dateTime)
                                        .font(.caption)
                                    Text("\(place.objectCount) objects")
                                        .font(.caption)
                                    Button("data.place.select") { controller.selectPlace(place.id) }
                                        .disabled(controller.isBusy)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    selectedPlace = place.id
                                    confirmsPlaceDeletion = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(Text("data.place.delete"))
                                .disabled(controller.isBusy)
                            }
                        }
                    }
                } else if controller.overviewFailed {
                    Section { Text("data.storage.read.failed") }
                }

                Section("data.support.title") {
                    Text("data.support.objects")
                    Text("data.support.device")
                    Text("data.support.routes")
                }

                Section {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("data.delete.action", systemImage: "trash")
                    }
                    .disabled(controller.isBusy)
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
                    .disabled(controller.isBusy)
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
            .task { await controller.refreshOverview() }
            .confirmationDialog("data.place.delete", isPresented: $confirmsPlaceDeletion) {
                Button("data.place.delete", role: .destructive) {
                    if let selectedPlace { controller.deletePlace(selectedPlace) }
                }
                Button("data.delete.confirm.cancel", role: .cancel) {}
            } message: { Text("data.place.delete.detail") }
            .interactiveDismissDisabled(controller.isBusy)
        }
    }
}
