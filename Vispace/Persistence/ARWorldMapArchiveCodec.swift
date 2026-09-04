@preconcurrency import ARKit
import Foundation

public enum ARWorldMapArchiveError: Error, Equatable, Sendable {
    case emptyArchive
    case archiveTooLarge(actual: Int, maximum: Int)
    case archiveFailed(message: String)
    case secureDecodeFailed(message: String)
    case decodedUnexpectedObject
}

/// Strict NSSecureCoding boundary for ARWorldMap. No legacy non-secure decode
/// path is provided, so a malformed or substituted object fails closed.
public enum ARWorldMapArchiveCodec {
    public static let maximumArchiveBytes = 128 * 1_024 * 1_024

    public static func archive(_ worldMap: ARWorldMap) throws -> Data {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: worldMap,
                requiringSecureCoding: true
            )
            guard !data.isEmpty else {
                throw ARWorldMapArchiveError.emptyArchive
            }
            guard data.count <= maximumArchiveBytes else {
                throw ARWorldMapArchiveError.archiveTooLarge(
                    actual: data.count,
                    maximum: maximumArchiveBytes
                )
            }
            return data
        } catch let error as ARWorldMapArchiveError {
            throw error
        } catch {
            throw ARWorldMapArchiveError.archiveFailed(
                message: String(describing: error)
            )
        }
    }

    public static func unarchive(_ data: Data) throws -> ARWorldMap {
        guard !data.isEmpty else {
            throw ARWorldMapArchiveError.emptyArchive
        }
        guard data.count <= maximumArchiveBytes else {
            throw ARWorldMapArchiveError.archiveTooLarge(
                actual: data.count,
                maximum: maximumArchiveBytes
            )
        }

        do {
            guard
                let worldMap = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: ARWorldMap.self,
                    from: data
                )
            else {
                throw ARWorldMapArchiveError.decodedUnexpectedObject
            }
            return worldMap
        } catch let error as ARWorldMapArchiveError {
            throw error
        } catch {
            throw ARWorldMapArchiveError.secureDecodeFailed(
                message: String(describing: error)
            )
        }
    }
}
