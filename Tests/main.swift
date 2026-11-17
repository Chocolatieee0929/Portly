import Foundation
func wait(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(predicate(), "Timed out")
}
let executable = CommandLine.arguments[1]
func tunnel(_ host: String) -> Tunnel { Tunnel(name: host, host: host, port: 17890, executable: executable) }
let first = tunnel("healthy"), second = tunnel("healthy")
first.start(); first.start(); second.start()
wait { first.state == .connected && second.state == .connected }
first.stop()
precondition(first.state == .disconnected && second.state == .connected)
first.start()
wait { first.state == .connected }
first.stop(); second.stop()
for host in ["denied", "occupied", "dropped"] {
    let item = tunnel(host)
    item.start()
    wait { if case .failed = item.state { return true }; return false }
    if case let .failed(reason) = item.state {
        let expected = ["denied": "Permission denied", "occupied": "Address already in use", "dropped": "Connection reset"]
        precondition(reason.contains(expected[host]!))
    }
    precondition(!item.switchIsOn)
    if host != "occupied" { precondition(!item.desired) }
    item.stop()
}
let cancelled = tunnel("healthy")
cancelled.start(); cancelled.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(cancelled.state == .disconnected)
print("PASS: independent sessions, duplicate start, restart, startup errors, remote disconnect, cancellation")

// Classify actionable startup and drop errors; do not mistake generic bind/forward errors for occupancy.
let reasons: [(String, TunnelFailure.Kind)] = [
    ("ssh: Could not resolve hostname aws-proxy: nodename nor servname provided, or not known", .configuration),
    ("ssh: Could not resolve hostname local-proxy: Name or service not known", .configuration),
    ("/Users/test/.ssh/config: line 2: Bad configuration option: HostNam", .configuration),
    ("/Users/test/.ssh/config line 3: Missing argument.", .configuration),
    ("Bad owner or permissions on /Users/test/.ssh/config", .configuration),
    ("Warning: Identity file /missing/key not accessible: No such file or directory.\nPermission denied (publickey).", .configuration),
    ("Load key \"/key\": invalid format\nPermission denied (publickey).", .configuration),
    ("WARNING: UNPROTECTED PRIVATE KEY FILE!\nPermission denied (publickey).", .configuration),
    ("/Users/test/.ssh/config line 4: Bad port 'abc'.", .configuration),
    ("Permission denied (publickey).", .authentication),
    ("connect to host host port 22: Connection refused", .refused),
    ("No route to host", .unreachable),
    ("Could not resolve hostname missing: nodename nor servname provided", .dns),
    ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .hostKeyChanged),
    ("bind [127.0.0.1]:17890: Address already in use", .portInUse),
    ("bind [127.0.0.1]:17890: Permission denied", .other),
    ("Could not request local forwarding.", .other),
    ("Connection reset by peer", .disconnected),
]
for (message, kind) in reasons { precondition(TunnelFailure.classify(message).kind == kind) }

let unconfigured = Tunnel(name: "Missing configuration", host: "unconfigured", port: 17890, executable: executable, retryInterval: 0.05)
unconfigured.start()
wait { unconfigured.failure != nil }
precondition(unconfigured.failure?.kind == .configuration && !unconfigured.switchIsOn && !unconfigured.waitingForPort)
precondition(unconfigured.failure!.advice.contains("~/.ssh/config") && unconfigured.failure!.diagnostic.contains("aws-proxy"))
unconfigured.stop()

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let release = scratch.appendingPathComponent("released")
let blocked = Tunnel(name: "Waiting", host: "release:\(release.path)", port: 17890, executable: executable, retryInterval: 0.2)
blocked.start()
wait { blocked.waitingForPort }
let originalFailure = blocked.failure
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(blocked.failure == originalFailure && blocked.desired)
FileManager.default.createFile(atPath: release.path, contents: nil)
wait { blocked.state == .connected }
precondition(blocked.failure == nil && !blocked.waitingForPort)
blocked.stop()

// Errors remain visible through a manual retry, until the session actually answers.
let authenticated = scratch.appendingPathComponent("authenticated")
let auth = Tunnel(name: "Auth", host: "auth:\(authenticated.path)", port: 17890, executable: executable)
auth.start()
wait { auth.failure != nil }
precondition(auth.failure?.kind == .authentication && !auth.waitingForPort && !auth.desired && !auth.switchIsOn)
let authError = auth.failure
FileManager.default.createFile(atPath: authenticated.path, contents: nil)
auth.start()
precondition(auth.failure == authError)
wait { auth.state == .connected }
precondition(auth.failure == nil)
auth.stop()

