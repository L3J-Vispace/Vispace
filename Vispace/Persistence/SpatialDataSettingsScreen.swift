import SwiftUI
import UniformTypeIdentifiers
import VispaceCore

struct SpatialDataSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: SpatialDataManagementController
    @State private var confirmsDeletion = false
    @State private var selectedPlace: MapID?
    @State private var confirmsPlaceDeletion = false
    @State private var selectsImportFile = false
    @State private var selectedImportFile: SelectedSpatialPlaceArchive?
    @State private var fileSelectionFailed = false

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
                                    if controller.supportsPlaceTransfer {
                                        Button("data.transfer.export") { controller.preparePlaceExport(place.id) }
                                            .disabled(controller.isBusy)
                                    }
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
                            .buttonStyle(.borderless)
                        }
                    }
                } else if controller.overviewFailed {
                    Section { Text("data.storage.read.failed") }
                }

                if controller.supportsPlaceTransfer {
                    Section("data.transfer.title") {
                        Button("data.transfer.import") { selectsImportFile = true }
                            .disabled(controller.isBusy)
                        if controller.state == .exporting || controller.state == .importing {
                            ProgressView("data.transfer.progress")
                        }
                        if controller.state == .imported {
                            Label("data.transfer.import.success", systemImage: "checkmark.circle")
                        }
                        if fileSelectionFailed { Text("data.transfer.file.failed").foregroundStyle(.red) }
                    } footer: { Text("data.transfer.scope") }
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
            .fileImporter(isPresented: $selectsImportFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files):
                    if let file = files.first {
                        fileSelectionFailed = false
                        selectedImportFile = SelectedSpatialPlaceArchive(url: file)
                    }
                case .failure: fileSelectionFailed = true
                }
            }
            .sheet(item: $selectedImportFile) { file in
                SpatialPlaceImportSheet(controller: controller, selectedFile: file.url)
            }
            .sheet(isPresented: Binding(
                get: { controller.preparedExport != nil },
                set: { if !$0 { controller.discardPreparedExport() } }
            )) {
                if let export = controller.preparedExport {
                    SpatialPlaceExportSheet(export: export) { controller.discardPreparedExport() }
                }
            }
        }
    }
}

private struct SelectedSpatialPlaceArchive: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SpatialPlaceEncryptedFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let encryptedData: Data

    init(encryptedData: Data) { self.encryptedData = encryptedData }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
            data.count <= SpatialPlaceArchiveCodec.maximumEncryptedFileBytes else {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        encryptedData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encryptedData)
    }
}

private struct SpatialPlaceExportSheet: View {
    let export: SpatialPlaceEncryptedExport
    let finish: () -> Void
    @State private var savedRecoveryKey = false
    @State private var exportsFile = false
    @State private var exportFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("data.transfer.key.title") {
                    Text("data.transfer.key.detail")
                    Text(export.recoveryKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive()
                    Toggle("data.transfer.key.saved", isOn: $savedRecoveryKey)
                }
                Section {
                    Button("data.transfer.save") { exportsFile = true }
                        .disabled(!savedRecoveryKey)
                    if exportFailed { Text("data.transfer.file.failed").foregroundStyle(.red) }
                } footer: { Text("data.transfer.scope") }
            }
            .navigationTitle("data.transfer.export")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("data.delete.confirm.cancel", action: finish)
            } }
            .fileExporter(isPresented: $exportsFile,
                document: SpatialPlaceEncryptedFileDocument(encryptedData: export.encryptedData),
                contentType: .data,
                defaultFilename: "Vispace-\(export.mapID.description.prefix(8)).vispaceplace"
            ) { result in
                switch result {
                case .success: finish()
                case .failure: exportFailed = true
                }
            }
        }
    }
}

private struct SpatialPlaceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: SpatialDataManagementController
    let selectedFile: URL
    @State private var recoveryKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(selectedFile.lastPathComponent)
                    SecureField("data.transfer.key.input", text: $recoveryKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("data.transfer.import") {
                        controller.importPlace(from: selectedFile, recoveryKey: recoveryKey)
                    }.disabled(controller.isBusy || recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if controller.state == .importing { ProgressView("data.transfer.progress") }
                    if case .failed(let message) = controller.state { Text(message).foregroundStyle(.red) }
                } footer: { Text("data.transfer.scope") }
            }
            .navigationTitle("data.transfer.import")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("data.delete.confirm.cancel") { dismiss() }.disabled(controller.isBusy)
            } }
            .interactiveDismissDisabled(controller.isBusy)
            .onAppear { controller.clearStatus() }
            .onDisappear { recoveryKey = "" }
            .onChange(of: controller.state) { _, state in
                if state == .imported { recoveryKey = ""; dismiss() }
            }
        }
    }
}
