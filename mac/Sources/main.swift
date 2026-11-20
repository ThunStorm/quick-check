import AppKit
import OSLog

@MainActor
private final class QuickCheckApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(subsystem: "com.thunstorm.quickcheck", category: "MenuBar")
    private var status: NSStatusItem?
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        installStatusItem()
        showSearch()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = item.button else { return }
        let symbol = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Quick Check")
            ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Quick Check")
        if let symbol {
            symbol.isTemplate = true
            button.image = symbol
        } else {
            button.title = "⌕"
        }
        button.toolTip = "Quick Check"
        button.setAccessibilityLabel("Quick Check")

        let menu = NSMenu(title: "Quick Check")
        let search = menu.addItem(withTitle: "打开 Quick Check", action: #selector(openSearchFromMenu), keyEquivalent: "")
        search.target = self
        menu.delegate = self
        item.menu = menu
        status = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        logger.notice("System status menu opened")
        // Release native tracking before placing a key window under the status item.
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.status?.menu?.cancelTrackingWithoutAnimation()
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        logger.notice("System status menu closed")
        showSearch(anchoredToStatusItem: true)
    }

    @objc private func openSearchFromMenu() {
        showSearch(anchoredToStatusItem: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSearch()
        return false
    }

    private func lookupController() -> PanelController? {
        if controller == nil, let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") {
            controller = PanelController(statusButton: status?.button, dictionary: LocalDictionary(url: url))
        }
        return controller
    }

    private func showSearch(anchoredToStatusItem: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.lookupController()?.show(anchoredToStatusItem: anchoredToStatusItem)
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
