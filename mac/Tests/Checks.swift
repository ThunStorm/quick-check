import Foundation

private struct CheckFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() { throw CheckFailure(reason: description) }
}

@main
enum Checks {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let dictionary = LocalDictionary(url: URL(fileURLWithPath: arguments[1]))
        var session = LookupSession()
        let now = Date(timeIntervalSince1970: 100)
        let zhEn = Direction(source: .chinese, target: .english)
        let en = Direction(source: .english, target: .chinese)
        let ja = Direction(source: .japanese, target: .chinese)
        let zhJa = Direction(source: .chinese, target: .japanese)

        try check(session.direction(for: "草稿", dictionary: dictionary) == zhEn, "Chinese → English in automatic mode")
        try check(dictionary.lookup("草稿", direction: zhEn).contains { $0.meaning.contains("draft") }, "Chinese gloss")
        try check(session.direction(for: "deadline", dictionary: dictionary) == en, "English → Chinese in automatic mode")
        try check(dictionary.lookup(" ＤＥＡＤＬＩＮＥ ", direction: en).first?.meaning.contains("截止") == true,
                  "English lookup normalizes width, case and whitespace")
        try check(session.direction(for: "領収書", dictionary: dictionary) == ja, "Japanese Han spelling → Chinese")
        try check(dictionary.lookup("領収書", direction: ja).first?.meaning.contains("收据") == true, "Japanese gloss")
        try check(session.direction(for: "てがみ", dictionary: dictionary) == ja, "Kana in automatic mode")
        try check(session.direction(for: "love", dictionary: dictionary) == en, "Short English word → Chinese")
        let love = DictionaryResult(entries: dictionary.lookup("love", direction: en))
        try check(love.plainText == "名词  爱意、爱情、喜爱\n动词  爱、热爱、喜欢",
                  "Compact grouped, reviewed meanings for love")
        let possessive = session.direction(for: "我的。", dictionary: dictionary)
        try check(possessive == zhEn, "Possessive phrase gets the default second language")
        let mine = DictionaryResult(entries: dictionary.lookup("我的。", direction: possessive))
        try check(mine.plainText == "限定词  my\n代词  mine", "Possessive phrase has offline equivalents")
        let repeated = DictionaryResult(entries: [
            DictionaryEntry(headword: "宠", detail: "寵 · chong3", meaning: "宠"),
            DictionaryEntry(headword: "宠", detail: "chong3", meaning: "宠"),
            DictionaryEntry(headword: "起きる", detail: "", meaning: "动词  起床；起立\n动词  起床；醒来")
        ])
        try check(repeated.plainText == "宠\n动词  起床、起立、醒来", "Duplicate glosses, headers and parts of speech")

        session.select(.japanese, at: now)
        try check(session.direction(for: "收据", dictionary: dictionary) == zhJa, "Chinese → selected Japanese")
        try check(dictionary.lookup("收据", direction: zhJa).first?.headword == "領収書", "Japanese headword")
        try check(session.direction(for: "てがみ", dictionary: dictionary).isAlreadyInTarget,
                  "Selecting Japanese keeps Japanese as target even for Japanese input")
        try check(session.direction(for: "Where is the closest train station?", dictionary: dictionary)
                  == Direction(source: .english, target: .japanese), "English → selected Japanese without source constraint")
        try check(!session.touch(at: now.addingTimeInterval(299)) && session.selectedTarget == .japanese, "Recent target")
        try check(session.touch(at: now.addingTimeInterval(599)) && session.selectedTarget == nil, "Idle reset to automatic")
        try check(dictionary.lookup(String(repeating: "long ", count: 80), direction: zhEn).isEmpty, "Long input")

        let suite = "com.thunstorm.quickcheck.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(LanguageSettings.load(from: defaults) == .init(), "Factory language defaults")
        let settings = LanguageSettings(primary: .french, defaultSecond: .korean)
        settings.save(to: defaults)
        try check(LanguageSettings.load(from: defaults) == settings, "Language settings round trip")
        try check(LanguageSettings(primary: .english).defaultSecond == .chinese, "Languages must be distinct")
        var multilingual = LookupSession(settings: settings)
        let frenchKorean = Direction(source: .french, target: .korean)
        let frenchText = "Je voudrais réserver une table pour ce soir."
        let spanishText = "¿Dónde está la estación de tren más cercana?"
        try check(multilingual.direction(for: frenchText, dictionary: dictionary) == frenchKorean,
                  "Primary-language input uses the preferred second language")
        try check(multilingual.direction(for: spanishText, dictionary: dictionary) == Direction(source: .spanish, target: .french),
                  "An unselected foreign source is still detected")
        multilingual.select(.french, at: now)
        try check(multilingual.direction(for: frenchText, dictionary: dictionary).isAlreadyInTarget,
                  "The configured primary is also a valid explicit target")
        multilingual.select(.spanish, at: now)
        try check(multilingual.direction(for: frenchText, dictionary: dictionary) == Direction(source: .french, target: .spanish),
                  "French → selected Spanish")
        try check(multilingual.direction(for: spanishText, dictionary: dictionary).isAlreadyInTarget,
                  "The target stays Spanish even when the input is Spanish")
        try check(multilingual.touch(at: now.addingTimeInterval(300)) && multilingual.selectedTarget == nil,
                  "Idle reset restores automatic mode")
        try check(multilingual.direction(for: "기차는 내일 아침에 출발합니다.", dictionary: dictionary)
                  == Direction(source: .korean, target: .french), "Hangul detection with a non-Chinese primary")
        try check(!frenchKorean.hasLocalDictionary && dictionary.lookup("train", direction: frenchKorean).isEmpty,
                  "Unsupported local language pairs fall through to online translation")

