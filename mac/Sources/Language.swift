import Foundation
import NaturalLanguage

enum Language: String, Codable, CaseIterable {
    case chinese = "zh"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case bengali = "bn"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case turkish = "tr"
    case dutch = "nl"
    case polish = "pl"
    case ukrainian = "uk"
    case swedish = "sv"
    case greek = "el"
    case hebrew = "he"
    case persian = "fa"

    var label: String {
        switch self {
        case .chinese: "中"
        case .english: "英"
        case .traditionalChinese: "繁"
        case .japanese: "日"
        case .korean: "韩"
        case .french: "法"
        case .german: "德"
        case .spanish: "西"
        case .portuguese: "葡"
        case .italian: "意"
        case .russian: "俄"
        case .arabic: "阿"
        case .hindi: "印地"
        case .bengali: "孟"
        case .thai: "泰"
        case .vietnamese: "越"
        case .indonesian: "印尼"
        case .malay: "马"
        case .turkish: "土"
        case .dutch: "荷"
        case .polish: "波"
        case .ukrainian: "乌"
        case .swedish: "瑞"
        case .greek: "希"
        case .hebrew: "希伯"
        case .persian: "波斯"
        }
    }

    var name: String {
        if self == .chinese { return "简体中文" }
        if self == .traditionalChinese { return "繁體中文" }
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    var promptName: String {
        if self == .chinese { return "Simplified Chinese" }
        if self == .traditionalChinese { return "Traditional Chinese" }
        return Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    fileprivate var isChinese: Bool { self == .chinese || self == .traditionalChinese }

    fileprivate var recognitionCode: NLLanguage {
        if self == .chinese { return .simplifiedChinese }
        return NLLanguage(rawValue: rawValue)
    }
}

struct Direction: Equatable {
    let source: Language
    let target: Language

    var reversed: Self { Self(source: target, target: source) }
    var label: String { "\(source.label) → \(target.label)" }
    var key: String { source.rawValue + "-" + target.rawValue }

    var hasLocalDictionary: Bool {
        (source == .chinese && [.english, .japanese].contains(target))
            || (target == .chinese && [.english, .japanese].contains(source))
    }
}

struct LanguageSettings: Equatable {
    private static let primaryKey = "language.primary"
    private static let secondKey = "language.defaultSecondary"

    let primary: Language
    let defaultSecond: Language

    init(primary: Language = .chinese, defaultSecond: Language = .english) {
        self.primary = primary
        self.defaultSecond = primary == defaultSecond ? (primary == .english ? .chinese : .english) : defaultSecond
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let primary = defaults.string(forKey: primaryKey).flatMap(Language.init(rawValue:)) ?? .chinese
        let second = defaults.string(forKey: secondKey).flatMap(Language.init(rawValue:)) ?? .english
        return Self(primary: primary, defaultSecond: second)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(primary.rawValue, forKey: Self.primaryKey)
        defaults.set(defaultSecond.rawValue, forKey: Self.secondKey)
    }
}

struct LookupSession {
    static let idleSeconds: TimeInterval = 5 * 60
    let settings: LanguageSettings
    private(set) var second: Language
    private var lastActivity: Date?

    init(settings: LanguageSettings = .init()) {
        self.settings = settings
        second = settings.defaultSecond
    }

    mutating func select(_ language: Language, at now: Date = .now) {
        guard language != settings.primary else { return }
        second = language
        lastActivity = now
    }

    @discardableResult
    mutating func touch(at now: Date = .now) -> Bool {
        let expired = lastActivity.map { now.timeIntervalSince($0) >= Self.idleSeconds } ?? false
        let changed = expired && second != settings.defaultSecond
        if changed { second = settings.defaultSecond }
        lastActivity = now
        return changed
    }

    func direction(for text: String, dictionary: LocalDictionary) -> (Direction, ambiguous: Bool) {
        let primary = settings.primary
        let forward = Direction(source: primary, target: second)
        let scalars = text.prefix(800).unicodeScalars
        let kana = scalars.contains { scalar in
            (0x3041...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value)
        }
        if kana, primary == .japanese || second == .japanese {
            return (primary == .japanese ? forward : forward.reversed, false)
        }
        let hangul = scalars.contains { scalar in
            (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
        if hangul, primary == .korean || second == .korean {
            return (primary == .korean ? forward : forward.reversed, false)
        }

        if primary.isChinese != second.isChinese {
            let fromChinese = primary.isChinese ? forward : forward.reversed
            let han = scalars.contains { scalar in
                (0x3400...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
                    || (0x20000...0x323AF).contains(scalar.value)
            }
            if han, fromChinese.target == .japanese {
                let chinese = !dictionary.lookup(text, direction: fromChinese).isEmpty
                let japanese = !dictionary.lookup(text, direction: fromChinese.reversed).isEmpty
                return (japanese && !chinese ? fromChinese.reversed : fromChinese, chinese == japanese)
            }
            if han { return (fromChinese, false) }
            if fromChinese.target != .japanese, scalars.contains(where: { $0.properties.isAlphabetic }) {
                return (fromChinese.reversed, false)
            }
        }

        guard scalars.contains(where: { $0.properties.isAlphabetic }) else { return (forward, true) }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [primary.recognitionCode, second.recognitionCode]
        recognizer.processString(String(text.prefix(800)))
        let scores = recognizer.languageHypotheses(withMaximum: 2)
        let firstScore = scores[primary.recognitionCode, default: 0]
        let secondScore = scores[second.recognitionCode, default: 0]
        let best = secondScore > firstScore ? forward.reversed : forward
        return (best, max(firstScore, secondScore) < 0.65 || abs(firstScore - secondScore) < 0.2)
    }
}
