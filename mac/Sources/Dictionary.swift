import Foundation
import SQLite3

struct DictionaryEntry: Equatable {
    let headword: String
    let detail: String
    let meaning: String
}

struct DictionaryResult: Equatable {
    struct Group: Equatable {
        let partOfSpeech: String?
        var meanings: [String]
    }

    private static let partOfSpeechLabels: Set<String> = [
        "名词", "动词", "形容词", "副词", "代词", "限定词", "介词", "连词", "短语"
    ]
    private static let separators = CharacterSet(charactersIn: "；;、")

    let groups: [Group]

    init(entries: [DictionaryEntry]) {
        var grouped: [Group] = []
        var seen: Set<String> = []
        for entry in entries {
            let fallbackPart = Self.partOfSpeech(in: entry.detail.components(separatedBy: " · ").last ?? "")
            for line in entry.meaning.split(whereSeparator: \.isNewline) {
                let sense = line.range(of: "  ").flatMap { separator in
                    Self.partOfSpeech(in: String(line[..<separator.lowerBound])).map { part in
                        (part, String(line[separator.upperBound...]))
                    }
                }
                let part = sense?.0 ?? fallbackPart
                let meaning = sense?.1 ?? String(line)
                let meanings = meaning.replacingOccurrences(of: " / ", with: "；")
                    .components(separatedBy: Self.separators)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert(LocalDictionary.normalize($0)).inserted }
                guard !meanings.isEmpty else { continue }
                if let index = grouped.firstIndex(where: { $0.partOfSpeech == part }) {
                    grouped[index].meanings.append(contentsOf: meanings)
                } else {
                    grouped.append(Group(partOfSpeech: part, meanings: meanings))
                }
            }
        }
        groups = grouped
    }

    var plainText: String {
        groups.map { group in
            let meanings = group.meanings.joined(separator: "、")
            return group.partOfSpeech.map { "\($0)  \(meanings)" } ?? meanings
        }.joined(separator: "\n")
    }

    private static func partOfSpeech(in text: String) -> String? {
        let parts = text.split(separator: "、")
        return !parts.isEmpty && parts.allSatisfy { partOfSpeechLabels.contains(String($0)) } ? text : nil
    }
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
        guard direction.hasLocalDictionary else { return [] }
        let sentencePunctuation = CharacterSet(charactersIn: "。！？!?").union(.whitespaces)
        let key = Self.normalize(text).trimmingCharacters(in: sentencePunctuation)
        guard !key.isEmpty, key.count <= 80, let database = open() else { return [] }
        let sql = """
            SELECT headword, detail, meaning, priority FROM entries
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
        var reviewed = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let priority = sqlite3_column_int(statement, 3)
            if results.isEmpty { reviewed = priority == 0 }
            if reviewed && priority != 0 { break }
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
