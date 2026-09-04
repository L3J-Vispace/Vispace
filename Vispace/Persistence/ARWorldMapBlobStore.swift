import CryptoKit
import Foundation

public struct WorldMapBlobID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct WorldMapBlobRecord: Equatable, Sendable {
    public let id: WorldMapBlobID
    public let createdAt: Date
    public let byteCount: Int
    public let sha256: String
    public let fileURL: URL

    public init(
        id: WorldMapBlobID,
        createdAt: Date,
        byteCount: Int,
        sha256: String,
        fileURL: URL
    ) {
        self.id = id
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.sha256 = sha256
        self.fileURL = fileURL
    }
}

public enum WorldMapBlobStoreError: Error, Equatable, Sendable {
    case emptyArchive
    case archiveTooLarge(actual: Int, maximum: Int)
    case encodedBlobTooLarge(actual: Int, maximum: Int)
    case unsupportedEnvelopeVersion(Int)
    case invalidEnvelope
    case blobAlreadyExists
    case checksumMismatch(expected: String, actual: String)
    case postWriteVerificationFailed
}

/// Stores only secure-coded ARWorldMap archives. Camera/depth pixel buffers have
/// no persistence entry point, and arbitrary Data fails secure type validation.
public actor ARWorldMapBlobStore {
    struct Envelope: Codable, Sendable {
        let magic: String
        let version: Int
        let id: WorldMapBlobID
        let createdAt: Date
        let archive: Data
        let sha256: String
    }

    private static let magic = "VISPACE-ARWORLDMAP"
    private static let version = 1
    private static let fileExtension = "vispacemap"

    private let directoryURL: URL
    private let maximumArchiveBytes: Int
    private let maximumEncodedBlobBytes: Int
    private let fileManager: FileManager
    private let archiveValidator: @Sendable (Data) throws -> Void

    public init(
        directoryURL: URL,
        maximumArchiveBytes: Int = ARWorldMapArchiveCodec.maximumArchiveBytes,
        fileManager: FileManager = .default
    ) {
        let envelopeAllowance = 1 * 1_024 * 1_024
        let boundedMaximum = min(
            max(1, maximumArchiveBytes),
            ARWorldMapArchiveCodec.maximumArchiveBytes
        )
        self.directoryURL = directoryURL.standardizedFileURL
        self.maximumArchiveBytes = boundedMaximum
        maximumEncodedBlobBytes = boundedMaximum + envelopeAllowance
        self.fileManager = fileManager
        archiveValidator = { archive in
            _ = try ARWorldMapArchiveCodec.unarchive(archive)
        }
    }

    #if DEBUG
        /// Debug-only seam for testing the envelope and file-integrity layer without
        /// fabricating an `ARWorldMap`, which ARKit does not expose as a fixture API.
        /// Release builds expose only the secure public initializer above.
        init(
            directoryURL: URL,
            maximumArchiveBytes: Int,
            fileManager: FileManager = .default,
            archiveValidator: @escaping @Sendable (Data) throws -> Void
        ) {
            let envelopeAllowance = 1 * 1_024 * 1_024
            let boundedMaximum = min(
                max(1, maximumArchiveBytes),
                ARWorldMapArchiveCodec.maximumArchiveBytes
            )
            self.directoryURL = directoryURL.standardizedFileURL
            self.maximumArchiveBytes = boundedMaximum
            maximumEncodedBlobBytes = boundedMaximum + envelopeAllowance
            self.fileManager = fileManager
            self.archiveValidator = archiveValidator
        }
    #endif

    @discardableResult
    public func saveArchive(
        _ archive: Data,
        id: WorldMapBlobID = WorldMapBlobID(),
        createdAt: Date = Date()
    ) throws -> WorldMapBlobRecord {
        try validateArchiveSize(archive)
        // Type-confusion guard: arbitrary Data (including camera pixels) is
        // rejected unless Apple's secure unarchiver proves it is ARWorldMap.
        try archiveValidator(archive)
        try prepareDirectory()

        let digest = Self.sha256(archive)
        let envelope = Envelope(
            magic: Self.magic,
            version: Self.version,
            id: id,
            createdAt: createdAt,
            archive: archive,
            sha256: digest
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= maximumEncodedBlobBytes else {
            throw WorldMapBlobStoreError.encodedBlobTooLarge(
                actual: encoded.count,
                maximum: maximumEncodedBlobBytes
            )
        }

        let destination = fileURL(for: id)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorldMapBlobStoreError.blobAlreadyExists
        }
        try publish(encoded, to: destination, id: id)

        do {
            let verified = try loadEnvelope(at: destination, expectedID: id)
            guard
                verified.archive == archive,
                verified.sha256 == digest
            else {
                throw WorldMapBlobStoreError.postWriteVerificationFailed
            }
        } catch {
            // Avoid returning a reference to a partially valid blob. Removal is
            // narrowly scoped to the typed destination created above.
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return WorldMapBlobRecord(
            id: id,
            createdAt: createdAt,
            byteCount: archive.count,
            sha256: digest,
            fileURL: destination
        )
    }

    public func loadArchive(id: WorldMapBlobID) throws -> Data {
        let archive = try loadEnvelope(at: fileURL(for: id), expectedID: id).archive
        try archiveValidator(archive)
        return archive
    }

    public func contains(id: WorldMapBlobID) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: id).path)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private func fileURL(for id: WorldMapBlobID) -> URL {
        directoryURL.appendingPathComponent(
            "\(id.rawValue.uuidString.lowercased()).\(Self.fileExtension)",
            isDirectory: false
        )
    }

    private func publish(_ encoded: Data, to destination: URL, id: WorldMapBlobID) throws {
        let stagingURL = directoryURL.appendingPathComponent(
            ".\(id.rawValue.uuidString.lowercased()).\(UUID().uuidString.lowercased()).staged",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        // Foundation deliberately traps when `.atomic` and `.withoutOverwriting`
        // are combined. Write a complete, protected staging inode first, then
        // publish it with a hard link. Linking on the same filesystem is atomic
        // and fails rather than replacing an existing destination.
        try encoded.write(
            to: stagingURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )

        do {
            try fileManager.linkItem(at: stagingURL, to: destination)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == CocoaError.Code.fileWriteFileExists.rawValue
            {
                throw WorldMapBlobStoreError.blobAlreadyExists
            }
            throw error
        }
    }

    private func loadEnvelope(
        at fileURL: URL,
        expectedID: WorldMapBlobID
    ) throws -> Envelope {
        let encoded = try readEncodedBlob(at: fileURL)
        guard encoded.count <= maximumEncodedBlobBytes else {
            throw WorldMapBlobStoreError.encodedBlobTooLarge(
                actual: encoded.count,
                maximum: maximumEncodedBlobBytes
            )
        }

        let envelope: Envelope
        do {
            envelope = try PropertyListDecoder().decode(Envelope.self, from: encoded)
        } catch {
            throw WorldMapBlobStoreError.invalidEnvelope
        }

        guard envelope.magic == Self.magic, envelope.id == expectedID else {
            throw WorldMapBlobStoreError.invalidEnvelope
        }
        guard envelope.version == Self.version else {
            throw WorldMapBlobStoreError.unsupportedEnvelopeVersion(envelope.version)
        }
        guard
            envelope.sha256.utf8.count == 64,
            envelope.sha256.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            throw WorldMapBlobStoreError.invalidEnvelope
        }
        try validateArchiveSize(envelope.archive)

        let actualDigest = Self.sha256(envelope.archive)
        guard actualDigest == envelope.sha256 else {
            throw WorldMapBlobStoreError.checksumMismatch(
                expected: envelope.sha256,
                actual: actualDigest
            )
        }
        return envelope
    }

    private func readEncodedBlob(at fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let readLimit = maximumEncodedBlobBytes + 1
        let chunkSize = 64 * 1_024
        var encoded = Data()
        encoded.reserveCapacity(min(readLimit, chunkSize))

        while encoded.count < readLimit {
            let remaining = readLimit - encoded.count
            guard
                let chunk = try handle.read(upToCount: min(remaining, chunkSize)),
                !chunk.isEmpty
            else {
                break
            }
            encoded.append(chunk)
        }
        return encoded
    }

    private func validateArchiveSize(_ archive: Data) throws {
        guard !archive.isEmpty else {
            throw WorldMapBlobStoreError.emptyArchive
        }
        guard archive.count <= maximumArchiveBytes else {
            throw WorldMapBlobStoreError.archiveTooLarge(
                actual: archive.count,
                maximum: maximumArchiveBytes
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
