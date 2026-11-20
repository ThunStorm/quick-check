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

    fileprivate var recognitionCode: NLLanguage {
        if self == .chinese { return .simplifiedChinese }
        return NLLanguage(rawValue: rawValue)
    }
}

struct Direction: Equatable {
    let source: Language?
    let target: Language

    var label: String { "\(source?.label ?? "自动") → \(target.label)" }
    var key: String { (source?.rawValue ?? "") + "-" + target.rawValue }
    var isAlreadyInTarget: Bool { source == target }

    var hasLocalDictionary: Bool {
        switch (source, target) {
        case (.chinese?, .english), (.chinese?, .japanese), (.english?, .chinese), (.japanese?, .chinese):
            true
        default:
            false
        }
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
    private(set) var selectedTarget: Language?
    private var lastActivity: Date?

    init(settings: LanguageSettings = .init()) {
        self.settings = settings
    }

    mutating func select(_ target: Language?, at now: Date = .now) {
        selectedTarget = target
        lastActivity = now
    }

    @discardableResult
    mutating func touch(at now: Date = .now) -> Bool {
        let expired = lastActivity.map { now.timeIntervalSince($0) >= Self.idleSeconds } ?? false
        let changed = expired && selectedTarget != nil
        if changed { selectedTarget = nil }
        lastActivity = now
        return changed
    }

    func direction(for text: String, dictionary: LocalDictionary) -> Direction {
        let source = identify(text, dictionary: dictionary)
        let target = selectedTarget ?? (source == settings.primary ? settings.defaultSecond : settings.primary)
        return Direction(source: source, target: target)
    }

    private func identify(_ text: String, dictionary: LocalDictionary) -> Language? {
        let sample = String(text.prefix(800)).precomposedStringWithCompatibilityMapping
        let letters = sample.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return nil }

        let kana = letters.filter { scalar in
            (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value)
        }.count
        let hangul = letters.filter { scalar in
            (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }.count
        let han = letters.filter { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x323AF).contains(scalar.value)
        }.count
        if kana > 0 && (kana + han) * 2 >= letters.count { return .japanese }
        if hangul * 2 >= letters.count { return .korean }

        if han == letters.count && han <= 12 {
            let zhEnglish = Direction(source: .chinese, target: .english)
            let zhJapanese = Direction(source: .chinese, target: .japanese)
            let jaChinese = Direction(source: .japanese, target: .chinese)
            let chinese = !dictionary.lookup(text, direction: zhEnglish).isEmpty
                || !dictionary.lookup(text, direction: zhJapanese).isEmpty
            let japanese = !dictionary.lookup(text, direction: jaChinese).isEmpty
            if chinese { return .chinese }
            if japanese { return .japanese }
        }

        if letters.allSatisfy({ $0.isASCII }), dictionary.englishInflection(text) != nil {
            return .english
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let ranked = recognizer.languageHypotheses(withMaximum: 3)
            .sorted { $0.value > $1.value }
        if let best = ranked.first, best.value >= 0.60 {
            return Language.allCases.first { $0.recognitionCode == best.key }
        }
        if han * 2 >= letters.count { return .chinese }
        let english = Direction(source: .english, target: .chinese)
        if letters.allSatisfy({ $0.isASCII }), !dictionary.lookup(text, direction: english).isEmpty {
            return .english
        }
        return nil
    }
}