        let copied = """
            {"baseURL":"http://127.0.0.1:8317/v1","apiKey":"lmx_test_example","model":"codex/sample-model"}
            """
        let mux = try LocalAiMuxConfiguration.parse(copied)
        let muxProvider = try ProviderSettings(baseURL: mux.baseURL, model: mux.model, apiKey: mux.apiKey)
        try check(muxProvider.endpoint.absoluteString == "http://127.0.0.1:8317/v1/chat/completions",
                  "LocalAiMux JSON base URL")
        try check(muxProvider.model == "codex/sample-model" && muxProvider.apiKey == "lmx_test_example",
                  "LocalAiMux exact model ID and key")
        let modelRequest = try LocalAiMuxConfiguration.modelsRequest(baseURL: mux.baseURL, apiKey: mux.apiKey)
        try check(modelRequest.url?.absoluteString == "http://127.0.0.1:8317/v1/models"
                  && modelRequest.httpMethod == "GET" && modelRequest.httpBody == nil
                  && modelRequest.value(forHTTPHeaderField: "Authorization") == "Bearer lmx_test_example",
                  "LocalAiMux directory request is read-only and authenticated")
        let fullEndpoint = try LocalAiMuxConfiguration.modelsRequest(
            baseURL: "http://127.0.0.1:8317/v1/chat/completions", apiKey: mux.apiKey
        )
        try check(fullEndpoint.url == modelRequest.url, "Directory URL from a full Chat Completions endpoint")
        let modelList = Data("""
            {"object":"list","data":[{"id":"qwen/model"},{"id":"codex/model"},{"id":"codex/model"},{"id":""}]}
            """.utf8)
        let modelIDs = try LocalAiMuxConfiguration.modelIDs(from: modelList)
        try check(modelIDs == ["codex/model", "qwen/model"], "Keep exact model IDs, sorted and unique")
        do {
            _ = try LocalAiMuxConfiguration.modelIDs(from: Data(#"{"data":[]}"#.utf8))
            throw CheckFailure(reason: "Accepted an empty model directory")
        } catch TranslationError.emptyModelDirectory {}
        let customPort = try LocalAiMuxConfiguration.parse(
            copied.replacingOccurrences(of: "127.0.0.1:8317", with: "localhost:18317")
        )
        try check(customPort.baseURL == "http://localhost:18317/v1", "LocalAiMux custom loopback port")
        do {
            _ = try LocalAiMuxConfiguration.parse(copied.replacingOccurrences(
                of: "lmx_test_example", with: "YOUR_LOCALAIMUX_KEY"
            ))
            throw CheckFailure(reason: "Imported a masked LocalAiMux preview")
        } catch TranslationError.incompleteLocalAiMuxKey {}
        for invalid in ["", copied.replacingOccurrences(of: "http://127.0.0.1:8317", with: "https://example.org")] {
            do {
                _ = try LocalAiMuxConfiguration.parse(invalid)
                throw CheckFailure(reason: "Accepted invalid LocalAiMux config")
            } catch TranslationError.invalidLocalAiMuxConfig {}
        }

        let offlineProvider = try ProviderSettings(baseURL: "http://127.0.0.1:1234/v1/", model: "mock", apiKey: "")
        try check(offlineProvider.endpoint.path == "/v1/chat/completions", "Endpoint normalization")
        for invalid in ["http://example.org/v1", "https://user@example.org/v1", "https://example.org/v1#fragment"] {
            do {
                _ = try ProviderSettings(baseURL: invalid, model: "mock", apiKey: "test-only")
                throw CheckFailure(reason: "Accepted invalid provider address")
            } catch TranslationError.invalidAddress {}
        }
        guard arguments.count > 2 else {
            print("PASS · offline dictionary, language settings, LocalAiMux configuration and model directory")
            return
        }
        let provider = try ProviderSettings(baseURL: arguments[2] + "/v1/", model: "mock", apiKey: "test-only")
        let text = "我这边都行，你定吧。"
        let original = try await TranslationClient.translate(
            TranslationInput(source: text, direction: zhEn, tone: .original), using: provider
        )
        let formal = try await TranslationClient.translate(
            TranslationInput(source: text, direction: zhEn, tone: .formal), using: provider
        )
        try check(original == "Whatever works for you." && formal == "Please choose whichever works best for you.",
                  "Translation and tone regeneration")
        let korean = try await TranslationClient.translate(
            TranslationInput(source: "Le train part demain matin.", direction: frenchKorean, tone: .original),
            using: provider
        )
        try check(korean == "기차는 내일 아침에 출발합니다.", "Translation with two configured non-Chinese languages")

        for (model, expected) in [("limit", "请求太频繁"), ("unauthorized", "服务拒绝"), ("empty", "可用的译文"),
                                  ("redirect", "HTTP 302")] {
            let failure = try ProviderSettings(baseURL: arguments[2] + "/v1", model: model, apiKey: "test-only")
            do {
                _ = try await TranslationClient.translate(
                    TranslationInput(source: text, direction: zhEn, tone: .original), using: failure
                )
                throw CheckFailure(reason: "Expected provider failure for \(model)")
            } catch let error as TranslationError {
                try check(error.localizedDescription.contains(expected), "Provider failure for \(model)")
            }
        }
        print("PASS · offline dictionary, language detection and expiry, translation, tone, provider failures")
    }
}
