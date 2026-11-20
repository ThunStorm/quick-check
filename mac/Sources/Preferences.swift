import AppKit

@MainActor
enum ProviderPreferences {
    static func show() {
        let defaults = UserDefaults.standard
        let oldEndpoint = defaults.string(forKey: ProviderSettings.endpointKey) ?? ""
        let oldModel = defaults.string(forKey: ProviderSettings.modelKey) ?? ""
        let endpoint = NSTextField(string: oldEndpoint)
        let model = NSTextField(string: oldModel)
        let key = NSSecureTextField()
        endpoint.placeholderString = "https://你的服务/v1"
        model.placeholderString = "服务商提供的模型名称"
        key.placeholderString = "留空则使用无密钥配置"
        do {
            key.stringValue = try APIKeyStore.read()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }

        let rows = [
            [NSTextField(labelWithString: "接口地址"), endpoint],
            [NSTextField(labelWithString: "模型"), model],
            [NSTextField(labelWithString: "API Key"), key]
        ]
        let form = NSGridView(views: rows)
        form.columnSpacing = 12
        form.rowSpacing = 8
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 280
        form.column(at: 1).xPlacement = .fill

        let alert = NSAlert()
        alert.messageText = "翻译设置"
        alert.informativeText = "填写兼容 Chat Completions 的接口。在线翻译会将原文提交到此地址，API Key 保存在钥匙串。"
        alert.accessoryView = form
        form.frame.size = form.fittingSize
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = endpoint

        while alert.runModal() == .alertFirstButtonReturn {
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
}
