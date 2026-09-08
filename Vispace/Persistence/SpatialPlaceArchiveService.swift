import CryptoKit
import Foundation
import VispaceCore

public enum SpatialPlaceArchiveError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidDocument
    case unsupportedVersion(Int)
    case invalidRecoveryKey
    case authenticationFailed
    case checksumMismatch
    case placeUnavailable
}

public struct SpatialPlaceEncryptedExport: Identifiable, Sendable {
    public let id: UUID
    public let mapID: MapID
    public let encryptedData: Data
    /// Ephemeral UI material. Never persisted in the document, logs, or settings.
    public let recoveryKey: String
}

/// One latest checkpoint plus current objects, never a directory or raw camera
/// frame. Length-delimited JSON metadata and raw archive bytes avoid both
/// base64 expansion and binary plist shared-reference expansion on import.
public struct SpatialPlaceArchiveCodec: Sendable {
    public static let maximumWorldMapBytes = 32 * 1_024 * 1_024
    public static let maximumEncryptedFileBytes = 36 * 1_024 * 1_024
    public static let maximumObjectCount = 2_048
    public static let maximumManifestBytes = 3 * 1_024 * 1_024
    private static let magic = Data("VISPACE-PLACE".utf8)
    private static let header = magic + Data([0, 1])
    private let archiveValidator: @Sendable (Data) throws -> Void

    public init() {
        archiveValidator = { _ = try ARWorldMapArchiveCodec.unarchive($0) }
    }

    #if DEBUG
    init(archiveValidator: @escaping @Sendable (Data) throws -> Void) {
        self.archiveValidator = archiveValidator
    }
    #endif

    public func seal(_ candidate: WorldMapRestoreCandidate) throws -> SpatialPlaceEncryptedExport {
        try Task.checkCancellation()
        try validate(candidate)
        let payload = Payload(schemaVersion: 1, metadata: candidate.metadata, objects: candidate.objects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(payload)
        guard manifest.count <= Self.maximumManifestBytes else {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        let length = UInt32(manifest.count)
        var plaintext = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        plaintext.append(manifest)
        plaintext.append(candidate.archive)
        plaintext.append(Data(SHA256.hash(data: candidate.archive)))
        try Task.checkCancellation()
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.header)
        guard let combined = sealed.combined else { throw SpatialPlaceArchiveError.invalidDocument }
        let recoveryKey = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return SpatialPlaceEncryptedExport(id: UUID(), mapID: candidate.metadata.mapID,
            encryptedData: Self.header + combined, recoveryKey: recoveryKey)
    }

    public func open(_ encryptedData: Data, recoveryKey: String) throws -> WorldMapRestoreCandidate {
        try Task.checkCancellation()
        guard encryptedData.count <= Self.maximumEncryptedFileBytes else { throw SpatialPlaceArchiveError.fileTooLarge }
        guard encryptedData.count > Self.header.count + 28,
            encryptedData.prefix(Self.magic.count) == Self.magic else { throw SpatialPlaceArchiveError.invalidDocument }
        let versionIndex = encryptedData.index(encryptedData.startIndex, offsetBy: Self.magic.count)
        let version = Int(encryptedData[versionIndex]) * 256 + Int(encryptedData[versionIndex + 1])
        guard version == 1 else { throw SpatialPlaceArchiveError.unsupportedVersion(version) }
        let trimmedKey = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.utf8.count == 44, let keyData = Data(base64Encoded: trimmedKey), keyData.count == 32 else {
            throw SpatialPlaceArchiveError.invalidRecoveryKey
        }
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: encryptedData.dropFirst(Self.header.count))
            plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData), authenticating: Self.header)
        } catch { throw SpatialPlaceArchiveError.authenticationFailed }
        try Task.checkCancellation()
        guard plaintext.count > 4 + 32 else { throw SpatialPlaceArchiveError.invalidDocument }
        let manifestLength = plaintext.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard manifestLength > 0, manifestLength <= Self.maximumManifestBytes,
            manifestLength < plaintext.count - 4 - 32 else { throw SpatialPlaceArchiveError.invalidDocument }
        let archiveLength = plaintext.count - 4 - manifestLength - 32
        guard archiveLength <= Self.maximumWorldMapBytes else { throw SpatialPlaceArchiveError.fileTooLarge }
        let manifest = Data(plaintext.dropFirst(4).prefix(manifestLength))
        let decoder = JSONDecoder()
        let probe: SchemaProbe
        do { probe = try decoder.decode(SchemaProbe.self, from: manifest) }
        catch { throw SpatialPlaceArchiveError.invalidDocument }
        guard probe.schemaVersion == 1 else { throw SpatialPlaceArchiveError.unsupportedVersion(probe.schemaVersion) }
        let payload: Payload
        do { payload = try decoder.decode(Payload.self, from: manifest) }
        catch let error as SpatialPlaceArchiveError { throw error }
        catch { throw SpatialPlaceArchiveError.invalidDocument }
        let archive = Data(plaintext.dropFirst(4 + manifestLength).dropLast(32))
        guard plaintext.suffix(32) == Data(SHA256.hash(data: archive)) else {
            throw SpatialPlaceArchiveError.checksumMismatch
        }
        let candidate = WorldMapRestoreCandidate(metadata: payload.metadata, archive: archive, objects: payload.objects)
        try validate(candidate)
        return candidate
    }

    private func validate(_ candidate: WorldMapRestoreCandidate) throws {
        guard !candidate.archive.isEmpty, candidate.archive.count <= Self.maximumWorldMapBytes,
            candidate.objects.count <= Self.maximumObjectCount else { throw SpatialPlaceArchiveError.fileTooLarge }
        guard candidate.metadata.availability == .active, candidate.metadata.quarantineReason == nil,
            candidate.objects.allSatisfy({
                $0.mapID == candidate.metadata.mapID && $0.position.coordinateFrameID == candidate.metadata.coordinateFrameID
                    && $0.object.semanticLabel.utf8.count <= 256
                    && ($0.object.displayName?.utf8.count ?? 0) <= 256
            }) else { throw SpatialPlaceArchiveError.invalidDocument }
        try SpatialMetadataDocument(maps: [candidate.metadata], objects: candidate.objects).validate()
        try archiveValidator(candidate.archive)
    }

    private struct SchemaProbe: Decodable { let schemaVersion: Int }
    private struct Payload: Codable {
        let schemaVersion: Int
        let metadata: SpatialMapMetadata
        let objects: [SpatialObjectMetadata]

        init(schemaVersion: Int, metadata: SpatialMapMetadata, objects: [SpatialObjectMetadata]) {
            self.schemaVersion = schemaVersion
            self.metadata = metadata
            self.objects = objects
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, metadata, objects }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else { throw SpatialPlaceArchiveError.unsupportedVersion(schemaVersion) }
            // Reject excessive element counts before constructing model values.
            var list = try container.nestedUnkeyedContainer(forKey: .objects)
            guard let count = list.count, count <= SpatialPlaceArchiveCodec.maximumObjectCount else {
                throw SpatialPlaceArchiveError.fileTooLarge
            }
            let metadata = try container.decode(SpatialMapMetadata.self, forKey: .metadata)
            var objects: [SpatialObjectMetadata] = []
            objects.reserveCapacity(count)
            while !list.isAtEnd {
                guard objects.count < SpatialPlaceArchiveCodec.maximumObjectCount else { throw SpatialPlaceArchiveError.fileTooLarge }
                objects.append(try list.decode(SpatialObjectMetadata.self))
            }
            self.init(schemaVersion: schemaVersion, metadata: metadata, objects: objects)
        }
    }
}

