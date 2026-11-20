import Foundation
import NaturalLanguage
import SQLite3

struct DictionaryEntry: Equatable {
    let headword: String
    let detail: String
    let meaning: String
}

struct DictionaryResult: Equatable {
    struct Row: Equatable {
        let meaning: String
        var partsOfSpeech: [String]

        var plainText: String {
            partsOfSpeech.isEmpty ? meaning : "\(meaning)  \(partsOfSpeech.joined(separator: "、"))"
        }
    }

    private static let partOfSpeechLabels: Set<String> = [
        "名词", "动词", "形容词", "副词", "代词", "限定词", "介词", "连词", "短语"
    ]
    private static let separators = CharacterSet(charactersIn: "；;、")
    let formNote: String?
    let rows: [Row]

    init(entries: [DictionaryEntry], target: Language? = nil, formNote: String? = nil) {
        self.formNote = formNote
        var rows: [Row] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            let fallback = Self.partsOfSpeech(in: entry.detail.components(separatedBy: " · ").last ?? "")
            for line in entry.meaning.split(whereSeparator: \.isNewline) {
                let sense = line.range(of: "  ").flatMap { separator -> ([String], String)? in
                    let parts = Self.partsOfSpeech(in: String(line[..<separator.lowerBound]))
                    return parts.isEmpty ? nil : (parts, String(line[separator.upperBound...]))
                }
                let parts = sense?.0 ?? fallback
                let meaning = sense?.1 ?? String(line)
                let glosses = meaning.replacingOccurrences(of: " / ", with: "；")
                    .components(separatedBy: Self.separators)
                for gloss in glosses {
                    let gloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !gloss.isEmpty else { continue }
                    let lexicalParts = target == .english ? gloss.components(separatedBy: ", ").map(Self.englishWord) : []
                    let candidates: [(String, [String])]
                    if !lexicalParts.isEmpty && lexicalParts.allSatisfy({ $0 != nil }) {
                        candidates = lexicalParts.compactMap { $0 }.map { ($0.word, parts.isEmpty ? $0.parts : parts) }
                    } else {
                        candidates = [(gloss, parts)]
                    }
                    for (word, tags) in candidates {
                        let key = LocalDictionary.normalize(word)
                        if let index = positions[key] {
                            rows[index].partsOfSpeech += tags.filter { !rows[index].partsOfSpeech.contains($0) }
                        } else {
                            positions[key] = rows.count
                            rows.append(Row(meaning: word, partsOfSpeech: tags))
                        }
                    }
                }
            }
        }
        self.rows = rows
    }

    var plainText: String {
        ([formNote].compactMap { $0 } + rows.map(\.plainText)).joined(separator: "\n")
    }

    private static func partsOfSpeech(in text: String) -> [String] {
        let parts = text.split(separator: "、").map(String.init)
        return parts.allSatisfy { partOfSpeechLabels.contains($0) } ? parts : []
    }

    private static func englishWord(_ gloss: String) -> (word: String, parts: [String])? {
        let words = gloss.split(separator: " ")
        guard let word = words.last, word.range(of: #"^[A-Za-z][A-Za-z'’\-]*$"#, options: .regularExpression) != nil
        else { return nil }
        if words.count == 1 { return (String(word), []) }
        guard words.count == 2 else { return nil }
        switch words[0].lowercased() {
        case "to": return (String(word), ["动词"])
        case "a", "an", "the": return (String(word), ["名词"])
        default: return nil
        }
    }
}

