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
            presentedSettings
        }
    }

    private var presentedSettings: some View {
        settingsWithDeletionDialogs
            .fileImporter(
                isPresented: $selectsImportFile,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleImportFileSelection(result)
            }
            .sheet(item: $selectedImportFile) { file in
                SpatialPlaceImportSheet(controller: controller, selectedFile: file.url)
            }
            .sheet(isPresented: presentsPreparedExport) {
                if let export = controller.preparedExport {
                    SpatialPlaceExportSheet(export: export) { controller.discardPreparedExport() }
                }
            }
    }

    private var settingsWithDeletionDialogs: some View {
        settingsList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusFeedback
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

    private var settingsList: some View {
        List {
            storagePolicySection
            storageOverviewSections
            transferSection
            supportSection
            deletionSection
        }
    }

    private var storagePolicySection: some View {
        Section("data.storage.section") {
            Label("data.storage.local", systemImage: "iphone")
            Label("data.storage.rawFrames", systemImage: "video.slash")
            Label("data.storage.retention", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private var storageOverviewSections: some View {
        if let overview = controller.overview {
            storageUsageSection(overview)
            storedPlacesSection(overview.places)
        } else if controller.overviewFailed {
            Section { Text("data.storage.read.failed") }
        }
    }

    private func storageUsageSection(_ overview: SpatialStorageOverview) -> some View {
        Section("data.storage.usage") {
            LabeledContent("data.storage.used", value: ByteCountFormatter.string(fromByteCount: overview.usedBytes, countStyle: .file))
            LabeledContent("data.storage.available", value: ByteCountFormatter.string(fromByteCount: overview.availableBytes, countStyle: .file))
            Text("data.storage.budget")
        }
    }

    private func storedPlacesSection(_ places: [SpatialStoredPlace]) -> some View {
        Section("data.places.title") {
            ForEach(places) { place in
                SpatialStoredPlaceRow(
                    place: place,
                    isBusy: controller.isBusy,
                    supportsTransfer: controller.supportsPlaceTransfer,
                    select: { controller.selectPlace(place.id) },
                    export: { controller.preparePlaceExport(place.id) },
                    delete: {
                        selectedPlace = place.id
                        confirmsPlaceDeletion = true
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var transferSection: some View {
        if controller.supportsPlaceTransfer {
            Section {
                Button("data.transfer.import") { selectsImportFile = true }
                    .disabled(controller.isBusy)
                if controller.state == .exporting || controller.state == .importing {
                    ProgressView("data.transfer.progress")
                }
                if controller.state == .imported {
                    Label("data.transfer.import.success", systemImage: "checkmark.circle")
                }
                if fileSelectionFailed {
                    Text("data.transfer.file.failed").foregroundStyle(.red)
                }
            } header: {
                Text("data.transfer.title")
            } footer: {
                Text("data.transfer.scope")
            }
        }
    }

    private var supportSection: some View {
        Section("data.support.title") {
            Text("data.support.objects")
            Text("data.support.device")
            Text("data.support.routes")
        }
    }

    private var deletionSection: some View {
        Section {
            Button(role: .destructive) {
                confirmsDeletion = true
            } label: {
                Label("data.delete.action", systemImage: "trash")
            }
            .disabled(controller.isBusy)
            .accessibilityIdentifier("vispace.data.delete")
        } footer: {
            Text("data.delete.detail")
        }
    }

    private var showsStatusFeedback: Bool {
        switch controller.state {
        case .deleting, .deleted, .failed: true
        default: false
        }
    }

    /// Maintenance changes the list's row count and scroll offset. Keep its
    /// outcome outside lazy rows so users can see it without another scroll.
    @ViewBuilder
    private var statusFeedback: some View {
        if showsStatusFeedback {
            statusContent
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch controller.state {
        case .deleting:
            HStack {
                ProgressView()
                Text("data.delete.progress")
            }
            .accessibilityElement(children: .combine)
        case .deleted:
            Label("data.delete.success", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("vispace.data.delete.success")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("vispace.data.delete.failure")
        default:
            EmptyView()
        }
    }

    private var presentsPreparedExport: Binding<Bool> {
        Binding(
            get: { controller.preparedExport != nil },
            set: { if !$0 { controller.discardPreparedExport() } }
        )
    }

    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let files):
            if let file = files.first {
                fileSelectionFailed = false
                selectedImportFile = SelectedSpatialPlaceArchive(url: file)
            }
        case .failure:
            fileSelectionFailed = true
        }
    }
}

private struct SpatialStoredPlaceRow: View {
    let place: SpatialStoredPlace
    let isBusy: Bool
    let supportsTransfer: Bool
    let select: () -> Void
    let export: () -> Void
    let delete: () -> Void

    private var shortIdentifier: String {
        String(place.id.description.prefix(8))
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: shortIdentifier)
                Text(Date(timeIntervalSince1970: place.updatedAt), format: .dateTime)
                    .font(.caption)
                Text("\(place.objectCount) objects")
                    .font(.caption)
                Button("data.place.select", action: select)
                    .disabled(isBusy)
                if supportsTransfer {
                    Button("data.transfer.export", action: export)
                        .disabled(isBusy)
                }
            }
            Spacer()
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .accessibilityLabel(Text("data.place.delete"))
            .disabled(isBusy)
        }
        .buttonStyle(.borderless)
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
