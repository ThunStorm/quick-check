import AppKit

@MainActor
private final class QuickCheckApp: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Quick Check")
            ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Quick Check")
        button.toolTip = "Quick Check"
        button.setAccessibilityLabel("Quick Check")
        button.action = #selector(toggle)
        button.target = self
        status = item
    }

    @objc private func toggle() {
        if controller == nil, let button = status?.button,
           let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") {
            controller = PanelController(statusButton: button, dictionary: LocalDictionary(url: url))
        }
        controller?.toggle()
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
