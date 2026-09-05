import Foundation

/// Applies the on-device storage policy to one exact spatial-data directory.
/// Call before accessing an existing store as well as before publishing new data.
enum SpatialStorageDirectory {
    static func prepare(
        at directoryURL: URL,
        fileManager: FileManager = .default,
        createIfMissing: Bool = true
    ) throws {
        var directory = directoryURL.standardizedFileURL
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
}
