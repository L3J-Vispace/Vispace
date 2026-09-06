import Foundation

public enum SpatialIntentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case searchObject
    case lastSeen
    case navigate
    case relationQuery
    case complexAsk
}

public struct IntentRoute: Codable, Hashable, Sendable {
    public let kind: SpatialIntentKind
    public let normalizedUtterance: String
    public let matchedSignals: [String]
    public let requiresLLM: Bool

    public init(
        kind: SpatialIntentKind,
        normalizedUtterance: String,
        matchedSignals: [String],
        requiresLLM: Bool
    ) {
        self.kind = kind
        self.normalizedUtterance = normalizedUtterance
        self.matchedSignals = matchedSignals
        self.requiresLLM = requiresLLM
    }
}

/// Small deterministic router for the non-LLM intents described in the product
/// specification. It deliberately does not pretend to understand arbitrary
/// language; unmatched or ambiguous requests become `complexAsk`.
public struct DeterministicIntentRouter: Sendable {
    private struct Rule: Sendable {
        let kind: SpatialIntentKind
        let priority: Int
        let signals: [String]
    }

    private let rules: [Rule] = [
        Rule(
            kind: .lastSeen,
            priority: 500,
            signals: ["마지막", "아까", "전에 어디", "어디 있었", "last seen", "where was"]
        ),
        Rule(
            kind: .navigate,
            priority: 400,
            signals: ["안내", "경로", "어떻게 가", "까지 가", "navigate", "route", "directions"]
        ),
        Rule(
            kind: .relationQuery,
            priority: 300,
            signals: [
                "아래", "위에", "옆에", "안에", "막고", "가까이", "왼쪽", "오른쪽",
                "연결", "접근", "under", "above", "inside", "blocking", "near",
                "left of", "right of", "connected", "accessible", "on",
            ]
        ),
        Rule(
            kind: .searchObject,
            priority: 200,
            signals: ["어디", "어딨어", "어딨", "찾아", "찾아줘", "위치 알려", "위치를 알려",
                      "위치알려", "위치를알려", "where is", "find"]
        ),
    ]

    public init() {}

    public func route(_ utterance: String) -> IntentRoute {
        let normalized =
            utterance
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let matches = rules.compactMap { rule -> (Rule, [String])? in
            let matched = rule.signals.filter {
                Self.containsSignal($0, in: normalized)
            }
            return matched.isEmpty ? nil : (rule, matched)
        }
        let selected = matches.sorted { lhs, rhs in
            if lhs.0.priority != rhs.0.priority {
                return lhs.0.priority > rhs.0.priority
            }
            return lhs.0.kind.rawValue < rhs.0.kind.rawValue
        }.first

        guard let selected else {
            return IntentRoute(
                kind: .complexAsk,
                normalizedUtterance: normalized,
                matchedSignals: [],
                requiresLLM: true
            )
        }
        return IntentRoute(
            kind: selected.0.kind,
            normalizedUtterance: normalized,
            matchedSignals: selected.1.sorted(),
            requiresLLM: false
        )
    }

    private static func containsSignal(_ signal: String, in utterance: String) -> Bool {
        guard signal.unicodeScalars.allSatisfy({ $0.isASCII }),
            !signal.contains(" ")
        else {
            return utterance.contains(signal)
        }
        let tokens = utterance.split { character in
            !character.isLetter && !character.isNumber
        }
        return tokens.contains { $0 == signal }
    }
}
