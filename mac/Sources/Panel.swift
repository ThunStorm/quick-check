import AppKit
import OSLog
import QuartzCore

private final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

private final class QueryTextView: NSTextView {
    private(set) var isPasting = false
    private var updatingMarkedText = false
    var onCompositionChange: (() -> Void)?
    var isComposing: Bool { updatingMarkedText || hasMarkedText() }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        updatingMarkedText = true
        onCompositionChange?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatingMarkedText = false
        onCompositionChange?()
    }

    override func unmarkText() {
        let wasComposing = isComposing
        super.unmarkText()
        if wasComposing { onCompositionChange?() }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = isComposing
        super.insertText(insertString, replacementRange: replacementRange)
        if wasComposing { onCompositionChange?() }
    }

    override func paste(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        let previous = isPasting
        isPasting = true
        defer { isPasting = previous }
        super.pasteAsPlainText(sender)
    }
}

@MainActor
final class PanelController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private enum TranslationEngine {
        case local, ai
    }

    private let logger = Logger(subsystem: "com.thunstorm.quickcheck", category: "MenuBar")
    private let width: CGFloat = 390
    private let padding: CGFloat = 16
    private let cornerRadius: CGFloat = 22
    private let shadowMargin: CGFloat = 18
    private let panel = LookupPanel(
        contentRect: NSRect(x: 0, y: 0, width: 390, height: 62),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private let windowSurface = NSView()
    private let outlineShadow = CALayer()
    private let shadowMask = CAShapeLayer()
    private let materialContainer = NSView()
    private let surface = NSView()
    private let inputScroll = NSScrollView()
    private let input = QueryTextView()
    private let placeholder = NSTextField(labelWithString: "输入单词或粘贴一段文字")
    private let language = NSPopUpButton(frame: .zero, pullsDown: true)
    private let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!,
                                    target: nil, action: nil)
    private let divider = NSBox()
    private let resultScroll = NSScrollView()
    private let result = NSTextView()
    private let info = NSTextField(labelWithString: "")
    private let directionLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let aiButton = NSButton(title: "AI 翻译", target: nil, action: nil)
    private let toneMenu = NSPopUpButton()
    private let footer = NSStackView()
    private let sourceCount = NSTextField(labelWithString: "")
    private let resultCount = NSTextField(labelWithString: "")

    private let dictionary: LocalDictionary
    private weak var statusButton: NSStatusBarButton?
    private var monitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var session = LookupSession(settings: LanguageSettings.load())
    private var direction: Direction?
    private var dictionaryResult = DictionaryResult(entries: [])
    private var dictionarySettings = DictionarySettings.load()
    private var lastQueriedText = ""
    private var output: String?
    private var outputEngine: TranslationEngine?
    private var displayedTone = Tone.original
    private var pendingEngine: TranslationEngine?
    private var failedTone: Tone?
    private var errorMessage: String?
    private var request: Task<Void, Never>?
    private var localTranslationHost: NSView?
    private var presentingSystemUI = false
    private var generation = 0
    private var anchorToStatusItem = false

    init(statusButton: NSStatusBarButton?, dictionary: LocalDictionary) {
        self.statusButton = statusButton
        self.dictionary = dictionary
        super.init()
        setup()
    }

    private var source: String { input.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    func show(anchoredToStatusItem: Bool = false) {
        let wasVisible = panel.isVisible
        if !wasVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        anchorToStatusItem = anchoredToStatusItem
        if session.touch() { refreshQuery() }
        updateSurface()
        render()
        if !anchoredToStatusItem { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        if anchoredToStatusItem {
            logger.notice("Search panel ordered front (visible: \(self.panel.isVisible), key: \(self.panel.isKeyWindow))")
        }
        if !wasVisible {
            input.setSelectedRange(NSRange(location: 0, length: (input.string as NSString).length))
            installMonitors()
        }
    }

    private func dismiss(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        if pendingEngine == .local { cancelTranslation() }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        panel.orderOut(nil)
        if restoreFocus, previousApp?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp?.activate()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !presentingSystemUI else { return }
        if anchorToStatusItem && panel.isVisible {
            logger.notice("Search panel resigned key")
        }
        dismiss(restoreFocus: false)
    }

    private func installMonitors() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if let self, !self.presentingSystemUI, event.window !== self.statusButton?.window {
                let insidePanel = event.window === self.panel
                    && self.materialContainer.frame.contains(event.locationInWindow)
                if !insidePanel { self.dismiss(restoreFocus: false) }
            }
            return event
        }
        if let monitor { monitors.append(monitor) }
    }

    private func setup() {
        panel.delegate = self
        panel.escape = { [weak self] in self?.dismiss(restoreFocus: true) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.title = "Quick Check"

        windowSurface.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: panel.frame.size)
        windowSurface.wantsLayer = true
        outlineShadow.shadowColor = NSColor.black.cgColor
        outlineShadow.shadowOpacity = 0.23
        outlineShadow.shadowRadius = 6
        outlineShadow.shadowOffset = CGSize(width: 0, height: -3)
        shadowMask.fillRule = .evenOdd
        outlineShadow.mask = shadowMask
        windowSurface.layer?.addSublayer(outlineShadow)

        materialContainer.frame = windowSurface.bounds
        materialContainer.wantsLayer = true
        materialContainer.layer?.cornerRadius = cornerRadius
        materialContainer.layer?.masksToBounds = true
        materialContainer.layer?.borderWidth = 0.75
        windowSurface.addSubview(materialContainer)
        panel.contentView = windowSurface
        updateSurface()
        prepareText(input, scroll: inputScroll, editable: true, font: .systemFont(ofSize: 15))
        prepareText(result, scroll: resultScroll, editable: false, font: .systemFont(ofSize: 14))
        input.delegate = self
        input.onCompositionChange = { [weak self] in self?.compositionChanged() }
        input.setAccessibilityLabel("查询文本")
        result.setAccessibilityLabel("查询结果")
        placeholder.textColor = .placeholderTextColor
        placeholder.font = input.font

        language.controlSize = .small
        installLanguageMenu()
        settings.target = self
        settings.action = #selector(showMenu(_:))
        settings.isBordered = false
        settings.toolTip = "设置与退出"
        divider.boxType = .separator

        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        directionLabel.textColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        retryButton.target = self
        retryButton.action = #selector(retry)
        aiButton.target = self
        aiButton.action = #selector(translateWithAI)
        aiButton.toolTip = "用已配置的 AI 接口重新翻译原文"
        toneMenu.target = self
        toneMenu.action = #selector(changeTone)
        toneMenu.setAccessibilityLabel("语气")
        toneMenu.addItems(withTitles: Tone.allCases.map(\.rawValue))
        toneMenu.controlSize = .small
        for button in [retryButton, copyButton, aiButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        aiButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        [directionLabel, info, retryButton, toneMenu, copyButton, aiButton].forEach(footer.addArrangedSubview)
        for label in [sourceCount, resultCount] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "字符数，不含空白"
        }
        [language, settings, inputScroll, placeholder, divider, resultScroll, footer, sourceCount, resultCount].forEach(surface.addSubview)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateSurface), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func updateSurface() {
        let frame = materialContainer.bounds
        let material: NSView
        surface.removeFromSuperview()
        surface.frame = frame
        surface.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: surface.frame)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.addSubview(surface)
            material = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: surface.frame)
            glass.cornerRadius = cornerRadius
            glass.contentView = surface
            material = glass
        } else {
            let effect = NSVisualEffectView(frame: surface.frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(surface)
            material = effect
        }
        material.autoresizingMask = [.width, .height]
        materialContainer.subviews = [material]
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            materialContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        if panel.isVisible { panel.makeFirstResponder(input) }
    }

    private func prepareText(_ text: NSTextView, scroll: NSScrollView, editable: Bool, font: NSFont) {
        text.isEditable = editable
        text.isRichText = false
        text.drawsBackground = false
        text.font = font
        text.textColor = .labelColor
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        guard !input.isComposing else { return }
        session.touch()
        refreshQuery()
        if input.isPasting, !input.hasMarkedText() { submitLocalQuery(allowDownload: false) }
    }

    private func compositionChanged() {
        updatePlaceholder()
        guard !input.isComposing, source != lastQueriedText else { return }
        session.touch()
        refreshQuery()
    }

    private func updatePlaceholder() {
        placeholder.isHidden = input.isComposing || !input.string.isEmpty
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !input.isComposing {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else if !source.isEmpty {
                if session.touch() { refreshQuery() }
                submitLocalQuery(allowDownload: true)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !input.isComposing {
            dismiss(restoreFocus: true)
            return true
        }
        return false
    }

    private func installLanguageMenu() {
        language.removeAllItems()
        language.addItem(withTitle: "自")
        let automatic = language.menu?.addItem(
            withTitle: "自动（优先\(session.settings.primary.name)）", action: #selector(changeLanguage(_:)), keyEquivalent: ""
        )
        automatic?.target = self
        automatic?.representedObject = ""
        language.menu?.addItem(.separator())
        for choice in Language.allCases {
            let item = language.menu?.addItem(withTitle: choice.name, action: #selector(changeLanguage(_:)),
                                              keyEquivalent: "")
            item?.target = self
            item?.representedObject = choice.rawValue
        }
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        let target = Language(rawValue: code)
        guard target != session.selectedTarget else { return }
        session.select(target)
        refreshQuery()
        panel.makeFirstResponder(input)
        submitLocalQuery(allowDownload: false)
    }

    private func submitLocalQuery(allowDownload: Bool) {
        guard let direction, !direction.isAlreadyInTarget, !source.isEmpty, !input.isComposing,
              dictionaryResult.rows.isEmpty, pendingEngine == nil else { return }
        guard source.count <= ProviderSettings.maxLength else {
            errorMessage = "最多可翻译 \(ProviderSettings.maxLength) 字符。"
            render()
            return
        }
        let translation = LocalTranslation(text: source, direction: direction)
        let current = generation
        pendingEngine = .local
        failedTone = nil
        errorMessage = nil
        render()
        request = Task { [weak self] in
            do {
                let status = try await translation.status()
                try Task.checkCancellation()
                guard let self, current == self.generation else { return }
                switch status {
                case .unsupported:
                    throw LocalTranslationError.unsupported
                case .supported:
                    guard allowDownload else { throw LocalTranslationError.downloadRequired }
                    self.hostLocalTranslation(translation, generation: current, mayPresentUI: true)
                case .installed:
                    if #available(macOS 26.0, *), let source = translation.source {
                        let result = try await translation.translateInstalled(from: source)
                        self.finishLocalTranslation(.success(result), generation: current)
                    } else {
                        self.hostLocalTranslation(translation, generation: current, mayPresentUI: translation.source == nil)
                    }
                @unknown default:
                    throw LocalTranslationError.unavailable
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLocalTranslation(.failure(error), generation: current)
            }
        }
    }

    private func hostLocalTranslation(_ translation: LocalTranslation, generation: Int, mayPresentUI: Bool) {
        presentingSystemUI = mayPresentUI
        if mayPresentUI { NSApp.activate() }
        let host = translation.host { [weak self] result in
            self?.finishLocalTranslation(result, generation: generation)
        }
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        localTranslationHost = host
        surface.addSubview(host)
    }

    private func finishLocalTranslation(_ result: Result<String, Error>, generation: Int) {
        guard generation == self.generation, pendingEngine == .local else { return }
        request = nil
        pendingEngine = nil
        presentingSystemUI = false
        localTranslationHost?.removeFromSuperview()
        localTranslationHost = nil
        switch result {
        case .success(let text):
            output = text
            outputEngine = .local
            displayedTone = .original
        case .failure(let error):
            errorMessage = (error as? LocalTranslationError)?.localizedDescription
                ?? LocalTranslationError.unavailable.localizedDescription
        }
        render()
    }

    private func cancelTranslation() {
        generation += 1
        request?.cancel()
        request = nil
        pendingEngine = nil
        presentingSystemUI = false
        localTranslationHost?.removeFromSuperview()
        localTranslationHost = nil
    }

    private func refreshQuery() {
        cancelTranslation()
        failedTone = nil
        errorMessage = nil
        output = nil
        outputEngine = nil
        displayedTone = .original
        let text = source
        lastQueriedText = text
        if text.isEmpty {
            direction = nil
            dictionaryResult = DictionaryResult(entries: [])
        } else {
            let currentDirection = session.direction(for: text, dictionary: dictionary)
            direction = currentDirection
            dictionaryResult = dictionary.search(text, direction: currentDirection, settings: dictionarySettings)
            if currentDirection.isAlreadyInTarget { output = text }
        }
        render()
    }

    @objc private func changeTone() {
        let index = toneMenu.indexOfSelectedItem
        guard Tone.allCases.indices.contains(index) else { return }
        let tone = Tone.allCases[index]
        guard tone != displayedTone || failedTone != nil else { return }
        generate(tone)
    }

    @objc private func retry() { generate(failedTone ?? .original) }

    @objc private func translateWithAI() { generate(.original) }

    @objc private func copyResult() {
        let text = output ?? dictionaryResult.plainText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        info.stringValue = "已复制"
        info.toolTip = "已复制"
    }

    private func generate(_ tone: Tone) {
        guard let direction, !direction.isAlreadyInTarget, !source.isEmpty, pendingEngine == nil else { return }
        let text = source
        guard text.count <= ProviderSettings.maxLength else {
            errorMessage = "最多可翻译 \(ProviderSettings.maxLength) 字符。"
            render()
            return
        }
        let defaults = UserDefaults.standard
        guard let endpoint = defaults.string(forKey: ProviderSettings.endpointKey),
              let model = defaults.string(forKey: ProviderSettings.modelKey) else {
            errorMessage = TranslationError.notConfigured.localizedDescription
            render()
            return
        }
        let provider: ProviderSettings
        do {
            let url = try ProviderSettings.chatEndpoint(baseURL: endpoint)
            presentingSystemUI = true
            defer { presentingSystemUI = false }
            provider = try ProviderSettings(baseURL: endpoint, model: model,
                                            apiKey: APIKeyStore.read(for: url, allowInteraction: true))
        } catch {
            errorMessage = error.localizedDescription
            render()
            return
        }

        let input = TranslationInput(source: text, direction: direction, tone: tone)
        let current = generation
        pendingEngine = .ai
        failedTone = nil
        errorMessage = nil
        render()
        request = Task { [weak self] in
            do {
                let translated = try await TranslationClient.translate(input, using: provider)
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.output = translated
                self.outputEngine = .ai
                self.displayedTone = tone
            } catch {
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.failedTone = tone
                if (error as? URLError)?.code == .timedOut {
                    self.errorMessage = "翻译超时，请重试。"
                } else {
                    self.errorMessage = (error as? TranslationError)?.localizedDescription ?? "连接失败，请检查网络或接口地址。"
                }
            }
            guard let self, current == self.generation else { return }
            self.request = nil
            self.pendingEngine = nil
            self.render()
        }
    }

    private func render() {
        let target = session.selectedTarget
        let alreadyInTarget = direction?.isAlreadyInTarget == true
        language.item(at: 0)?.title = target?.label ?? "自"
        language.setAccessibilityLabel("目标语言（\(target?.name ?? "自动")）")
        language.toolTip = target.map { "目标语言 \($0.name)" } ?? "自动识别语言，可指定目标语言"
        for item in language.itemArray {
            item.state = (item.representedObject as? String) == (target?.rawValue ?? "") ? .on : .off
        }
        updatePlaceholder()
        directionLabel.stringValue = direction?.label ?? ""
        directionLabel.isHidden = direction == nil
        retryButton.isHidden = failedTone == nil || pendingEngine != nil
        aiButton.isHidden = direction == nil || alreadyInTarget
        aiButton.isEnabled = pendingEngine == nil
        copyButton.isHidden = output == nil && !dictionaryResult.hasContent
        toneMenu.isHidden = outputEngine != .ai || alreadyInTarget
        toneMenu.isEnabled = pendingEngine == nil
        toneMenu.selectItem(at: Tone.allCases.firstIndex(of: displayedTone) ?? 0)
        if let errorMessage {
            info.stringValue = errorMessage
        } else if let pendingEngine {
            info.stringValue = pendingEngine == .local ? "本地翻译中…" : "AI 翻译中…"
        } else if alreadyInTarget {
            info.stringValue = "已是目标语"
        } else if let outputEngine {
            info.stringValue = outputEngine == .local ? "本地翻译" : "AI 译文"
        } else {
            info.stringValue = dictionaryResult.rows.isEmpty ? "↵ 本地翻译" : "本地词典"
        }
        let translated = output ?? (dictionaryResult.rows.isEmpty ? nil : dictionaryResult.rows.map(\.meaning).joined(separator: "\n"))
        sourceCount.stringValue = "原文 \(characterCount(source))"
        resultCount.stringValue = "译文 \(translated.map(characterCount) ?? "—")"
        info.toolTip = info.stringValue
        info.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed

        let content = NSMutableAttributedString()
        if let output {
            content.append(NSAttributedString(string: output, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor
            ]))
        } else {
            if let note = dictionaryResult.formNote {
                content.append(NSAttributedString(string: note + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            for (index, row) in dictionaryResult.rows.enumerated() {
                if index > 0 { content.append(NSAttributedString(string: "\n")) }
                content.append(NSAttributedString(string: row.meaning, attributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor
                ]))
                if !row.partsOfSpeech.isEmpty {
                    content.append(NSAttributedString(string: "  " + row.partsOfSpeech.joined(separator: "、"), attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        }
        if !dictionaryResult.senses.isEmpty {
            let secondary: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
            ]
            let explanation: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
            ]
            if content.length > 0 { content.append(NSAttributedString(string: "\n\n")) }
            content.append(NSAttributedString(string: "Open English WordNet", attributes: secondary))
            for sense in dictionaryResult.senses {
                content.append(NSAttributedString(string: "\n\n\(sense.word)  \(sense.partOfSpeech)", attributes: secondary))
                if let definition = sense.definition {
                    content.append(NSAttributedString(string: "\n" + definition, attributes: explanation))
                }
                for example in sense.examples {
                    content.append(NSAttributedString(string: "\n“" + example + "”", attributes: secondary))
                }
            }
        }
        let resultChanged = result.textStorage?.isEqual(to: content) == false
        if resultChanged { result.textStorage?.setAttributedString(content) }
        layout(resultContent: content)
        if resultChanged { result.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }

    private func layout(resultContent: NSAttributedString) {
        let languageWidth: CGFloat = (session.selectedTarget?.label.count ?? 1) > 1 ? 66 : 44
        let inputX = 18 + languageWidth
        let inputWidth = width - inputX - 46
        let contentWidth = width - padding * 2
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let inputBounds = (input.string + " ").boundingRect(
            with: NSSize(width: inputWidth, height: 100), options: options,
            attributes: [.font: input.font ?? NSFont.systemFont(ofSize: 15)]
        )
        let inputHeight = max(24, min(94, ceil(inputBounds.height) + 6))
        let resultBounds = resultContent.boundingRect(with: NSSize(width: contentWidth, height: 400), options: options)
        let resultHeight = resultContent.length > 0 ? min(236, ceil(resultBounds.height) + 8) : 0
        let expanded = !source.isEmpty
        let inputTop: CGFloat = 14
        let extraHeight: CGFloat = expanded ? 37 + (resultHeight > 0 ? resultHeight + 6 : 0) : 0
        let height = inputTop + inputHeight + 14 + extraHeight
        let frameSize = NSSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)

        let statusWindow = anchorToStatusItem ? statusButton?.window : nil
        if let screen = statusWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let bounds = screen.visibleFrame
            // The status window already has its position in screen coordinates.
            let anchor = statusWindow.flatMap { window in
                screen.frame.intersects(window.frame) ? window.frame : nil
            }
            let centerX = anchor?.midX ?? bounds.midX
            let x = min(max(centerX - frameSize.width / 2, bounds.minX), bounds.maxX - frameSize.width)
            let top = anchor.map { min($0.minY, bounds.maxY) - 3 } ?? bounds.maxY - 64
            panel.setFrame(NSRect(x: x, y: top - height - shadowMargin,
                                  width: frameSize.width, height: frameSize.height), display: false)
        }
        layoutOutline(width: width, height: height)
        surface.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let rowY = height - inputTop - inputHeight
        language.frame = NSRect(x: 13, y: height - 39, width: languageWidth, height: 26)
        settings.frame = NSRect(x: width - 37, y: height - 37, width: 23, height: 22)
        inputScroll.frame = NSRect(x: inputX, y: rowY, width: inputWidth, height: inputHeight)
        inputScroll.hasVerticalScroller = inputHeight >= 94
        placeholder.frame = NSRect(x: inputX, y: height - 35, width: inputWidth, height: 20)
        divider.isHidden = !expanded
        divider.frame = NSRect(x: padding, y: rowY - 9, width: contentWidth, height: 1)
        resultScroll.isHidden = resultHeight == 0
        resultScroll.frame = NSRect(x: padding, y: 41, width: contentWidth, height: resultHeight)
        resultScroll.hasVerticalScroller = resultHeight >= 236
        footer.isHidden = !expanded
        let countWidth: CGFloat = 76
        footer.frame = NSRect(x: padding, y: 12, width: contentWidth - countWidth - 8, height: 24)
        let countX = width - padding - countWidth
        sourceCount.frame = NSRect(x: countX, y: 23, width: countWidth, height: 13)
        resultCount.frame = NSRect(x: countX, y: 10, width: countWidth, height: 13)
        sourceCount.isHidden = !expanded
        resultCount.isHidden = !expanded
    }

    private func characterCount(_ text: String) -> String {
        text.count(where: { !$0.isWhitespace }).formatted()
    }

    private func layoutOutline(width: CGFloat, height: CGFloat) {
        materialContainer.frame = NSRect(x: shadowMargin, y: shadowMargin, width: width, height: height)
        let roundedEdge = CGPath(roundedRect: materialContainer.frame, cornerWidth: cornerRadius,
                                 cornerHeight: cornerRadius, transform: nil)
        // Keep the shadow outside the glass so it cannot tint the translucent interior.
        let exterior = CGMutablePath()
        exterior.addRect(windowSurface.bounds)
        exterior.addPath(roundedEdge)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineShadow.frame = windowSurface.bounds
        outlineShadow.shadowPath = roundedEdge
        shadowMask.frame = outlineShadow.bounds
        shadowMask.path = exterior
        CATransaction.commit()
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let languages = menu.addItem(withTitle: "语言设置…", action: #selector(showLanguageSettings), keyEquivalent: "")
        languages.target = self
        let dictionaries = menu.addItem(withTitle: "词库与显示…", action: #selector(showDictionarySettings), keyEquivalent: "")
        dictionaries.target = self
        let preferences = menu.addItem(withTitle: "翻译接口…", action: #selector(showSettings), keyEquivalent: "")
        preferences.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Quick Check", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    @objc private func showSettings() {
        let anchored = anchorToStatusItem
        dismiss(restoreFocus: false)
        NSApp.activate()
        ProviderPreferences().show()
        show(anchoredToStatusItem: anchored)
    }

    @objc private func showDictionarySettings() {
        let anchored = anchorToStatusItem
        dismiss(restoreFocus: false)
        NSApp.activate()
        if let saved = DictionaryPreferences.show(dictionarySettings), saved != dictionarySettings {
            saved.save()
            dictionarySettings = saved
            refreshQuery()
        }
        show(anchoredToStatusItem: anchored)
    }

    @objc private func showLanguageSettings() {
        let anchored = anchorToStatusItem
        dismiss(restoreFocus: false)
        NSApp.activate()
        if let saved = LanguagePreferences(settings: session.settings).show(), saved != session.settings {
            saved.save()
            session = LookupSession(settings: saved)
            installLanguageMenu()
            refreshQuery()
        }
        show(anchoredToStatusItem: anchored)
    }
}