let cancelRetry = Tunnel(name: "Cancel", host: "occupied", port: 17890, executable: executable, retryInterval: 0.05)
cancelRetry.start()
wait { cancelRetry.waitingForPort }
cancelRetry.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(cancelRetry.state == .disconnected && cancelRetry.failure == nil && !cancelRetry.desired && !cancelRetry.occupiesPort)

// A second managed connection must wait rather than compete with the first process.
let owner = tunnel("healthy")
let follower = Tunnel(name: "Second", host: "healthy", port: 17890, executable: executable, retryInterval: 0.05)
follower.portOwner = { owner.occupiesPort ? owner.name : nil }
owner.start(); follower.start()
precondition(follower.failure?.kind == .portInUse && !follower.occupiesPort)
owner.stop()
wait { follower.state == .connected }
follower.stop()

precondition(TunnelStore.portError("17890", "17890") != nil)
precondition(TunnelStore.portError("0", "17891") != nil)
precondition(TunnelStore.portError("65536", "17891") != nil)
precondition(TunnelStore.portError("bad", "17891") != nil)
precondition(TunnelStore.portError("17890", "17891") == nil)
let suite = "PortlyTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = TunnelStore(defaults: defaults)
precondition(!store.savePorts("19000", "19000"))
precondition(store.savePorts("19000", "19001"))
let restored = TunnelStore(defaults: defaults)
precondition(restored.tunnels[0].port == 19000 && restored.tunnels[1].port == 19001)
precondition(restored.tunnels[0].remotePort == 17890 && restored.tunnels[1].remotePort == 17891)
print("PASS: error classification and persistence, port release recovery, retry cancellation, conflict reservation, port validation and persistence")

let askpass = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("fake-askpass").path
let interactive = Tunnel(name: "Interactive", host: "askpass-check", port: 17890, executable: executable, askpassPath: askpass)
interactive.start()
wait { interactive.state == .connected }
interactive.stop()
precondition(TunnelFailure.classify("Permission denied (keyboard-interactive).").advice.contains("验证码"))
print("PASS: interactive SSH arguments and askpass pipe integration (synthetic credentials only)")

let matching = PortListener(pid: 123, command: "ssh", arguments: ["ssh", "-NT", "-L", "127.0.0.1:17891:127.0.0.1:17891", "local-proxy"])
precondition(matching.matches(host: "local-proxy", port: 17891, remotePort: 17891))
precondition(!matching.matches(host: "aws-proxy", port: 17891, remotePort: 17891))
precondition(!matching.matches(host: "local-proxy", port: 17891, remotePort: 17890))
let attached = PortListener(pid: 123, command: "ssh", arguments: ["ssh", "-NT", "-L17891:127.0.0.1:17891", "local-proxy"])
precondition(attached.matches(host: "local-proxy", port: 17891, remotePort: 17891))
let unknown = PortListener(pid: 123, command: "ssh", arguments: nil)
precondition(!unknown.matches(host: "local-proxy", port: 17891, remotePort: 17891))

final class ListenerFixture {
    private let lock = NSLock()
    private var value: PortListener?
    init(_ value: PortListener?) { self.value = value }
    func read() -> PortListener? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: PortListener?) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

// Stopping observation must not send any signal to the external process.
let outside = Process()
outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
outside.arguments = ["30"]
try! outside.run()
defer { if outside.isRunning { outside.terminate(); outside.waitUntilExit() } }
let existing = PortListener(pid: outside.processIdentifier, command: "ssh", arguments: matching.arguments)
let listener = ListenerFixture(existing)
let observer = Tunnel(name: "External", host: "local-proxy", port: 17891, executable: executable, retryInterval: 0.05,
                      listenerInspector: { _ in listener.read() })
observer.start()
wait { observer.state == .external }
precondition(observer.isConnected && observer.failure == nil && !observer.occupiesPort)
observer.stop()
precondition(outside.isRunning && observer.state == .disconnected)

listener.set(unknown)
observer.start()
wait { observer.state == .external }
precondition(!observer.isConnected && observer.failure == nil && !observer.externalMatches)
listener.set(nil)
wait { observer.state == .connected }
observer.stop()
precondition(outside.isRunning)

let occupiedByService = ListenerFixture(PortListener(pid: 123, command: "python3", arguments: nil))
let service = Tunnel(name: "Service", host: "healthy", port: 17891, executable: executable, retryInterval: 0.05,
                     listenerInspector: { _ in occupiedByService.read() })
