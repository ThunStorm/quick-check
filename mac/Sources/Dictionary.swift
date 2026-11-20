import Foundation
import SQLite3

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
        guard direction.hasLocalDictionary else { return [] }
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
