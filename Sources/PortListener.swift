import Foundation
import Darwin

struct PortListener: Equatable {
    let pid: Int32
    let command: String
    let arguments: [String]?
    var isSSH: Bool { command == "ssh" }

    func matches(host: String, port: Int, remotePort: Int) -> Bool {
        guard isSSH, let arguments, !arguments.isEmpty else { return false }
        let expected = ["127.0.0.1:\(port):127.0.0.1:\(remotePort)", "\(port):127.0.0.1:\(remotePort)"]
        let valued = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let flags = Set("1246AaCfGgKkMNnqsTtVvXxYy")
        var index = 1
        var destination: String?
        var forwards: [String] = []
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                if index + 1 < arguments.count { destination = arguments[index + 1] }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" { destination = argument; break }
            let options = Array(argument.dropFirst())
            var optionIndex = 0
            while optionIndex < options.count {
                let option = options[optionIndex]
                if valued.contains(option) {
                    let value: String
                    if optionIndex + 1 < options.count {
                        value = String(options[(optionIndex + 1)...])
                    } else {
                        index += 1
                        guard index < arguments.count else { return false }
                        value = arguments[index]
                    }
                    if option == "L" { forwards.append(value) }
                    break
                }
                guard flags.contains(option) else { return false }
                optionIndex += 1
            }
            index += 1
        }
        return destination == host && forwards.contains(where: expected.contains)
    }

    /// Only inspect local listeners. Lack of process visibility never proves a port is free.
    static func inspect(port: Int) -> PortListener? {
        guard let output = run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]) else { return nil }
        var pid: Int32?
        var command = ""
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()); command = "" }
            if line.first == "c" { command = String(line.dropFirst()) }
            if line.first == "n", let pid,
               ["127.0.0.1:\(port)", "*:\(port)", "[::]:\(port)"].contains(String(line.dropFirst())) {
                return PortListener(pid: pid, command: command, arguments: processArguments(pid))
            }
        }
        return nil
    }

    /// Revalidate the listener immediately before signalling; never terminate by port alone.
    static func terminate(_ listener: PortListener, host: String, port: Int, remotePort: Int) {
        guard listener.pid > 1,
              let current = inspect(port: port), current == listener,
              current.matches(host: host, port: port, remotePort: remotePort) else { return }
        kill(current.pid, SIGTERM)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            // lsof output is bounded to listeners on one port, never whole process listings.
            let deadline = Date().addingTimeInterval(2)
            while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    private static func processArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0,
              length > 4, length <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return nil }
        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { target in
            bytes.withUnsafeBytes { memcpy(target.baseAddress!, $0.baseAddress!, 4) }
        }
        guard argc > 0 && argc < 4096 else { return nil }
        var offset = 4
        while offset < length && bytes[offset] != 0 { offset += 1 }
        while offset < length && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < length && bytes[offset] != 0 { offset += 1 }
            guard offset < length else { return nil }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        // Ignore the environment block and never display full argv; only match the forward.
        return arguments
    }
}
