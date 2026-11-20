import AppKit

@MainActor
final class ProviderPreferences: NSObject, NSTextFieldDelegate {
    private let endpoint = NSTextField()
    private let model = NSComboBox()
    private let key = NSSecureTextField()
    private let modelList = NSButton(title: "获取模型", target: nil, action: nil)
    private var directoryTask: Task<Void, Never>?
    private var pendingLookup: UUID?

    func show() {
        let defaults = UserDefaults.standard
        endpoint.stringValue = defaults.string(forKey: ProviderSettings.endpointKey) ?? ""
        model.stringValue = defaults.string(forKey: ProviderSettings.modelKey) ?? ""
        endpoint.placeholderString = "https://你的服务/v1"
        model.placeholderString = "服务商提供的模型 ID"
        key.placeholderString = "留空则使用无密钥配置"
        endpoint.setAccessibilityLabel("Base URL")
        model.setAccessibilityLabel("模型 ID")
        key.setAccessibilityLabel("API Key")
        endpoint.delegate = self
        key.delegate = self
        do {
            key.stringValue = try APIKeyStore.read()
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        modelList.target = self
        modelList.action = #selector(fetchModels)
        modelList.toolTip = "获取本机 LocalAiMux 当前 Key 可用的模型"
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modelRow = NSStackView(views: [model, modelList])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Base URL"), endpoint],
            [NSTextField(labelWithString: "模型 ID"), modelRow],
            [NSTextField(labelWithString: "API Key"), key]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 8
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 300
        form.column(at: 1).xPlacement = .fill

        let alert = NSAlert()
        alert.messageText = "翻译接口"
        alert.informativeText = "填写兼容 Chat Completions 的接口，或导入 LocalAiMux 的完整 JSON。API Key 保存在钥匙串。"
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
                let secret = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty || !modelName.isEmpty || !secret.isEmpty {
                    _ = try ProviderSettings(baseURL: address, model: modelName, apiKey: secret)
                }
                try APIKeyStore.save(secret)
                defaults.set(address.isEmpty ? nil : address, forKey: ProviderSettings.endpointKey)
                defaults.set(modelName.isEmpty ? nil : modelName, forKey: ProviderSettings.modelKey)
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func currentModelRequest() throws -> URLRequest {
        try LocalAiMuxConfiguration.modelsRequest(baseURL: endpoint.stringValue, apiKey: key.stringValue)
    }

    @objc private func fetchModels() {
        let request: URLRequest
        do {
            request = try currentModelRequest()
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
                result = .success(try await TranslationClient.loadLocalAiMuxModels(request))
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
        directoryTask?.cancel()
        directoryTask = nil
        setLoadingModels(false)
        model.removeAllItems()
    }

    private func presentModels(_ result: Result<[String], Error>, for request: URLRequest, lookupID: UUID) {
        guard pendingLookup == lookupID else { return }
        directoryTask = nil
        setLoadingModels(false)
        guard modelList.window?.isVisible == true, let current = try? currentModelRequest(),
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

    init(settings: LanguageSettings) {
        super.init()
        primary.setAccessibilityLabel("主语言")
        secondary.setAccessibilityLabel("默认第二语言")
        primary.addItems(withTitles: Language.allCases.map(\.name))
        primary.selectItem(at: Language.allCases.firstIndex(of: settings.primary) ?? 0)
        primary.target = self
        primary.action = #selector(refreshSecondary)
        fillSecondary(selected: settings.defaultSecond)
    }

    func show() -> LanguageSettings? {
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "主语言"), primary],
            [NSTextField(labelWithString: "默认第二语言"), secondary]
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
        return LanguageSettings(primary: primaryLanguage, defaultSecond: secondaryLanguage)
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
