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
    public static let maximumWorldMapBytes = ARWorldMapArchiveCodec.maximumArchiveBytes
    public static let maximumEncryptedFileBytes = 146 * 1_024 * 1_024
    public static let maximumObjectCount = 65_536
    public static let maximumAutomaticObjectCount = 2_048
    public static let maximumManifestBytes = 16 * 1_024 * 1_024
    static let archiveChunkBytes = 1_024 * 1_024
    static let legacyMaximumEncryptedFileBytes = 36 * 1_024 * 1_024
    static let legacyMaximumWorldMapBytes = 32 * 1_024 * 1_024
    static let legacyMaximumManifestBytes = 3 * 1_024 * 1_024
    static let legacyMaximumObjectCount = 2_048
    private static let magic = Data("VISPACE-PLACE".utf8)
    private static let header = magic + Data([0, 2])
    private static let legacyHeader = magic + Data([0, 1])
    private static let sealedBoxOverhead = 28
    private static let manifestPrefixBytes = 8 + 32
    private static let objectLimitKey = CodingUserInfoKey(rawValue: "Vispace.portableObjectLimit")!
    private let archiveValidator: @Sendable (Data) throws -> Void
    private let checkCancellation: @Sendable () throws -> Void

    public init() {
        archiveValidator = { _ = try ARWorldMapArchiveCodec.unarchive($0) }
        checkCancellation = { try Task.checkCancellation() }
    }

    #if DEBUG
    init(archiveValidator: @escaping @Sendable (Data) throws -> Void,
         checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) {
        self.archiveValidator = archiveValidator
        self.checkCancellation = checkCancellation
    }
    #endif

    public func seal(_ candidate: WorldMapRestoreCandidate) throws -> SpatialPlaceEncryptedExport {
        try checkCancellation()
        try validate(candidate)
        let payload = Payload(schemaVersion: 1, metadata: candidate.metadata, objects: candidate.objects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(payload)
        guard manifest.count <= Self.maximumManifestBytes else {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        var manifestPlaintext = Self.integerBytes(UInt64(candidate.archive.count), count: 8)
        manifestPlaintext.append(Data(SHA256.hash(data: candidate.archive)))
        manifestPlaintext.append(manifest)
        try checkCancellation()
        let key = SymmetricKey(size: .bits256)
        let encryptedManifest = try Self.encrypt(manifestPlaintext, key: key, authenticating: Self.header)
        let chunkAuthentication = Self.header + Data(SHA256.hash(data: encryptedManifest))
        let chunkCount = (candidate.archive.count + Self.archiveChunkBytes - 1) / Self.archiveChunkBytes
        var encrypted = Data()
        encrypted.reserveCapacity(Self.header.count + 4 + encryptedManifest.count
            + candidate.archive.count + chunkCount * Self.sealedBoxOverhead)
        encrypted.append(Self.header)
        encrypted.append(Self.integerBytes(UInt64(encryptedManifest.count), count: 4))
        encrypted.append(encryptedManifest)
        for index in 0..<chunkCount {
            try checkCancellation()
            let start = index * Self.archiveChunkBytes
            let end = min(candidate.archive.count, start + Self.archiveChunkBytes)
            let chunk = candidate.archive.subdata(in: (candidate.archive.startIndex + start)..<(candidate.archive.startIndex + end))
            encrypted.append(try Self.encrypt(chunk, key: key,
                authenticating: chunkAuthentication + Self.integerBytes(UInt64(index), count: 8)))
        }
        try checkCancellation()
        let recoveryKey = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return SpatialPlaceEncryptedExport(id: UUID(), mapID: candidate.metadata.mapID,
            encryptedData: encrypted, recoveryKey: recoveryKey)
    }

    public func open(_ encryptedData: Data, recoveryKey: String) throws -> WorldMapRestoreCandidate {
        try checkCancellation()
        guard encryptedData.count <= Self.maximumEncryptedFileBytes else { throw SpatialPlaceArchiveError.fileTooLarge }
        guard encryptedData.count > Self.header.count + 28,
            encryptedData.prefix(Self.magic.count) == Self.magic else { throw SpatialPlaceArchiveError.invalidDocument }
        let versionIndex = encryptedData.index(encryptedData.startIndex, offsetBy: Self.magic.count)
        let version = Int(encryptedData[versionIndex]) * 256 + Int(encryptedData[versionIndex + 1])
        guard version == 1 || version == 2 else { throw SpatialPlaceArchiveError.unsupportedVersion(version) }
        if version == 1 && encryptedData.count > Self.legacyMaximumEncryptedFileBytes {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        let trimmedKey = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.utf8.count == 44, let keyData = Data(base64Encoded: trimmedKey), keyData.count == 32 else {
            throw SpatialPlaceArchiveError.invalidRecoveryKey
        }
        let key = SymmetricKey(data: keyData)
        return try version == 1 ? openLegacy(encryptedData, key: key) : openChunked(encryptedData, key: key)
    }

    private func openLegacy(_ encryptedData: Data, key: SymmetricKey) throws -> WorldMapRestoreCandidate {
        let plaintext = try Self.decrypt(Data(encryptedData.dropFirst(Self.legacyHeader.count)),
            key: key, authenticating: Self.legacyHeader)
        try checkCancellation()
        guard plaintext.count > 4 + 32 else { throw SpatialPlaceArchiveError.invalidDocument }
        let manifestLength = plaintext.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard manifestLength > 0, manifestLength <= Self.legacyMaximumManifestBytes,
            manifestLength < plaintext.count - 4 - 32 else { throw SpatialPlaceArchiveError.invalidDocument }
        let archiveLength = plaintext.count - 4 - manifestLength - 32
        guard archiveLength <= Self.legacyMaximumWorldMapBytes else { throw SpatialPlaceArchiveError.fileTooLarge }
        let manifest = Data(plaintext.dropFirst(4).prefix(manifestLength))
        let payload = try decodePayload(manifest, maximumObjects: Self.legacyMaximumObjectCount)
        let archive = Data(plaintext.dropFirst(4 + manifestLength).dropLast(32))
        guard plaintext.suffix(32) == Data(SHA256.hash(data: archive)) else {
            throw SpatialPlaceArchiveError.checksumMismatch
        }
        let candidate = WorldMapRestoreCandidate(metadata: payload.metadata, archive: archive, objects: payload.objects)
        try validate(candidate)
        return candidate
    }

    private func openChunked(_ encryptedData: Data, key: SymmetricKey) throws -> WorldMapRestoreCandidate {
        let lengthStart = encryptedData.startIndex + Self.header.count
        let encryptedManifestLength = Int(Self.readInteger(encryptedData[lengthStart..<(lengthStart + 4)]))
        guard encryptedManifestLength > Self.manifestPrefixBytes + Self.sealedBoxOverhead,
            encryptedManifestLength <= Self.maximumManifestBytes + Self.manifestPrefixBytes + Self.sealedBoxOverhead,
            encryptedManifestLength <= encryptedData.count - Self.header.count - 4
        else { throw SpatialPlaceArchiveError.invalidDocument }
        let manifestStart = lengthStart + 4
        let encryptedManifest = encryptedData.subdata(in: manifestStart..<(manifestStart + encryptedManifestLength))
        let plaintext = try Self.decrypt(encryptedManifest, key: key, authenticating: Self.header)
        guard plaintext.count > Self.manifestPrefixBytes else { throw SpatialPlaceArchiveError.invalidDocument }
        let archiveLengthValue = Self.readInteger(plaintext.prefix(8))
        guard archiveLengthValue > 0, archiveLengthValue <= UInt64(Self.maximumWorldMapBytes) else {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        let archiveLength = Int(archiveLengthValue)
        let chunkCount = (archiveLength + Self.archiveChunkBytes - 1) / Self.archiveChunkBytes
        let prefixLength = Self.header.count + 4 + encryptedManifestLength
        guard encryptedData.count == prefixLength + archiveLength + chunkCount * Self.sealedBoxOverhead else {
            throw SpatialPlaceArchiveError.invalidDocument
        }
        try checkCancellation()
        let payload = try decodePayload(Data(plaintext.dropFirst(Self.manifestPrefixBytes)), maximumObjects: Self.maximumObjectCount)
        let expectedDigest = Data(plaintext.dropFirst(8).prefix(32))
        let chunkAuthentication = Self.header + Data(SHA256.hash(data: encryptedManifest))
        var archive = Data()
        archive.reserveCapacity(archiveLength)
        var digest = SHA256()
        var offset = encryptedData.startIndex + prefixLength
        for index in 0..<chunkCount {
            try checkCancellation()
            let byteCount = min(Self.archiveChunkBytes, archiveLength - archive.count) + Self.sealedBoxOverhead
            let chunk = try Self.decrypt(encryptedData.subdata(in: offset..<(offset + byteCount)), key: key,
                authenticating: chunkAuthentication + Self.integerBytes(UInt64(index), count: 8))
            digest.update(data: chunk)
            archive.append(chunk)
            offset += byteCount
        }
        guard Data(digest.finalize()) == expectedDigest else { throw SpatialPlaceArchiveError.checksumMismatch }
        try checkCancellation()
        let candidate = WorldMapRestoreCandidate(metadata: payload.metadata, archive: archive, objects: payload.objects)
        try validate(candidate)
        return candidate
    }

    private func decodePayload(_ manifest: Data, maximumObjects: Int) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.userInfo[Self.objectLimitKey] = maximumObjects
        let probe: SchemaProbe
        do { probe = try decoder.decode(SchemaProbe.self, from: manifest) }
        catch { throw SpatialPlaceArchiveError.invalidDocument }
        guard probe.schemaVersion == 1 else { throw SpatialPlaceArchiveError.unsupportedVersion(probe.schemaVersion) }
        do {
            let payload = try decoder.decode(Payload.self, from: manifest)
            try Self.validateObjectCounts(payload.objects)
            return payload
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as SpatialPlaceArchiveError { throw error }
        catch { throw SpatialPlaceArchiveError.invalidDocument }
    }

    private static func encrypt(_ plaintext: Data, key: SymmetricKey, authenticating data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: data).combined else {
            throw SpatialPlaceArchiveError.invalidDocument
        }
        return combined
    }

    private static func decrypt(_ ciphertext: Data, key: SymmetricKey, authenticating data: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: data) }
        catch { throw SpatialPlaceArchiveError.authenticationFailed }
    }

    private static func integerBytes(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
    }

    private static func readInteger(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func validate(_ candidate: WorldMapRestoreCandidate) throws {
        guard !candidate.archive.isEmpty, candidate.archive.count <= Self.maximumWorldMapBytes else {
            throw SpatialPlaceArchiveError.fileTooLarge
        }
        try Self.validateObjectCounts(candidate.objects)
        guard candidate.metadata.availability == .active, candidate.metadata.quarantineReason == nil,
            candidate.objects.allSatisfy({
                $0.mapID == candidate.metadata.mapID && $0.position.coordinateFrameID == candidate.metadata.coordinateFrameID
                    && $0.object.semanticLabel.utf8.count <= 256
                    && ($0.object.displayName?.utf8.count ?? 0) <= 256
            }) else { throw SpatialPlaceArchiveError.invalidDocument }
        try SpatialMetadataDocument(maps: [candidate.metadata], objects: candidate.objects).validate()
        try checkCancellation()
        try archiveValidator(candidate.archive)
    }

    private static func validateObjectCounts(_ objects: [SpatialObjectMetadata]) throws {
        guard objects.count <= maximumObjectCount,
            objects.lazy.filter({ !UserObjectRegistrationAccumulator.isManualRegistration($0) })
                .prefix(maximumAutomaticObjectCount + 1).count <= maximumAutomaticObjectCount
        else { throw SpatialPlaceArchiveError.fileTooLarge }
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
            let maximumObjects = decoder.userInfo[SpatialPlaceArchiveCodec.objectLimitKey] as? Int
                ?? SpatialPlaceArchiveCodec.maximumObjectCount
            guard let count = list.count, count <= maximumObjects else {
                throw SpatialPlaceArchiveError.fileTooLarge
            }
            let metadata = try container.decode(SpatialMapMetadata.self, forKey: .metadata)
            var objects: [SpatialObjectMetadata] = []
            objects.reserveCapacity(count)
            while !list.isAtEnd {
                try Task.checkCancellation()
                guard objects.count < maximumObjects else { throw SpatialPlaceArchiveError.fileTooLarge }
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
                data.reserveCapacity(min(size, limit))
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
