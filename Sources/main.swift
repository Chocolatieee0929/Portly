import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let reopenNotification = Notification.Name("com.chocolatieee.portly.reopen")
    private var statusItem: NSStatusItem!
    private let store = TunnelStore()
    private var detailWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenRequested(_:)),
            name: Self.reopenNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        for tunnel in store.tunnels { menu.addItem(tunnel.makeMenuItem()) }
        menu.addItem(.separator())
        let detail = NSMenuItem(title: "Open", action: #selector(showDetails), keyEquivalent: ",")
        detail.target = self
        menu.addItem(detail)
        let quit = NSMenuItem(title: "Exit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        store.onChange = { [weak self] in self?.updateStatus() }
        updateStatus()
        showDetails()
    }

    private func configureMainMenu() {
        // Status-item shortcuts are only handled while that menu is tracking.
        // Install a regular application menu for shortcuts while a window has focus.
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Portly")
        let quit = NSMenuItem(title: "Quit Portly", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func updateStatus() {
        if let image = NSImage(systemSymbolName: "network", accessibilityDescription: "Portly SSH 隧道") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "SSH" }
        statusItem.button?.toolTip = store.tunnels.map {
            "\($0.name)：\($0.displayStatus)"
        }.joined(separator: "\n")
    }

    @objc private func showDetails() {
        if detailWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Portly"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 520, height: 420)
            window.contentView = NSHostingView(rootView: DetailsView(store: store))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            detailWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDetails()
        return true
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func reopenRequested(_ notification: Notification) { showDetails() }
    func applicationWillTerminate(_ notification: Notification) { store.stopAll() }
}

let app = NSApplication.shared
let instance: SingleInstance
do {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
    instance = try SingleInstance(directory: support.appendingPathComponent("com.chocolatieee.portly"))
} catch {
    let alert = NSAlert()
    alert.messageText = "无法启动 Portly"
    alert.informativeText = "无法检查运行中的实例，请检查应用支持目录的访问权限。"
    alert.runModal()
    exit(1)
}
if !instance.isPrimary {
    // Retry briefly so a simultaneous first launch has time to register its observer.
    for _ in 0..<5 {
        DistributedNotificationCenter.default().postNotificationName(AppDelegate.reopenNotification,
            object: nil, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.15)
    }
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.chocolatieee.portly")
        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
        .activate(options: [.activateIgnoringOtherApps])
    // Exit before creating the store: a duplicate must never clean up the primary's tunnels.
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