public actor SpatialPlaceArchiveService {
    private let repository: WorldMapCheckpointRepository
    private let codec: SpatialPlaceArchiveCodec

    public init(repository: WorldMapCheckpointRepository) {
        self.repository = repository
        self.codec = SpatialPlaceArchiveCodec()
    }

    #if DEBUG
    init(repository: WorldMapCheckpointRepository, codec: SpatialPlaceArchiveCodec) {
        self.repository = repository
        self.codec = codec
    }
    #endif

    public func exportPlace(mapID: MapID) async throws -> SpatialPlaceEncryptedExport {
        guard let candidate = try await repository.loadLatestValidCheckpoint(mapID: mapID) else {
            throw SpatialPlaceArchiveError.placeUnavailable
        }
        return try codec.seal(candidate)
    }

    @discardableResult
    public func importPlace(from selectedFile: URL, recoveryKey: String) async throws -> MapID {
        let encrypted = try Self.readSelectedFile(selectedFile)
        let candidate = try codec.open(encrypted, recoveryKey: recoveryKey)
        try Task.checkCancellation()
        return try await repository.importPortableCheckpoint(candidate)
    }

    /// The selected URL is read-only and never supplies a destination path.
    /// Security-scoped access lasts only for this bounded, coordinated read.
    private static func readSelectedFile(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result {
                try SpatialStorageDirectory.validateRegularFile(at: source)
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= SpatialPlaceArchiveCodec.maximumEncryptedFileBytes else { throw SpatialPlaceArchiveError.fileTooLarge }
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                var data = Data()
                let limit = SpatialPlaceArchiveCodec.maximumEncryptedFileBytes + 1
                while data.count < limit {
                    try Task.checkCancellation()
                    guard let chunk = try handle.read(upToCount: min(64 * 1_024, limit - data.count)), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                guard data.count < limit else { throw SpatialPlaceArchiveError.fileTooLarge }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SpatialPlaceArchiveError.invalidDocument }
        return try result.get()
    }
}
