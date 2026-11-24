import AppKit
import SwiftUI
import Translation

enum LocalTranslationError: LocalizedError {
    case unsupported, downloadRequired, unavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "本地翻译不支持此语言组合。"
        case .downloadRequired: "首次使用需下载语包，按回车继续。"
        case .unavailable: "本地翻译未完成，可重按回车。"
        }
    }
}

struct LocalTranslation {
    let text: String
    let source: Locale.Language?
    let target: Locale.Language

    init(text: String, direction: Direction) {
        self.text = text
        source = direction.source.map(Self.language)
        target = Self.language(direction.target)
    }

    private static func language(_ language: Language) -> Locale.Language {
        Locale.Language(identifier: language == .chinese ? "zh-Hans" : language.rawValue)
    }

    func status() async throws -> LanguageAvailability.Status {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        if let source { return await availability.status(from: source, to: target) }
        return try await availability.status(for: text, to: target)
    }

    @available(macOS 26.0, *)
    func translateInstalled(from source: Locale.Language) async throws -> String {
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        return try await withTaskCancellationHandler {
            try await session.translate(text).targetText
        } onCancel: {
            session.cancel()
        }
    }

    @MainActor
    func host(completion: @escaping @MainActor (Result<String, Error>) -> Void) -> NSView {
        let configuration: TranslationSession.Configuration
        if #available(macOS 26.4, *) {
            configuration = .init(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            configuration = .init(source: source, target: target)
        }
        // Keep the SwiftUI host attached to the panel while the system presents download approval.
        return NSHostingView(rootView: Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    completion(.success(response.targetText))
                } catch {
                    completion(.failure(error))
                }
            })
    }
}
