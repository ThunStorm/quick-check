import AppKit

private final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

@MainActor
final class PanelController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let width: CGFloat = 390
    private let padding: CGFloat = 16
    private let panel = LookupPanel(
        contentRect: NSRect(x: 0, y: 0, width: 390, height: 62),
        styleMask: [.borderless], backing: .buffered, defer: true
    )
    private let surface = NSView()
    private let inputScroll = NSScrollView()
    private let input = NSTextView()
    private let placeholder = NSTextField(labelWithString: "输入单词或粘贴一段文字")
    private let language = NSPopUpButton()
    private let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!,
                                    target: nil, action: nil)
    private let divider = NSBox()
    private let resultScroll = NSScrollView()
    private let result = NSTextView()
    private let info = NSTextField(labelWithString: "")
    private let directionButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let toneMenu = NSPopUpButton()
    private let footer = NSStackView()

    private let dictionary: LocalDictionary
    private weak var statusButton: NSStatusBarButton?
    private var monitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var session = LookupSession()
    private var direction: Direction?
    private var ambiguous = false
    private var entries: [DictionaryEntry] = []
    private var output: String?
    private var displayedTone = Tone.original
    private var pendingTone: Tone?
    private var failedTone: Tone?
    private var errorMessage: String?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var anchorToStatusItem = false

    init(statusButton: NSStatusBarButton?, dictionary: LocalDictionary) {
        self.statusButton = statusButton
        self.dictionary = dictionary
        super.init()
        setup()
    }

    private var source: String { input.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggle() {
        if panel.isVisible { dismiss(restoreFocus: true) } else { show(anchoredToStatusItem: true) }
    }

    func show(anchoredToStatusItem: Bool = false) {
        let wasVisible = panel.isVisible
        if !wasVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        anchorToStatusItem = anchoredToStatusItem
        if session.touch() { refreshQuery() }
        updateSurface()
        render()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        if !wasVisible {
            input.setSelectedRange(NSRange(location: 0, length: (input.string as NSString).length))
            installMonitors()
        }
    }

    private func dismiss(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        panel.orderOut(nil)
        if restoreFocus, previousApp?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp?.activate()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(restoreFocus: false)
    }

    private func installMonitors() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if let self, event.window !== self.panel && event.window !== self.statusButton?.window {
                self.dismiss(restoreFocus: false)
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
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.title = "Quick Check"

        updateSurface()
        prepareText(input, scroll: inputScroll, editable: true, font: .systemFont(ofSize: 15))
        prepareText(result, scroll: resultScroll, editable: false, font: .systemFont(ofSize: 14))
        input.delegate = self
        input.setAccessibilityLabel("查询文本")
        result.setAccessibilityLabel("查询结果")
        placeholder.textColor = .placeholderTextColor
        placeholder.font = input.font

        language.addItems(withTitles: ["英", "日"])
        language.setAccessibilityLabel("第二语言")
        language.target = self
        language.action = #selector(changeLanguage)
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
        directionButton.target = self
        directionButton.action = #selector(reverseDirection)
        directionButton.toolTip = "反转本次翻译方向"
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        retryButton.target = self
        retryButton.action = #selector(retry)
        toneMenu.target = self
        toneMenu.action = #selector(changeTone)
        toneMenu.setAccessibilityLabel("语气")
        toneMenu.addItems(withTitles: Tone.allCases.map(\.rawValue))
        toneMenu.controlSize = .small
        for button in [directionButton, retryButton, copyButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        [directionButton, info, retryButton, toneMenu, copyButton].forEach(footer.addArrangedSubview)
        [language, settings, inputScroll, placeholder, divider, resultScroll, footer].forEach(surface.addSubview)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateSurface), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func updateSurface() {
        let frame = panel.contentView?.bounds ?? panel.frame
        surface.removeFromSuperview()
        surface.frame = NSRect(origin: .zero, size: frame.size)
        surface.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: surface.frame)
            solid.wantsLayer = true
            solid.layer?.cornerRadius = 22
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.addSubview(surface)
            panel.contentView = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: surface.frame)
            glass.cornerRadius = 22
            glass.contentView = surface
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: surface.frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 22
            effect.layer?.masksToBounds = true
            effect.addSubview(surface)
            panel.contentView = effect
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
        session.touch()
        refreshQuery()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else if !source.isEmpty {
                if session.touch() { refreshQuery() }
                generate(.original)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            dismiss(restoreFocus: true)
            return true
        }
        return false
    }

    @objc private func changeLanguage() {
        session.select(language.indexOfSelectedItem == 1 ? .japanese : .english)
        refreshQuery()
        panel.makeFirstResponder(input)
    }

    @objc private func reverseDirection() {
        guard let direction else { return }
        let expired = session.touch()
        refreshQuery(override: expired ? nil : direction.reversed)
    }

    private func refreshQuery(override: Direction? = nil) {
        generation += 1
        request?.cancel()
        request = nil
        pendingTone = nil
        failedTone = nil
        errorMessage = nil
        output = nil
        displayedTone = .original
        let detected = session.direction(for: source, dictionary: dictionary)
        direction = source.isEmpty ? nil : (override ?? detected.0)
        ambiguous = detected.ambiguous && override == nil
        entries = direction.map { dictionary.lookup(source, direction: $0) } ?? []
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

    @objc private func copyResult() {
        let text = output ?? entries.map { "\($0.headword)  \($0.meaning)" }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        info.stringValue = "已复制"
        info.toolTip = "已复制"
    }

    private func generate(_ tone: Tone) {
        guard let direction, !source.isEmpty, pendingTone == nil else { return }
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
            provider = try ProviderSettings(baseURL: endpoint, model: model, apiKey: APIKeyStore.read())
        } catch {
            errorMessage = error.localizedDescription
            render()
            return
        }

        let input = TranslationInput(source: text, direction: direction, tone: tone)
        let current = generation
        pendingTone = tone
        failedTone = nil
        errorMessage = nil
        render()
        request = Task { [weak self] in
            do {
                let translated = try await TranslationClient.translate(input, using: provider)
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.output = translated
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
            self.pendingTone = nil
            self.render()
        }
    }

    private func render() {
        language.selectItem(at: session.second == .japanese ? 1 : 0)
        placeholder.isHidden = !input.string.isEmpty
        directionButton.title = (direction?.label ?? "") + (ambiguous ? " ▾" : "")
        directionButton.isHidden = direction == nil
        retryButton.isHidden = failedTone == nil || pendingTone != nil
        copyButton.isHidden = output == nil && entries.isEmpty
        toneMenu.isHidden = output == nil
        toneMenu.isEnabled = pendingTone == nil
        toneMenu.selectItem(at: Tone.allCases.firstIndex(of: pendingTone ?? displayedTone) ?? 0)
        info.stringValue = errorMessage ?? (pendingTone != nil ? "翻译中…" :
            (output != nil ? "" : (entries.isEmpty ? "↵ 翻译" : "本地词典")))
        info.toolTip = info.stringValue
        info.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed

        let content = NSMutableAttributedString()
        if let output {
            content.append(NSAttributedString(string: output, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor
            ]))
        } else {
            for (index, entry) in entries.enumerated() {
                if index > 0 { content.append(NSAttributedString(string: "\n\n")) }
                content.append(NSAttributedString(string: entry.headword, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor
                ]))
                if !entry.detail.isEmpty {
                    content.append(NSAttributedString(string: "  " + entry.detail, attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
                content.append(NSAttributedString(string: "\n" + entry.meaning, attributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor
                ]))
            }
        }
        let resultChanged = result.textStorage?.isEqual(to: content) == false
        if resultChanged { result.textStorage?.setAttributedString(content) }
        layout(resultContent: content)
        if resultChanged { result.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }

    private func layout(resultContent: NSAttributedString) {
        let inputWidth = width - 113
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

        let statusWindow = anchorToStatusItem ? statusButton?.window : nil
        if let screen = statusWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let bounds = screen.visibleFrame
            // The status window already has its position in screen coordinates.
            let anchor = statusWindow.flatMap { window in
                screen.frame.intersects(window.frame) ? window.frame : nil
            }
            let centerX = anchor?.midX ?? bounds.midX
            let x = min(max(centerX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
            let top = anchor.map { min($0.minY, bounds.maxY) - 3 } ?? bounds.maxY - 64
            panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        }
        surface.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let rowY = height - inputTop - inputHeight
        language.frame = NSRect(x: 13, y: height - 39, width: 49, height: 26)
        settings.frame = NSRect(x: width - 37, y: height - 37, width: 23, height: 22)
        inputScroll.frame = NSRect(x: 67, y: rowY, width: inputWidth, height: inputHeight)
        inputScroll.hasVerticalScroller = inputHeight >= 94
        placeholder.frame = NSRect(x: 67, y: height - 35, width: inputWidth, height: 20)
        divider.isHidden = !expanded
        divider.frame = NSRect(x: padding, y: rowY - 9, width: contentWidth, height: 1)
        resultScroll.isHidden = resultHeight == 0
        resultScroll.frame = NSRect(x: padding, y: 41, width: contentWidth, height: resultHeight)
        resultScroll.hasVerticalScroller = resultHeight >= 236
        footer.isHidden = !expanded
        footer.frame = NSRect(x: padding, y: 12, width: contentWidth, height: 24)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let preferences = menu.addItem(withTitle: "翻译设置…", action: #selector(showSettings), keyEquivalent: "")
        preferences.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Quick Check", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    @objc private func showSettings() {
        dismiss(restoreFocus: false)
        ProviderPreferences.show()
    }
}
