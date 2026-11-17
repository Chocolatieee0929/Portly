import Foundation
import Combine

final class TunnelStore: ObservableObject {
    let tunnels: [Tunnel]
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func savedPort(_ key: String, fallback: Int) -> Int {
            let port = defaults.integer(forKey: key)
            return (1...65535).contains(port) ? port : fallback
        }
        tunnels = [
            Tunnel(name: "AWS Proxy", host: "aws-proxy", port: savedPort("awsLocalPort", fallback: 17890), remotePort: 17890),
            Tunnel(name: "Local Proxy", host: "local-proxy", port: savedPort("localLocalPort", fallback: 17891), remotePort: 17891),
        ]
        for tunnel in tunnels {
            tunnel.portOwner = { [weak self, weak tunnel] in
                guard let self, let tunnel else { return nil }
                return self.tunnels.first { $0 !== tunnel && $0.port == tunnel.port && $0.occupiesPort }?.name
            }
            tunnel.onChange = { [weak self] in
                self?.objectWillChange.send()
                self?.onChange?()
            }
        }
    }

    static func portError(_ first: String, _ second: String) -> String? {
        guard let a = Int(first), let b = Int(second), (1...65535).contains(a), (1...65535).contains(b) else {
            return "端口必须是 1–65535 的整数。"
        }
        return a == b ? "本地端口冲突：两个隧道不能使用同一端口。" : nil
    }

    @discardableResult func savePorts(_ first: String, _ second: String) -> Bool {
        guard Self.portError(first, second) == nil,
              !tunnels.contains(where: { $0.desired }), let a = Int(first), let b = Int(second) else { return false }
        tunnels[0].setPort(a)
        tunnels[1].setPort(b)
        defaults.set(a, forKey: "awsLocalPort")
        defaults.set(b, forKey: "localLocalPort")
        objectWillChange.send()
        return true
    }

    func stopAll() { tunnels.forEach { $0.stop(closeExisting: true) } }
}