service.start()
wait { service.failure?.kind == .portInUse }
precondition(service.externalListener == nil && !service.occupiesPort)
occupiedByService.set(nil)
wait { service.state == .connected }
service.stop()

let stoppedInspection = Tunnel(name: "Cancelled", host: "local-proxy", port: 17891, executable: executable,
                              listenerInspector: { _ in Thread.sleep(forTimeInterval: 0.05); return matching })
stoppedInspection.start(); stoppedInspection.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(stoppedInspection.state == .disconnected && stoppedInspection.externalListener == nil)
print("PASS: exact external forwarding match, unverified SSH listener, no external process termination, observation-to-owned recovery, non-SSH conflict, cancelled inspection")
let remoteCommand = PortListener(pid: 123, command: "ssh", arguments: ["ssh", "-N", "-L", "17891:127.0.0.1:17891", "wrong-server", "local-proxy"])
precondition(!remoteCommand.matches(host: "local-proxy", port: 17891, remotePort: 17891))
let bundledFlags = PortListener(pid: 123, command: "ssh", arguments: ["ssh", "-NTL", "17891:127.0.0.1:17891", "-o", "BatchMode=yes", "local-proxy"])
precondition(bundledFlags.matches(host: "local-proxy", port: 17891, remotePort: 17891))

// Exactly two automatic retries after the initial attempt; failed switches are always off.
final class AttemptCounter {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let attemptCounter = AttemptCounter()
let exhausted = Tunnel(name: "Bounded retries", host: "healthy", port: 17890, executable: executable, retryInterval: 0.03,
                       listenerInspector: { _ in
    attemptCounter.record()
    return PortListener(pid: 123, command: "python3", arguments: nil)
})
exhausted.start()
wait { exhausted.failure != nil }
precondition(!exhausted.switchIsOn)
wait { !exhausted.desired }
precondition(exhausted.retryCount == 2 && attemptCounter.read() == 3 && !exhausted.waitingForPort)
precondition(exhausted.failure != nil && !exhausted.switchIsOn)
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(attemptCounter.read() == 3)
// A deliberate user retry receives a fresh, independently bounded budget.
exhausted.start()
wait { !exhausted.desired }
precondition(attemptCounter.read() == 6 && exhausted.retryCount == 2)
exhausted.stop()
precondition(exhausted.failure == nil && exhausted.retryCount == 0 && !exhausted.switchIsOn)

let refused = tunnel("denied")
refused.start()
wait { refused.failure != nil }
precondition(!refused.desired && !refused.switchIsOn && refused.retryCount == 0)
let retained = refused.failure
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(refused.failure == retained)
refused.stop()
print("PASS: failed switches off, two-retry limit, no retries after exhaustion, manual retry budget reset, retained error until cleared")

// Existing connections use the same status and disconnect path; unknown listeners are untouched.
let adopted = Process()
adopted.executableURL = URL(fileURLWithPath: "/bin/sleep")
adopted.arguments = ["30"]
try! adopted.run()
defer { if adopted.isRunning { adopted.terminate(); adopted.waitUntilExit() } }
let adoptedListener = PortListener(pid: adopted.processIdentifier, command: "ssh", arguments: matching.arguments)
var terminationRequests = 0
let unified = Tunnel(name: "Unified", host: "local-proxy", port: 17891, executable: executable,
    listenerInspector: { _ in adoptedListener },
    listenerTerminator: { listener, host, port, remote in
        precondition(listener.pid == adopted.processIdentifier && host == "local-proxy" && port == 17891 && remote == 17891)
        terminationRequests += 1
        adopted.terminate()
    })
unified.start()
wait { unified.isConnected }
precondition(unified.displayStatus == "connected")
unified.stop()
wait { !adopted.isRunning }
precondition(terminationRequests == 1 && unified.state == .disconnected)
let quitting = Tunnel(name: "Quit", host: "local-proxy", port: 17891, executable: executable,
    listenerInspector: { _ in matching }, listenerTerminator: { _, _, _, _ in terminationRequests += 1 })
quitting.start()
quitting.stop(closeExisting: true)
precondition(terminationRequests == 2 && !quitting.desired)
let uncertain = Tunnel(name: "Unknown", host: "local-proxy", port: 17891, executable: executable,
    listenerInspector: { _ in unknown }, listenerTerminator: { _, _, _, _ in preconditionFailure("Unverified listener must not be terminated") })
uncertain.stop(closeExisting: true)
print("PASS: unified connected status, closing matched connections, quit during preflight, preserving unverified listeners")