final class LocalDictionary {
    private static let englishToChinese = Direction(source: .english, target: .chinese)
    private static let irregular: [String: (past: String, participle: String)] = [
        "be": ("was / were", "been"), "begin": ("began", "begun"), "break": ("broke", "broken"),
        "bring": ("brought", "brought"), "build": ("built", "built"), "buy": ("bought", "bought"),
        "catch": ("caught", "caught"), "choose": ("chose", "chosen"), "come": ("came", "come"),
        "do": ("did", "done"), "draw": ("drew", "drawn"), "drink": ("drank", "drunk"),
        "drive": ("drove", "driven"), "eat": ("ate", "eaten"), "fall": ("fell", "fallen"),
        "feel": ("felt", "felt"), "find": ("found", "found"), "fly": ("flew", "flown"),
        "forget": ("forgot", "forgotten"), "give": ("gave", "given"), "go": ("went", "gone"),
        "have": ("had", "had"), "hear": ("heard", "heard"), "keep": ("kept", "kept"),
        "know": ("knew", "known"), "leave": ("left", "left"), "lose": ("lost", "lost"),
        "make": ("made", "made"), "meet": ("met", "met"), "pay": ("paid", "paid"),
        "put": ("put", "put"), "read": ("read", "read"), "ride": ("rode", "ridden"),
        "run": ("ran", "run"), "say": ("said", "said"), "see": ("saw", "seen"),
        "sell": ("sold", "sold"), "send": ("sent", "sent"), "sing": ("sang", "sung"),
        "sit": ("sat", "sat"), "sleep": ("slept", "slept"), "speak": ("spoke", "spoken"),
        "stand": ("stood", "stood"), "swim": ("swam", "swum"), "take": ("took", "taken"),
        "teach": ("taught", "taught"), "tell": ("told", "told"), "think": ("thought", "thought"),
        "understand": ("understood", "understood"), "wear": ("wore", "worn"),
        "win": ("won", "won"), "write": ("wrote", "written")
    ]
    private static let passiveAuxiliaries: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being", "has been", "have been", "had been",
        "am being", "is being", "are being", "was being", "were being",
        "will be", "would be", "can be", "could be", "should be", "must be"
    ]
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

    func search(_ text: String, direction: Direction) -> DictionaryResult {
        let exact = lookup(text, direction: direction)
        if exact.isEmpty, direction == Self.englishToChinese, let inflection = englishInflection(text) {
            return inflection
        }
        return DictionaryResult(entries: exact, target: direction.target)
    }

    func englishInflection(_ text: String) -> DictionaryResult? {
        let words = Self.normalize(text).trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
            .split(separator: " ")
        guard let last = words.last, (3...30).contains(last.count),
              last.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        let form = String(last)
        let auxiliary = words.dropLast().joined(separator: " ")
        guard auxiliary.isEmpty || Self.passiveAuxiliaries.contains(auxiliary) else { return nil }

        if form.hasSuffix("ed") {
            let stem = String(form.dropLast(2))
            var candidates = [stem, String(form.dropLast())]
            if stem.last == stem.dropLast().last { candidates.append(String(stem.dropLast())) }
            for lemma in candidates {
                guard let forms = Self.irregular[lemma], forms.past != form, forms.participle != form else { continue }
                let entries = lookup(lemma, direction: Self.englishToChinese)
                guard !entries.isEmpty else { continue }
                let suggestion = auxiliary.isEmpty
                    ? "拼写更正 · 过去式 \(forms.past) · 过去分词 \(forms.participle)"
                    : "拼写更正 · \(auxiliary) \(forms.participle)"
                return DictionaryResult(entries: entries, target: .chinese, formNote: "\(suggestion)\n原形 \(lemma)")
            }
        }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = form
        tagger.setLanguage(.english, range: form.startIndex..<form.endIndex)
        let lemma = tagger.tag(at: form.startIndex, unit: .word, scheme: .lemma).0?.rawValue ?? form
        let knownForms = Self.irregular[lemma]
        let participle = knownForms?.participle == form || (knownForms == nil && form.hasSuffix("ed") && form != lemma)
        let wrongPassive = !auxiliary.isEmpty && !participle && knownForms?.past == form
        guard auxiliary.isEmpty ? lemma != form : (participle || wrongPassive) else { return nil }
        let entries = lookup(lemma, direction: Self.englishToChinese)
        guard !entries.isEmpty else { return nil }
        if wrongPassive, let knownForms {
            return DictionaryResult(entries: entries, target: .chinese,
                                    formNote: "拼写更正 · \(auxiliary) \(knownForms.participle)\n原形 \(lemma)")
        }
        let presentation = auxiliary.isEmpty ? "原形 \(lemma)" : "被动形式 \(auxiliary) \(form) · 原形 \(lemma)"
        let forms: String
        if let knownForms {
            forms = "\n过去式 \(knownForms.past) · 过去分词 \(knownForms.participle)"
        } else {
            forms = participle ? "\n过去式 / 过去分词 \(form)" : ""
        }
        return DictionaryResult(entries: entries, target: .chinese, formNote: presentation + forms)
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
