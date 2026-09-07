import Foundation

/// A vocabulary entry describes a class, never an observed object or its position.
public struct ObjectSemanticClass: Hashable, Sendable {
    public let canonicalLabel: String
    public let koreanName: String
    public let aliases: [String]
    public let supportsAutomaticDetection: Bool

    public var searchTerms: [String] { [canonicalLabel, koreanName] + aliases }
}

/// Shared vocabulary for the bundled detector, search, and human-readable labels.
/// Legacy model identifiers remain canonical so existing saved records still match.
public struct ObjectSemanticCatalog: Hashable, Sendable {
    public let entries: [ObjectSemanticClass]

    public var bundledModelLabels: [String] {
        entries.filter(\.supportsAutomaticDetection).map(\.canonicalLabel)
    }

    public func entry(for label: String) -> ObjectSemanticClass? {
        let key = Self.normalized(label)
        return entries.first { $0.searchTerms.contains { Self.normalized($0) == key } }
    }

    public func canonicalLabel(for label: String) -> String {
        entry(for: label)?.canonicalLabel ?? Self.normalized(label)
    }

    public func aliases(for label: String) -> [String] {
        guard let entry = entry(for: label) else { return [] }
        let key = Self.normalized(label)
        return Array(Set(entry.searchTerms.map(Self.normalized))).filter { $0 != key }.sorted()
    }

    public func displayName(for label: String) -> String {
        entry(for: label)?.koreanName ?? label
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func detected(_ label: String, _ korean: String, _ aliases: String...) -> ObjectSemanticClass {
        ObjectSemanticClass(canonicalLabel: label, koreanName: korean, aliases: aliases,
                            supportsAutomaticDetection: true)
    }

    private static func manual(_ label: String, _ korean: String, _ aliases: String...) -> ObjectSemanticClass {
        ObjectSemanticClass(canonicalLabel: label, koreanName: korean, aliases: aliases,
                            supportsAutomaticDetection: false)
    }

    /// The first 80 entries follow YOLOv3Int8LUT.mlmodel's actual class order.
    /// Manual categories are understood by search but require a real saved record.
    public static let `default` = Self(entries: [
        detected("person", "사람", "인물"),
        detected("bicycle", "자전거", "bike"),
        detected("car", "자동차", "차", "승용차"),
        detected("motorbike", "오토바이", "motorcycle", "모터사이클"),
        detected("aeroplane", "비행기", "airplane", "항공기"),
        detected("bus", "버스"),
        detected("train", "기차", "열차"),
        detected("truck", "트럭", "화물차"),
        detected("boat", "보트", "배"),
        detected("traffic light", "신호등"),
        detected("fire hydrant", "소화전"),
        detected("stop sign", "정지 표지판", "정지표지판"),
        detected("parking meter", "주차 요금기", "주차요금기", "주차 미터기"),
        detected("bench", "벤치"),
        detected("bird", "새"),
        detected("cat", "고양이"),
        detected("dog", "개", "강아지"),
        detected("horse", "말"),
        detected("sheep", "양"),
        detected("cow", "소"),
        detected("elephant", "코끼리"),
        detected("bear", "곰"),
        detected("zebra", "얼룩말"),
        detected("giraffe", "기린"),
        detected("backpack", "백팩", "배낭"),
        detected("umbrella", "우산"),
        detected("handbag", "가방", "bag", "핸드백"),
        detected("tie", "넥타이"),
        detected("suitcase", "여행 가방", "여행가방", "캐리어"),
        detected("frisbee", "프리스비", "원반"),
        detected("skis", "스키"),
        detected("snowboard", "스노보드"),
        detected("sports ball", "공", "운동공", "축구공", "농구공", "야구공", "테니스공"),
        detected("kite", "연"),
        detected("baseball bat", "야구 방망이", "야구방망이", "야구 배트"),
        detected("baseball glove", "야구 글러브", "야구글러브", "야구 장갑"),
        detected("skateboard", "스케이트보드"),
        detected("surfboard", "서핑보드", "서프보드"),
        detected("tennis racket", "테니스 라켓", "테니스라켓", "tennis racquet"),
        detected("bottle", "병", "water bottle", "물병"),
        detected("wine glass", "와인 잔", "와인잔"),
        detected("cup", "컵", "mug", "잔", "머그컵"),
        detected("fork", "포크"),
        detected("knife", "칼", "나이프"),
        detected("spoon", "숟가락", "수저", "스푼"),
        detected("bowl", "그릇", "사발"),
        detected("banana", "바나나"),
        detected("apple", "사과"),
        detected("sandwich", "샌드위치"),
        detected("orange", "오렌지", "귤"),
        detected("broccoli", "브로콜리"),
        detected("carrot", "당근"),
        detected("hot dog", "핫도그"),
        detected("pizza", "피자"),
        detected("donut", "도넛", "doughnut", "도너츠"),
        detected("cake", "케이크", "케익"),
        detected("chair", "의자"),
        detected("sofa", "소파", "couch", "쇼파"),
        detected("pottedplant", "화분", "potted plant", "plant", "식물"),
        detected("bed", "침대"),
        detected("diningtable", "테이블", "dining table", "table", "탁자", "식탁"),
        detected("toilet", "변기"),
        detected("tvmonitor", "모니터", "tv", "television", "monitor", "텔레비전", "텔레비젼", "티비", "티브이", "티브이 모니터"),
        detected("laptop", "노트북", "notebook computer"),
        detected("mouse", "마우스"),
        detected("remote", "리모컨", "remote control", "리모콘"),
        detected("keyboard", "키보드"),
        detected("cell phone", "휴대폰", "phone", "smartphone", "핸드폰", "스마트폰", "휴대전화"),
        detected("microwave", "전자레인지", "전자렌지"),
        detected("oven", "오븐"),
        detected("toaster", "토스터", "토스터기"),
        detected("sink", "싱크대", "개수대"),
        detected("refrigerator", "냉장고", "fridge"),
        detected("book", "책", "책자"),
        detected("clock", "시계", "벽시계", "탁상시계"),
        detected("vase", "꽃병"),
        detected("scissors", "가위"),
        detected("teddy bear", "곰 인형", "곰인형", "테디베어"),
        detected("hair drier", "헤어드라이어", "hair dryer", "드라이어", "드라이기"),
        detected("toothbrush", "칫솔"),
        manual("key", "열쇠", "keys", "키"),
        manual("wallet", "지갑"),
        manual("desk", "책상"),
        manual("speaker", "스피커", "스피커폰"),
        manual("desktop computer", "컴퓨터 본체", "desktop", "pc", "computer", "컴퓨터", "본체", "데스크톱", "데스크탑"),
        manual("cable", "케이블", "wire", "전선", "충전선", "충전 케이블"),
        manual("charger", "충전기", "충전 어댑터"),
        manual("power strip", "멀티탭"),
        manual("printer", "프린터"),
        manual("camera", "카메라"),
        manual("headphones", "헤드폰", "헤드셋"),
        manual("earphones", "이어폰", "earbuds", "에어팟"),
        manual("mouse pad", "마우스패드", "마우스 패드"),
        manual("keyboard case", "키보드 케이스", "키보드케이스"),
        manual("glasses", "안경"),
        manual("pen", "펜", "볼펜"),
        manual("pencil", "연필"),
        manual("watch", "손목시계", "스마트워치"),
        manual("user_registered_object", "직접 등록한 물체", "user registered object", "직접등록한물체"),
    ])
}
