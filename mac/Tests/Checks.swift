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
        let en = Direction(source: .chinese, target: .english)
        let ja = Direction(source: .chinese, target: .japanese)

        try check(session.direction(for: "草稿", dictionary: dictionary).0 == en, "Chinese → English")
        try check(dictionary.lookup("草稿", direction: en).contains { $0.meaning.contains("draft") }, "Chinese gloss")
        try check(session.direction(for: "deadline", dictionary: dictionary).0 == en.reversed, "English → Chinese")
        try check(dictionary.lookup(" ＤＥＡＤＬＩＮＥ ", direction: en.reversed).first?.meaning.contains("截止") == true,
                  "English lookup normalizes width, case and whitespace")
        session.select(.japanese, at: now)
        try check(session.direction(for: "收据", dictionary: dictionary).0 == ja, "Chinese → Japanese")
        try check(dictionary.lookup("收据", direction: ja).first?.headword == "領収書", "Japanese headword")
        try check(session.direction(for: "領収書", dictionary: dictionary).0 == ja.reversed, "Japanese → Chinese")
        try check(dictionary.lookup("領収書", direction: ja.reversed).first?.meaning.contains("收据") == true,
                  "Japanese gloss")
        try check(session.direction(for: "てがみ", dictionary: dictionary).0 == ja.reversed, "Kana")
        try check(session.direction(for: "手紙", dictionary: dictionary).ambiguous, "Shared Han spelling")
        try check(!session.touch(at: now.addingTimeInterval(299)) && session.second == .japanese, "Recent language")
        try check(session.touch(at: now.addingTimeInterval(599)) && session.second == .english, "Idle language reset")
        try check(dictionary.lookup(String(repeating: "long ", count: 80), direction: en).isEmpty, "Long input")

        let suite = "com.thunstorm.quickcheck.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(LanguageSettings.load(from: defaults) == .init(), "Factory language defaults")
        let settings = LanguageSettings(primary: .french, defaultSecond: .korean)
        settings.save(to: defaults)
        try check(LanguageSettings.load(from: defaults) == settings, "Language settings round trip")
        try check(LanguageSettings(primary: .english).defaultSecond == .chinese, "Languages must be distinct")
        var multilingual = LookupSession(settings: settings)
        multilingual.select(.spanish, at: now)
        multilingual.select(.french, at: now)
        try check(multilingual.second == .spanish, "Temporary language cannot duplicate the primary")
        let frenchSpanish = Direction(source: .french, target: .spanish)
        try check(multilingual.direction(for: "Je voudrais réserver une table pour ce soir.", dictionary: dictionary).0
                  == frenchSpanish, "French to Spanish when both use Latin script")
        try check(multilingual.direction(for: "¿Dónde está la estación de tren más cercana?", dictionary: dictionary).0
                  == frenchSpanish.reversed, "Spanish to French when both use Latin script")
        try check(multilingual.touch(at: now.addingTimeInterval(300)) && multilingual.second == .korean,
                  "Idle reset restores the configured second language")
        let frenchKorean = Direction(source: .french, target: .korean)
        try check(multilingual.direction(for: "기차는 내일 아침에 출발합니다.", dictionary: dictionary).0
                  == frenchKorean.reversed, "Hangul detection with a non-Chinese primary")
        try check(!frenchKorean.hasLocalDictionary && dictionary.lookup("train", direction: frenchKorean).isEmpty,
                  "Unsupported local language pairs fall through to online translation")
        let englishChinese = LookupSession(settings: LanguageSettings(primary: .english, defaultSecond: .chinese))
        try check(englishChinese.direction(for: "草稿", dictionary: dictionary).0 == en,
                  "An English primary still supports Chinese-to-English dictionary lookup")

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
            TranslationInput(source: text, direction: en, tone: .original), using: provider
        )
        let formal = try await TranslationClient.translate(
            TranslationInput(source: text, direction: en, tone: .formal), using: provider
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
                    TranslationInput(source: text, direction: en, tone: .original), using: failure
                )
                throw CheckFailure(reason: "Expected provider failure for \(model)")
            } catch let error as TranslationError {
                try check(error.localizedDescription.contains(expected), "Provider failure for \(model)")
            }
        }
        print("PASS · offline dictionary, language detection and expiry, translation, tone, provider failures")
    }
}
