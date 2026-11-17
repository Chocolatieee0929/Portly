import Foundation
import Darwin

if CommandLine.arguments.count == 3 {
    let gate = try SingleInstance(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    if CommandLine.arguments[1] == "--hold" {
        precondition(gate.isPrimary)
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        while true { pause() }
    }
    exit(gate.isPrimary ? 0 : 2)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("portly-instance-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
func probe() throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    task.arguments = ["--probe", directory.path]
    try task.run()
    task.waitUntilExit()
    return task.terminationStatus
}
var primary: SingleInstance? = try SingleInstance(directory: directory)
precondition(primary!.isPrimary)
precondition(try! probe() == 2, "Second process must not acquire the lock")
primary = nil
precondition(try! probe() == 0, "Normal exit must release the lock")

let crashed = Process()
let output = Pipe()
crashed.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
crashed.arguments = ["--hold", directory.path]
crashed.standardOutput = output
try crashed.run()
precondition(output.fileHandleForReading.availableData == Data("ready\n".utf8))
precondition(try! probe() == 2)
kill(crashed.processIdentifier, SIGKILL)
crashed.waitUntilExit()
precondition(try! probe() == 0, "A crash must not leave a stale lock")
print("PASS: single instance across processes, release on exit, recovery after crash")
