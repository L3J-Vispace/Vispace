import Foundation

public enum SpatialStorageError: Error, Equatable, Sendable {
    case unsafePath
    case unsupportedSchema(actual: Int)
    case capacityExceeded(maximumBytes: Int64)
    case insufficientFreeSpace(requiredBytes: Int64)
}

/// Applies the on-device storage policy to one exact spatial-data directory.
/// Call before accessing an existing store as well as before publishing new data.
enum SpatialStorageDirectory {
    static let maximumTotalBytes: Int64 = 512 * 1_024 * 1_024
    static let minimumFreeBytes: Int64 = 128 * 1_024 * 1_024
    private static let writeLock = NSLock()

    static func prepare(
        at directoryURL: URL,
        fileManager: FileManager = .default,
        createIfMissing: Bool = true
    ) throws {
        var directory = directoryURL.standardizedFileURL
        try validatePath(at: directory, fileManager: fileManager)
        if !createIfMissing, !fileManager.fileExists(atPath: directory.path) {
            return
        }

        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: protection
        )
        // Creation attributes do not update an existing directory. Reapply the
        // policy so a store from an earlier app version is protected on access.
        try fileManager.setAttributes(protection, ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    /// Reject link traversal before opening, replacing, moving, or deleting a
    /// spatial file. The three system aliases are supplied by Apple's OS, not
    /// by this application's writable data directory.
    static func validatePath(at url: URL, fileManager: FileManager = .default) throws {
        guard url.isFileURL else { throw SpatialStorageError.unsafePath }
        var component = url.standardizedFileURL
        while component.path != "/" && !component.path.isEmpty {
            if let attributes = try? fileManager.attributesOfItem(atPath: component.path) {
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                    !["/var", "/tmp", "/etc"].contains(component.path)
                {
                    throw SpatialStorageError.unsafePath
                }
                if component != url.standardizedFileURL,
                    attributes[.type] as? FileAttributeType != .typeDirectory,
                    attributes[.type] as? FileAttributeType != .typeSymbolicLink
                {
                    throw SpatialStorageError.unsafePath
                }
            }
            let parent = component.deletingLastPathComponent()
            if parent == component { break }
            component = parent
        }
    }

    static func validateRegularFile(at url: URL, fileManager: FileManager = .default) throws {
        try validatePath(at: url, fileManager: fileManager)
        guard try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            == .typeRegular
        else { throw SpatialStorageError.unsafePath }
    }

    /// Probe versions before model decoders can wrap compatibility failures in
    /// DecodingError. A newer writer's bytes must remain at their original URL.
    static func validateJSONSchemas(
        _ data: Data, allowsLegacyRoot: Bool = false, maximumSchemaVersion: Int = 1
    ) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON catalog.")) }
        func checkedVersion(_ number: NSNumber) throws -> Int {
            guard number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue,
                number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max)
            else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Schema version must be an integer.")) }
            return number.intValue
        }
        func inspect(_ value: Any, isRoot: Bool) throws {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if ["schemaVersion", "policyVersion"].contains(key),
                        let number = child as? NSNumber {
                        let version = try checkedVersion(number)
                        let supported = key == "schemaVersion" ? (1...maximumSchemaVersion).contains(version) : version == 1
                        if !supported,
                            !(isRoot && key == "schemaVersion" && allowsLegacyRoot && version == 0) {
                            throw SpatialStorageError.unsupportedSchema(actual: version)
                        }
                    }
                    if key == "schema", let schema = child as? [String: Any],
                        let number = schema["version"] as? NSNumber {
                        let version = try checkedVersion(number)
                        if version != 1 { throw SpatialStorageError.unsupportedSchema(actual: version) }
                    }
                    try inspect(child, isRoot: false)
                }
            } else if let array = value as? [Any] {
                for child in array { try inspect(child, isRoot: false) }
            }
        }
        try inspect(object, isRoot: true)
    }

    static func atomicWrite(
        _ data: Data, to destination: URL, directory: URL,
        fileManager: FileManager = .default, reclaiming: Bool = false
    ) throws {
        try validatePath(at: destination, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try validateRegularFile(at: destination, fileManager: fileManager)
        }
        try withWriteBudget(bytes: data.count, at: directory, fileManager: fileManager, reclaiming: reclaiming) {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    static func totalBytes(at root: URL, fileManager: FileManager = .default) throws -> Int64 {
        try validatePath(at: root, fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { throw SpatialStorageError.unsafePath }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SpatialStorageError.unsafePath }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    /// Serializes byte admission and publication across independent repository
    /// actors. Include the full new inode because atomic replacement needs both
    /// old and new bytes until publication completes.
    static func withWriteBudget<T>(
        bytes: Int, at directory: URL, fileManager: FileManager = .default,
        reclaiming: Bool = false,
        write: () throws -> T
    ) throws -> T {
        try writeLock.withLock {
            let root = directory.lastPathComponent == "WorldMaps"
                ? directory.deletingLastPathComponent() : directory
            // Cleanup is best effort; admission still measures every retained
            // byte, and fails closed if the capacity cannot be reclaimed.
            try? maintainArtifacts(at: root, fileManager: fileManager)
            let current = try totalBytes(at: root, fileManager: fileManager)
            guard reclaiming || Int64(bytes) <= maximumTotalBytes - current else {
                throw SpatialStorageError.capacityExceeded(maximumBytes: maximumTotalBytes)
            }
            let attributes = try fileManager.attributesOfFileSystem(forPath: root.path)
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let required = (reclaiming ? 0 : minimumFreeBytes) + Int64(bytes)
            guard free >= required else {
                throw SpatialStorageError.insufficientFreeSpace(requiredBytes: required)
            }
            return try write()
        }
    }

    /// Only recognized quarantine artifacts and abandoned staging files are
    /// eligible. Active catalogs, checkpoints, backups, and unknown files are
    /// never selected by retention.
    static func maintainArtifacts(
        at root: URL, fileManager: FileManager = .default, now: Date = Date()
    ) throws {
        try validatePath(at: root, fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let directories = [root, root.appendingPathComponent("WorldMaps")]
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            try validatePath(at: directory, fileManager: fileManager)
            for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let stagingParts = url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
                if stagingParts.count == 4, stagingParts[0].isEmpty, stagingParts[3] == "staged",
                    UUID(uuidString: String(stagingParts[1])) != nil,
                    UUID(uuidString: String(stagingParts[2])) != nil {
                    try validateRegularFile(at: url, fileManager: fileManager)
                    let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
                    if now.timeIntervalSince(modified) > 24 * 60 * 60 { try fileManager.removeItem(at: url) }
                }
            }
            let quarantine = directory.appendingPathComponent("Quarantine")
            guard fileManager.fileExists(atPath: quarantine.path) else { continue }
            try validatePath(at: quarantine, fileManager: fileManager)
            var artifacts: [(url: URL, bytes: Int64, modified: Date)] = []
            for url in try fileManager.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
                let name = url.lastPathComponent
                let parts = name.split(separator: ".")
                let catalogNames = ["spatial-metadata-v1", "place-memory-v1", "coordinate-alignments-v1", "scene-graphs-v1", "temporal-spatial-memory-v1"]
                guard parts.count == 4,
                    catalogNames.contains(String(parts[0])) || UUID(uuidString: String(parts[0])) != nil,
                    UUID(uuidString: String(parts[1])) != nil,
                    name.hasSuffix(".quarantined") || name.hasSuffix(".reason.txt") || name.hasSuffix(".reason.plist")
                else { continue }
                try validateRegularFile(at: url, fileManager: fileManager)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                artifacts.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? now))
            }
            artifacts.sort { $0.modified < $1.modified }
            var bytes = artifacts.reduce(Int64(0)) { $0 + $1.bytes }
            var count = artifacts.count
            for artifact in artifacts {
                if count > 64 || bytes > 128 * 1_024 * 1_024 || now.timeIntervalSince(artifact.modified) > 30 * 24 * 60 * 60 {
                    try fileManager.removeItem(at: artifact.url)
                    count -= 1
                    bytes -= artifact.bytes
                }
            }
        }
    }
}
