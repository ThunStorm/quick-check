import Foundation
import SQLite3

enum Language: String, Codable, CaseIterable {
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"

    var label: String {
        switch self {
        case .chinese: "中"
        case .english: "英"
        case .japanese: "日"
        }
    }

    var name: String {
        switch self {
        case .chinese: "简体中文"
        case .english: "英语"
        case .japanese: "日语"
        }
    }

    var promptName: String {
        switch self {
        case .chinese: "Simplified Chinese"
        case .english: "English"
        case .japanese: "Japanese"
        }
    }
}

struct Direction: Equatable {
    var source: Language
    var target: Language

    var reversed: Self { Self(source: target, target: source) }
    var label: String { "\(source.label) → \(target.label)" }
    var key: String { source.rawValue + "-" + target.rawValue }
}

struct DictionaryEntry: Equatable {
    let headword: String
    let detail: String
    let meaning: String
}

final class LocalDictionary {
    private let url: URL
    private var database: OpaquePointer?

    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close(database) } }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func lookup(_ text: String, direction: Direction) -> [DictionaryEntry] {
        let key = Self.normalize(text)
        guard !key.isEmpty, key.count <= 80, let database = open() else { return [] }
        let sql = """
            SELECT headword, detail, meaning FROM entries
            WHERE direction = ? AND query = ?
            ORDER BY priority, headword, meaning LIMIT 5
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, direction.key, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)

        var results: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(DictionaryEntry(
                headword: String(cString: sqlite3_column_text(statement, 0)),
                detail: String(cString: sqlite3_column_text(statement, 1)),
                meaning: String(cString: sqlite3_column_text(statement, 2))
            ))
        }
        return results
    }

    private func open() -> OpaquePointer? {
        if let database { return database }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        database = opened
        if let opened { sqlite3_exec(opened, "PRAGMA cache_size=-512", nil, nil, nil) }
        return database
    }
}

struct LookupSession {
    static let idleSeconds: TimeInterval = 5 * 60
    private(set) var second: Language = .english
    private var lastActivity: Date?

    mutating func select(_ language: Language, at now: Date = .now) {
        second = language
        lastActivity = now
    }

    @discardableResult
    mutating func touch(at now: Date = .now) -> Bool {
        let expired = lastActivity.map { now.timeIntervalSince($0) >= Self.idleSeconds } ?? false
        let changed = expired && second != .english
        if changed { second = .english }
        lastActivity = now
        return changed
    }

    func direction(for text: String, dictionary: LocalDictionary) -> (Direction, ambiguous: Bool) {
        let scalars = text.unicodeScalars
        let kana = scalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value)
        }
        let han = scalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x323AF).contains(scalar.value)
        }
        let fromChinese = Direction(source: .chinese, target: second)
        if second == .english { return (han ? fromChinese : fromChinese.reversed, false) }
        if kana { return (fromChinese.reversed, false) }
        if han {
            let chinese = !dictionary.lookup(text, direction: fromChinese).isEmpty
            let japanese = !dictionary.lookup(text, direction: fromChinese.reversed).isEmpty
            return (japanese && !chinese ? fromChinese.reversed : fromChinese, chinese == japanese)
        }
        return (fromChinese, true)
    }
}
