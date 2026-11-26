import AppKit

@MainActor
final class ProviderPreferences: NSObject, NSTextFieldDelegate {
    private enum KeyStorage: Int {
        case keychain, session, remove
    }

    private let endpoint = NSTextField()
    private let model = NSComboBox()
    private let key = NSSecureTextField()
    private let keyStorage = NSPopUpButton()
    private let modelList = NSButton(title: "获取模型", target: nil, action: nil)
    private var directoryTask: Task<Void, Never>?
    private var pendingLookup: UUID?

    func show() {
        let defaults = UserDefaults.standard
        endpoint.stringValue = defaults.string(forKey: ProviderSettings.endpointKey) ?? ""
        model.stringValue = defaults.string(forKey: ProviderSettings.modelKey) ?? ""
        endpoint.placeholderString = "https://你的服务/v1"
        model.placeholderString = "服务商提供的模型 ID"
        key.placeholderString = "留空保留已保存的 Key"
        endpoint.setAccessibilityLabel("Base URL")
        model.setAccessibilityLabel("模型 ID")
        key.setAccessibilityLabel("API Key")
        endpoint.delegate = self
        key.delegate = self
        keyStorage.addItems(withTitles: ["保存到钥匙串", "仅本次运行使用", "清除已保存的 Key"])
        keyStorage.setAccessibilityLabel("API Key 保存方式")
        keyStorage.target = self
        keyStorage.action = #selector(changeKeyStorage)

        modelList.target = self
        modelList.action = #selector(fetchModels)
        modelList.toolTip = "从当前 Base URL 获取可用模型"
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modelRow = NSStackView(views: [model, modelList])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Base URL"), endpoint],
            [NSTextField(labelWithString: "模型 ID"), modelRow],
            [NSTextField(labelWithString: "API Key"), key],
            [NSTextField(labelWithString: "保存方式"), keyStorage]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 8
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 300
        form.column(at: 1).xPlacement = .fill

        let alert = NSAlert()
        alert.messageText = "翻译接口"
        alert.informativeText = "可导入 LocalAiMux 的完整 JSON。API Key 可保存到钥匙串，也可仅在本次运行使用。"
        alert.accessoryView = form
        form.frame.size = form.fittingSize
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "导入 LocalAiMux JSON")
        alert.window.initialFirstResponder = endpoint

