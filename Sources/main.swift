import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let store = TunnelStore()
    private var detailWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
    func applicationWillTerminate(_ notification: Notification) { store.stopAll() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
