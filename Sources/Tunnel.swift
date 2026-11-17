import Cocoa
import Darwin
import Combine

/// SSH tunnel lifecycle, including verified existing sessions.
final class Tunnel: NSObject, ObservableObject {
    enum State: Equatable {
        case disconnected, connecting, connected, external, failed(String)
        var title: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .external: return "external"
            case .failed: return "failed"
            }
        }
    }

    let name: String
    let host: String
    let remotePort: Int
    @Published private(set) var port: Int
    @Published private(set) var state: State = .disconnected { didSet { updateMenu(); onChange?() } }
    @Published private(set) var failure: TunnelFailure?
    @Published private(set) var desired = false
    @Published private(set) var waitingForPort = false
    @Published private(set) var retryCount = 0
    static let maxRetries = 2
    // A failed attempt never leaves the connection switch enabled, even while a retry is pending.
    var switchIsOn: Bool { desired && failure == nil }
    var retryMessage: String? {
        if failure != nil && occupiesPort && retryCount > 0 { return "正在进行第 \(retryCount)/\(Self.maxRetries) 次重试" }
        if waitingForPort { return "3 秒后进行第 \(retryCount + 1)/\(Self.maxRetries) 次重试" }
        if failure != nil && retryCount >= Self.maxRetries { return "已重试 2 次，自动重试已停止。" }
        return nil
    }
    @Published private(set) var externalListener: PortListener?
    var externalMatches: Bool { externalListener?.matches(host: host, port: port, remotePort: remotePort) == true }
    var isConnected: Bool { state == .connected || (state == .external && externalMatches) }
    var displayStatus: String {
        if state == .external { return externalMatches ? "connected" : "waiting for confirmation" }
        return failure?.title ?? state.title
    }
    private var preflighting = false
    private let listenerInspector: (Int) -> PortListener?
    private let listenerTerminator: (PortListener, String, Int, Int) -> Void
    var onChange: (() -> Void)?
    var portOwner: (() -> String?)?
    var occupiesPort: Bool { process != nil || preflighting }
    private let retryInterval: TimeInterval
    private var retryTimer: Timer?
    private let executable: String
    private let askpassPath: String?
    private var item: NSMenuItem?
    private var process: Process?
    private var folder: URL?
    private var errorHandle: FileHandle?
    private var timer: Timer?
    private var checking = false
    private var generation = UUID()

    init(name: String, host: String, port: Int, remotePort: Int? = nil, executable: String = "/usr/bin/ssh", retryInterval: TimeInterval = 3,
         askpassPath: String? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PortlyAskpass").path,
         listenerInspector: ((Int) -> PortListener?)? = nil,
         listenerTerminator: @escaping (PortListener, String, Int, Int) -> Void = PortListener.terminate) {
        self.listenerTerminator = listenerTerminator
        self.name = name
        self.host = host
        self.port = port
        self.remotePort = remotePort ?? port
        self.executable = executable
        self.askpassPath = askpassPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        self.retryInterval = retryInterval
        self.listenerInspector = listenerInspector ?? (executable == "/usr/bin/ssh" ? { PortListener.inspect(port: $0) } : { _ in nil })
    }

    func makeMenuItem() -> NSMenuItem {
        if let item { return item }
        let item = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        item.target = self
        self.item = item
        updateMenu()
        return item
    }

    private func updateMenu() {
        guard let item else { return }
        item.title = name
        item.state = isConnected ? .on : .off
        let color: NSColor = failure != nil ? .systemRed : (desired ? (isConnected ? .systemGreen : .systemOrange) : .systemGray)
        let dot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        item.image = dot
        if let failure {
            let retry = retryMessage.map { "\n\($0)" } ?? ""
            item.toolTip = "\(failure.title)\n\(failure.advice)\(retry)\n\n\(failure.diagnostic)"
        } else {
            item.toolTip = "127.0.0.1:\(port) → \(host) → 127.0.0.1:\(remotePort)"
        }
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [
            .foregroundColor: failure != nil ? NSColor.systemRed : (desired ? NSColor.labelColor : NSColor.secondaryLabelColor),
            .font: NSFont.menuFont(ofSize: 0),
        ])
    }

    @objc private func toggle() { desired ? stop() : start() }

    func setPort(_ value: Int) {
        guard !desired, (1...65535).contains(value) else { return }
        port = value
        updateMenu()
    }

    func start() {
        guard !occupiesPort else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        desired = true
        launch()
    }

    private func launch() {
        guard desired, !occupiesPort else { return }
        waitingForPort = false
        if let owner = portOwner?() {
            fail(TunnelFailure(kind: .portInUse, diagnostic: "本地端口 \(port) 已由 \(owner) 的连接任务使用。"))
            return
        }
        generation = UUID()
        let token = generation
        preflighting = true
        if failure == nil && state != .external { state = .connecting }
        let inspect = listenerInspector
        let port = port
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listener = inspect(port)
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.desired else { return }
                self.preflighting = false
                if let listener {
                    if listener.isSSH {
                        self.externalListener = listener
                        // A listening external session is not a failed owned connection.
                        self.failure = nil
                        self.waitingForPort = false
                        self.retryCount = 0
                        self.state = .external
                        self.scheduleRetry()
                    } else {
                        self.externalListener = nil
                        self.fail(TunnelFailure(kind: .portInUse,
                            diagnostic: "本地端口 \(port) 已由 \(listener.command)（PID \(listener.pid)）监听，无法建立新的转发。"))
                    }
                    return
                }
                self.externalListener = nil
                self.spawn(token: token)
            }
        }
    }

    private func spawn(token: UUID) {
        guard desired, generation == token else { return }
        let task = Process()
        do {
            // Short 0700 directory isolates the control socket from existing SSH masters.
            var template = Array("/tmp/portly-ssh.XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let directory = URL(fileURLWithPath: String(cString: path))
            folder = directory
            let log = directory.appendingPathComponent("error")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            errorHandle = handle
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = ["-N", "-T", "-M", "-S", directory.appendingPathComponent("control").path,
                              "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
                              "-o", "BatchMode=\(askpassPath == nil ? "yes" : "no")",
                              "-o", "NumberOfPasswordPrompts=1", "-o", "ExitOnForwardFailure=yes",
                              "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1",
                              "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                              "-o", "RemoteCommand=none",
                              "-L", "127.0.0.1:\(port):127.0.0.1:\(remotePort)", host]
            if let askpassPath {
                var environment = ProcessInfo.processInfo.environment
                environment["SSH_ASKPASS"] = askpassPath
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["PORTLY_SSH_HOST"] = host
                environment["PORTLY_SSH_DIAGNOSTIC"] = log.path
                task.environment = environment
            }
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = handle
            task.terminationHandler = { [weak self] task in
                let diagnostic = (try? String(contentsOf: log, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = task.terminationStatus
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    let wasConnected = self.state == .connected
                    self.process = nil
                    self.cleanup()
                    let message = diagnostic.isEmpty ? "SSH 已退出（\(status)）" : String(diagnostic.suffix(8192))
                    self.fail(TunnelFailure.classify(message, wasConnected: wasConnected))
                }
            }
            process = task
            if failure == nil { state = .connecting }
            try task.run()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkSession() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            task.terminationHandler = nil
            process = nil
            cleanup()
            fail(TunnelFailure.classify(error.localizedDescription))
        }
    }

    private func checkSession() {
        guard !checking, let directory = folder, process?.isRunning == true else { return }
        checking = true
        let token = generation
        let executable = executable
        let host = host
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = ["-S", directory.appendingPathComponent("control").path, "-O", "check", host]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var success = false
            do {
                try task.run()
                let deadline = Date().addingTimeInterval(2)
                while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
                success = task.terminationStatus == 0
            } catch {}
            let connected = success
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.checking = false
                if connected, self.process?.isRunning == true {
                    self.failure = nil
                    self.waitingForPort = false
                    self.retryCount = 0
                    self.state = .connected
                }
            }
        }
    }

    private func fail(_ reason: TunnelFailure) {
        // Preserve the first failure while retrying. Clear it only after a real reconnect or stop.
        if failure == nil { failure = reason }
        waitingForPort = reason.kind == .portInUse && desired && retryCount < Self.maxRetries
        if !waitingForPort { desired = false }
        state = .failed(failure!.diagnostic)
        if waitingForPort { scheduleRetry(forFailure: true) }
    }

    private func scheduleRetry(forFailure: Bool = false) {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: retryInterval, repeats: false) { [weak self] _ in
            guard let self, self.desired else { return }
            self.retryTimer = nil
            if forFailure { self.retryCount += 1 }
            self.launch()
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop(closeExisting: Bool = false) {
        // On quit, also cover a listener discovered while preflight was still pending.
        let existing = externalListener ?? (closeExisting ? listenerInspector(port) : nil)
        desired = false
        retryTimer?.invalidate()
        retryTimer = nil
        generation = UUID()
        preflighting = false
        externalListener = nil
        if let existing, existing.matches(host: host, port: port, remotePort: remotePort),
           existing.pid != process?.processIdentifier {
            listenerTerminator(existing, host, port, remotePort)
        }
        if let task = process, task.isRunning {
            task.terminationHandler = nil
            task.terminate()
            let deadline = Date().addingTimeInterval(0.2)
            while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
        }
        process = nil
        cleanup()
        failure = nil
        waitingForPort = false
        retryCount = 0
        state = .disconnected
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        checking = false
        try? errorHandle?.close()
        errorHandle = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}