        while true {
            let response = alert.runModal()
            directoryTask?.cancel()
            directoryTask = nil
            setLoadingModels(false)
            if response == .alertThirdButtonReturn {
                do {
                    let config = try LocalAiMuxConfiguration.parse(NSPasteboard.general.string(forType: .string))
                    endpoint.stringValue = config.baseURL
                    model.stringValue = config.model
                    if storage == .remove { keyStorage.selectItem(at: KeyStorage.keychain.rawValue) }
                    key.isEnabled = true
                    key.stringValue = config.apiKey
                    model.removeAllItems()
                } catch {
                    NSAlert(error: error).runModal()
                }
                continue
            }
            guard response == .alertFirstButtonReturn else { return }
            do {
                let address = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelName = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = storage == .remove ? "" : typedKey
                let provider = !address.isEmpty || !modelName.isEmpty || !secret.isEmpty
                    ? try ProviderSettings(baseURL: address, model: modelName, apiKey: secret)
                    : nil
                switch storage {
                case .keychain:
                    if !secret.isEmpty { try APIKeyStore.save(secret, endpoint: provider?.endpoint) }
                case .session:
                    guard let provider, !secret.isEmpty else { throw TranslationError.sessionKeyRequired }
                    APIKeyStore.useForSession(secret, endpoint: provider.endpoint)
                case .remove:
                    try APIKeyStore.save("", endpoint: nil)
                }
                APIKeyStore.preserveKeyEndpoint()
                defaults.set(address.isEmpty ? nil : address, forKey: ProviderSettings.endpointKey)
                defaults.set(modelName.isEmpty ? nil : modelName, forKey: ProviderSettings.modelKey)
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func currentModelRequest(allowInteraction: Bool) throws -> URLRequest {
        try ProviderSettings.modelsRequest(baseURL: endpoint.stringValue,
                                                   apiKey: modelDirectoryKey(allowInteraction: allowInteraction))
    }

    private func modelDirectoryKey(allowInteraction: Bool) throws -> String {
        if storage == .remove { return "" }
        if !typedKey.isEmpty { return typedKey }
        if storage == .session { throw TranslationError.sessionKeyRequired }
        let url = try ProviderSettings.chatEndpoint(baseURL: endpoint.stringValue)
        return try APIKeyStore.read(for: url, allowInteraction: allowInteraction)
    }

    private var typedKey: String { key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var storage: KeyStorage { KeyStorage(rawValue: keyStorage.indexOfSelectedItem) ?? .keychain }

    @objc private func changeKeyStorage() {
        key.isEnabled = storage != .remove
        key.placeholderString = storage == .session ? "填写本次运行使用的 Key" : "留空保留已保存的 Key"
        resetModelList()
    }

    @objc private func fetchModels() {
        let request: URLRequest
        do {
            request = try currentModelRequest(allowInteraction: true)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        setLoadingModels(true)
        let id = UUID()
        pendingLookup = id
        directoryTask = Task.detached { [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await TranslationClient.loadModels(request))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            // The settings alert is running in AppKit's modal event loop.
            RunLoop.main.perform(inModes: [.modalPanel, .default]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.presentModels(result, for: request, lookupID: id)
                }
            }
        }
    }

    private func setLoadingModels(_ loading: Bool) {
        modelList.title = loading ? "获取中…" : "获取模型"
        modelList.isEnabled = !loading
        if !loading { pendingLookup = nil }
    }

    func controlTextDidChange(_ notification: Notification) {
        resetModelList()
    }

    private func resetModelList() {
        directoryTask?.cancel()
        directoryTask = nil
        setLoadingModels(false)
        model.removeAllItems()
    }

    private func presentModels(_ result: Result<[String], Error>, for request: URLRequest, lookupID: UUID) {
        guard pendingLookup == lookupID else { return }
        directoryTask = nil
        setLoadingModels(false)
        guard modelList.window?.isVisible == true, let current = try? currentModelRequest(allowInteraction: false),
              current.url == request.url,
              current.value(forHTTPHeaderField: "Authorization") == request.value(forHTTPHeaderField: "Authorization")
        else { return }

        switch result {
        case .failure(let error):
            NSAlert(error: error).runModal()
        case .success(let ids):
            model.removeAllItems()
            model.addItems(withObjectValues: ids)
            model.numberOfVisibleItems = min(ids.count, 10)
            modelList.title = "刷新模型"
        }
    }
}

@MainActor
final class LanguagePreferences: NSObject {
    private let primary = NSPopUpButton()
    private let secondary = NSPopUpButton()
    private let liveTranslation = NSButton(checkboxWithTitle: "输入时实时翻译", target: nil, action: nil)

    init(settings: LanguageSettings) {
        super.init()
        primary.setAccessibilityLabel("主语言")
        secondary.setAccessibilityLabel("默认第二语言")
        primary.addItems(withTitles: Language.allCases.map(\.name))
        primary.selectItem(at: Language.allCases.firstIndex(of: settings.primary) ?? 0)
        primary.target = self
        primary.action = #selector(refreshSecondary)
        fillSecondary(selected: settings.defaultSecond)
        liveTranslation.state = settings.liveTranslation ? .on : .off
    }

    func show() -> LanguageSettings? {
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "主语言"), primary],
            [NSTextField(labelWithString: "默认第二语言"), secondary],
            [NSView(), liveTranslation]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 8
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 180
        form.column(at: 1).xPlacement = .fill
        form.frame.size = form.fittingSize

        let alert = NSAlert()
        alert.messageText = "语言设置"
        alert.informativeText = "自动模式优先译成主语言，主语言原文译成默认第二语言。手动指定目标语后，闲置五分钟恢复自动。"
        alert.accessoryView = form
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, let secondaryLanguage else { return nil }
        return LanguageSettings(primary: primaryLanguage, defaultSecond: secondaryLanguage,
                                liveTranslation: liveTranslation.state == .on)
    }

    private var primaryLanguage: Language {
        Language.allCases[primary.indexOfSelectedItem]
    }

    private var secondaryLanguage: Language? {
        (secondary.selectedItem?.representedObject as? String).flatMap(Language.init(rawValue:))
    }

    @objc private func refreshSecondary() {
        fillSecondary(selected: secondaryLanguage ?? .english)
    }

    private func fillSecondary(selected: Language) {
        let settings = LanguageSettings(primary: primaryLanguage, defaultSecond: selected)
        secondary.removeAllItems()
        for choice in Language.allCases where choice != settings.primary {
            secondary.addItem(withTitle: choice.name)
            secondary.lastItem?.representedObject = choice.rawValue
        }
        secondary.selectItem(withTitle: settings.defaultSecond.name)
    }
}

@MainActor
enum DictionaryPreferences {
    static func show(_ settings: DictionarySettings) -> DictionarySettings? {
        let cedict = checkbox("CC-CEDICT 中英词库", checked: settings.useCEDICT)
        let tomoshi = checkbox("Tomoshi 中日词库", checked: settings.useTomoshi)
        let wordNet = checkbox("Open English WordNet 英语词库", checked: settings.useWordNet)
        let definitions = checkbox("显示详细释义", checked: settings.showDefinitions)
        let examples = checkbox("显示例句", checked: settings.showExamples)

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "词库"), cedict],
            [NSView(), tomoshi],
            [NSView(), wordNet],
            [NSTextField(labelWithString: "结果显示"), definitions],
            [NSView(), examples]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 8
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading
        form.frame.size = form.fittingSize

        let alert = NSAlert()
        alert.messageText = "词库与显示"
        alert.informativeText = "英语详细释义和例句来自 WordNet。"
        alert.accessoryView = form
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        return DictionarySettings(
            useCEDICT: cedict.state == .on,
            useTomoshi: tomoshi.state == .on,
            useWordNet: wordNet.state == .on,
            showDefinitions: definitions.state == .on,
            showExamples: examples.state == .on
        )
    }

    private static func checkbox(_ title: String, checked: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = checked ? .on : .off
        return button
    }
}
