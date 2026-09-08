import Foundation

public enum SpatialCommandRejection: String, Equatable, Sendable {
    case empty
    case tooLong
    case ambiguousFurniture
    case negatedPlacement
    case unsupportedFurniture
}

public enum SpatialCommand: Equatable, Sendable {
    case objectQuery(String)
    case relationQuery(String)
    case placement(FurnitureKind)
    case rejected(SpatialCommandRejection)
}

/// Bounded dispatch, not unrestricted natural-language understanding. Domain
/// query engines still validate and ground object/relation requests.
public struct SpatialCommandParser: Sendable {
    public static let maximumCharacters = 256
    public static let maximumUnicodeScalars = 1_024

    public init() {}

    public func parse(_ input: String) -> SpatialCommand {
        // Bound scalar work before Unicode normalization or grapheme counting.
        guard
            input.unicodeScalars.prefix(Self.maximumUnicodeScalars + 1).count
                <= Self.maximumUnicodeScalars
        else { return .rejected(.tooLong) }
        let text = input.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected(.empty) }
        guard text.count <= Self.maximumCharacters else { return .rejected(.tooLong) }
        let normalized = text.lowercased()
        let intent = DeterministicIntentRouter().route(normalized)
        // A described placement ("where did I put the sofa?") is not a
        // request to evaluate a new placement. Preserve explicit history and
        // navigation commands before the weak furniture-language heuristic.
        if intent.kind == .lastSeen || intent.kind == .navigate {
            return .objectQuery(text)
        }
        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let placementSignal =
            ["놓", "배치", "어때", "둘까", "두면"].contains(where: normalized.contains)
            || !tokens.isDisjoint(with: ["place", "fit", "recommend"])
        if placementSignal {
            let compact = normalized.filter { !$0.isWhitespace }
            let koreanNegated = ["놓지", "두지", "배치하지", "추천하지", "말아", "말고", "안놓", "안두", "안배치"]
                .contains(where: compact.contains)
            let englishNegated =
                !tokens.isDisjoint(with: ["not", "never", "don", "dont", "cannot", "without"])
                || (tokens.contains("can") && tokens.contains("t"))
            if koreanNegated || englishNegated { return .rejected(.negatedPlacement) }
            var kinds: [FurnitureKind] = []
            if normalized.contains("소파") || !tokens.isDisjoint(with: ["sofa", "couch"]) {
                kinds.append(.sofa)
            }
            if normalized.contains("침대") || tokens.contains("bed") { kinds.append(.bed) }
            if normalized.contains("책상") || tokens.contains("desk") { kinds.append(.desk) }
            if kinds.count > 1 { return .rejected(.ambiguousFurniture) }
            if let kind = kinds.first { return .placement(kind) }
            if intent.kind != .searchObject {
                return .rejected(.unsupportedFurniture)
            }
        }
        return intent.kind == .relationQuery
            ? .relationQuery(text) : .objectQuery(text)
    }
}
