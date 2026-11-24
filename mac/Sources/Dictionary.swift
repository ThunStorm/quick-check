import Foundation
import NaturalLanguage
import SQLite3

struct DictionaryEntry: Equatable {
    let headword: String
    let detail: String
    let meaning: String
}

struct DictionarySettings: Equatable, Codable {
    private static let key = "dictionary.settings"

    var useCEDICT = true
    var useTomoshi = true
    var useWordNet = true
    var showDefinitions = true
    var showExamples = true

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    func includes(_ direction: Direction) -> Bool {
        switch (direction.source, direction.target) {
        case (.chinese?, .english), (.english?, .chinese): useCEDICT
        case (.chinese?, .japanese), (.japanese?, .chinese): useTomoshi
        default: false
        }
    }
}

struct DictionarySense: Equatable {
    let word: String
    let partOfSpeech: String
    let definition: String?
    let examples: [String]

    var plainText: String {
        ([word + "  " + partOfSpeech] + [definition].compactMap { $0 } + examples).joined(separator: "\n")
    }
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
    let lemma: String?
    let rows: [Row]
    var senses: [DictionarySense] = []
    var hasContent: Bool { !rows.isEmpty || !senses.isEmpty }

    init(entries: [DictionaryEntry], target: Language? = nil, formNote: String? = nil, lemma: String? = nil) {
        self.formNote = formNote
        self.lemma = lemma
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
        let translations = ([formNote].compactMap { $0 } + rows.map(\.plainText)).joined(separator: "\n")
        let details = senses.isEmpty ? "" : "Open English WordNet\n"
            + senses.map(\.plainText).joined(separator: "\n\n")
        return [translations, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
    private let wordNetURL: URL?
    private var database: OpaquePointer?
    private var wordNetDatabase: OpaquePointer?

    init(url: URL, wordNetURL: URL? = nil) {
        self.url = url
        self.wordNetURL = wordNetURL
    }

    deinit {
        if let database { sqlite3_close(database) }
        if let wordNetDatabase { sqlite3_close(wordNetDatabase) }
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func search(_ text: String, direction: Direction, settings: DictionarySettings = .init()) -> DictionaryResult {
        let includesTranslations = settings.includes(direction)
        let includesDetails = settings.useWordNet && (settings.showDefinitions || settings.showExamples)
        let exact = includesTranslations ? lookup(text, direction: direction) : []
        let inflection = exact.isEmpty && direction == Self.englishToChinese
            && (includesTranslations || includesDetails) ? englishInflection(text) : nil
        var result = (includesTranslations ? inflection : nil) ?? DictionaryResult(entries: exact, target: direction.target)
        if includesDetails {
            let words: [String]
            if direction.source == .english {
                words = [inflection?.lemma ?? lookupKey(text)]
            } else if direction.target == .english {
                words = Array(result.rows.prefix(3).map(\.meaning))
            } else {
                words = []
            }
            for word in words where result.senses.count < 4 {
                let remaining = 4 - result.senses.count
                let limit = words.count == 1 ? remaining : min(2, remaining)
                result.senses += readWordNet(word, settings: settings, limit: limit)
            }
        }
        return result
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
                return DictionaryResult(entries: entries, target: .chinese, formNote: "\(suggestion)\n原形 \(lemma)", lemma: lemma)
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
                                    formNote: "拼写更正 · \(auxiliary) \(knownForms.participle)\n原形 \(lemma)", lemma: lemma)
        }
        let presentation = auxiliary.isEmpty ? "原形 \(lemma)" : "被动形式 \(auxiliary) \(form) · 原形 \(lemma)"
        let forms: String
        if let knownForms {
            forms = "\n过去式 \(knownForms.past) · 过去分词 \(knownForms.participle)"
        } else {
            forms = participle ? "\n过去式 / 过去分词 \(form)" : ""
        }
        return DictionaryResult(entries: entries, target: .chinese, formNote: presentation + forms, lemma: lemma)
    }

    func lookup(_ text: String, direction: Direction) -> [DictionaryEntry] {
        guard direction.hasLocalDictionary else { return [] }
        let key = lookupKey(text)
        guard !key.isEmpty, key.count <= 80 else { return [] }
        if database == nil { database = Self.open(url) }
        guard let database else { return [] }
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

    private func lookupKey(_ text: String) -> String {
        let sentencePunctuation = CharacterSet(charactersIn: "。！？!?").union(.whitespaces)
        return Self.normalize(text).trimmingCharacters(in: sentencePunctuation)
    }

    private func readWordNet(_ word: String, settings: DictionarySettings, limit: Int) -> [DictionarySense] {
        let key = Self.normalize(word).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !key.isEmpty, key.count <= 80, let wordNetURL else { return [] }
        if wordNetDatabase == nil { wordNetDatabase = Self.open(wordNetURL) }
        guard let wordNetDatabase else { return [] }
        let sql = """
            SELECT senses.part, senses.definition, senses.examples
            FROM words JOIN senses ON words.sense = senses.id
            WHERE words.word = ? AND (? OR senses.examples != '')
            ORDER BY words.position LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(wordNetDatabase, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_int(statement, 2, settings.showDefinitions ? 1 : 0)
        sqlite3_bind_int(statement, 3, Int32(limit))
        var results: [DictionarySense] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let part = String(cString: sqlite3_column_text(statement, 0))
            let definition = settings.showDefinitions ? String(cString: sqlite3_column_text(statement, 1)) : nil
            let examples = settings.showExamples ? String(cString: sqlite3_column_text(statement, 2))
                .split(separator: "\n").map(String.init) : []
            results.append(DictionarySense(word: key, partOfSpeech: part, definition: definition, examples: examples))
        }
        return results
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        if let opened { sqlite3_exec(opened, "PRAGMA cache_size=-512", nil, nil, nil) }
        return opened
    }
}
