import Cocoa
import Darwin

// Separate SSH_ASKPASS process. Replies go only to SSH's private pipe, never to logs or preferences.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let parent = getppid()
let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
    if getppid() != parent || kill(parent, 0) != 0 { exit(1) }
}
RunLoop.main.add(watchdog, forMode: .common)
RunLoop.main.add(watchdog, forMode: .modalPanel)

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let host = ProcessInfo.processInfo.environment["PORTLY_SSH_HOST"] ?? "SSH"
let alert = NSAlert()
alert.messageText = "\(host) · SSH 认证"
alert.informativeText = prompt
alert.alertStyle = .informational

func presentAuthenticationAlert() -> NSApplication.ModalResponse {
    let window = alert.window
    // The helper is a separate accessory app: activation alone does not keep
    // its prompt above other apps or make it visible in a full-screen Space.
    window.level = .modalPanel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hidesOnDeactivate = false
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    return alert.runModal()
}

let confirmingHost = prompt.lowercased().contains("are you sure you want to continue connecting")
if confirmingHost {
    // Keep OpenSSH's host fingerprint visible and require an explicit decision.
    alert.messageText = "\(host) · 确认服务器身份"
    let logPath = ProcessInfo.processInfo.environment["PORTLY_SSH_DIAGNOSTIC"] ?? ""
    let diagnostic = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    // OpenSSH emits the fingerprint to stderr before invoking askpass, not in the prompt.
    guard diagnostic.contains("fingerprint is") else {
        alert.informativeText = "无法展示服务器指纹，请先在终端连接此主机并核对服务器身份。"
        alert.addButton(withTitle: "取消")
        _ = presentAuthenticationAlert()
        exit(1)
    }
    alert.informativeText = String(diagnostic.suffix(4096)) + "\n\n" + prompt
    alert.addButton(withTitle: "确认连接")
    alert.addButton(withTitle: "取消")
    guard presentAuthenticationAlert() == .alertFirstButtonReturn else { exit(1) }
    FileHandle.standardOutput.write(Data("yes\n".utf8))
} else {
    let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
    input.placeholderString = "密码、密钥口令或验证码"
    alert.accessoryView = input
    alert.addButton(withTitle: "继续")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = input
    guard presentAuthenticationAlert() == .alertFirstButtonReturn else { exit(1) }
    var response = input.stringValue
    input.stringValue = ""
    FileHandle.standardOutput.write(Data((response + "\n").utf8))
    response = ""
}
watchdog.invalidate()
exit(0)
