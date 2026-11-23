import AppKit
import OSLog

@MainActor
private final class QuickCheckApp: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.thunstorm.quickcheck", category: "MenuBar")
    private var status: NSStatusItem?
    private var controller: PanelController?
    private var pendingStatusSearch: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        installStatusItem()
        showSearch()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else { return }
        let symbol = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Quick Check")
            ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Quick Check")
        if let symbol {
            let image = symbol.withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? symbol
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "⌕"
        }
        button.toolTip = "Quick Check"
        button.setAccessibilityLabel("Quick Check")
        button.target = self
        button.action = #selector(statusButtonPressed)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        status = item
    }

    @objc private func statusButtonPressed() {
        logger.notice("Status button pressed")
        pendingStatusSearch?.cancel()
        pendingStatusSearch = Task { [weak self] in
            // Present after the status button finishes handling the click.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            repeat {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            } while NSEvent.pressedMouseButtons != 0 && clock.now < deadline
            self?.lookupController()?.show(anchoredToStatusItem: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSearch()
        return false
    }

    private func lookupController() -> PanelController? {
        if controller == nil, let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") {
            let wordNet = Bundle.main.url(forResource: "wordnet", withExtension: "sqlite3")
            controller = PanelController(statusButton: status?.button,
                                         dictionary: LocalDictionary(url: url, wordNetURL: wordNet))
        }
        return controller
    }

    private func showSearch() {
        DispatchQueue.main.async { [weak self] in
            self?.lookupController()?.show()
        }
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let editItem = mainMenu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = QuickCheckApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
