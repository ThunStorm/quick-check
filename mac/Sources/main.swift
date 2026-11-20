import AppKit

@MainActor
private final class QuickCheckApp: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let item = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = item.button else { return }
        let symbol = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Quick Check")
            ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Quick Check")
        if let image = symbol?.withSymbolConfiguration(.init(pointSize: 17, weight: .semibold)) {
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        } else {
            button.title = "QC"
        }
        button.toolTip = "Quick Check"
        button.setAccessibilityLabel("Quick Check")
        button.action = #selector(toggle(_:))
        button.target = self
        status = item
    }

    @objc private func toggle(_ button: NSStatusBarButton) {
        if controller == nil, let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") {
            controller = PanelController(statusButton: button, dictionary: LocalDictionary(url: url))
        }
        // Let AppKit finish tracking the status item before moving keyboard focus.
        DispatchQueue.main.async { [weak self] in
            self?.controller?.toggle()
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
