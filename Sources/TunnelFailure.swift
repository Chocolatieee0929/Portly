import Foundation

struct TunnelFailure: Equatable {
    enum Kind: String {
        case configuration = "SSH 配置异常"
        case authentication = "认证失败"
        case refused = "连接被拒"
        case unreachable = "主机不可达"
        case dns = "DNS 解析失败"
        case hostKey = "主机密钥校验失败"
        case hostKeyChanged = "主机密钥已变更"
        case portInUse = "本地端口被占用"
        case disconnected = "连接已断开"
        case other = "SSH 连接失败"
    }
    let kind: Kind
    let diagnostic: String
    var title: String { kind.rawValue }
    var advice: String {
        switch kind {
        case .configuration:
            let text = diagnostic.lowercased()
            if let host = ["aws-proxy", "local-proxy"].first(where: { text.contains("could not resolve hostname \($0):") }) {
                return "请先在 ~/.ssh/config 中配置 \(host)。"
            }
            if text.contains("bad owner or permissions") || text.contains("unprotected private key") {
                return "请检查 SSH 配置或密钥文件的访问权限。"
            }
            if text.contains("identity file") || text.contains("identityfile") || text.contains("load key") {
                return "SSH 密钥无法使用，请检查密钥路径和文件。"
            }
            return "请检查 ~/.ssh/config，修正配置后重试。"
        case .authentication:
            if diagnostic.lowercased().contains("keyboard-interactive") {
                return "交互认证未完成或被服务器拒绝。请重新连接，在弹窗中输入密码或验证码，并确认 SSH 用户正确。"
            }
            return "检查 SSH 用户、密钥与 ssh-agent；如弹出认证窗口，请完成密码或密钥口令输入。"
        case .refused: return "检查服务器 SSH 服务是否运行、端口和防火墙是否正确。"
        case .unreachable: return "检查网络、VPN、服务器地址及路由。"
        case .dns: return "检查 SSH 主机别名、HostName 和 DNS 设置。"
        case .hostKey, .hostKeyChanged: return "在终端核对服务器身份与主机指纹；确认原因后再更新 known_hosts。"
        case .portInUse: return "新连接无法使用该本地端口；已有监听可能是正常工作的隧道。请先确认监听者，或更换本地端口。自动重试最多两次。"
        case .disconnected: return "检查网络或服务器状态后重新连接。"
        case .other: return "查看 SSH 原始错误，并在终端测试相同主机别名。"
        }
    }

    static func classify(_ diagnostic: String, wasConnected: Bool = false) -> TunnelFailure {
        let text = diagnostic.lowercased()
        let kind: Kind
        // Bind failures must win over a simultaneous network error. Never classify a generic
        // "forwarding failed" as port occupancy: permissions or a remote forward can also fail.
        if text.contains("address already in use") && !text.contains("remote port forwarding failed") {
            kind = .portInUse
        } else if ["identification has changed", "host key has changed"].contains(where: text.contains) {
            kind = .hostKeyChanged
        } else if text.contains("host key verification failed") {
            kind = .hostKey
        } else if ["bad configuration option", "bad configuration options", "missing argument",
                   "bad owner or permissions", "unprotected private key file",
                   "identity file", "identityfile", "invalid port", "bad port",
                   "cannot open user config file", "can't open user config file",
                   "could not resolve hostname aws-proxy:", "could not resolve hostname local-proxy:"].contains(where: text.contains)
                    || (text.contains("load key") && ["invalid format", "no such file", "permission denied", "error in libcrypto"].contains(where: text.contains)) {
            kind = .configuration
        } else if text.contains("bind") && text.contains("permission denied") {
            kind = .other
        } else if ["permission denied", "authentication failed", "too many authentication failures", "no supported authentication"].contains(where: text.contains) {
            kind = .authentication
        } else if ["could not resolve hostname", "name or service not known", "nodename nor servname", "temporary failure in name resolution"].contains(where: text.contains) {
            kind = .dns
        } else if text.contains("connection refused") {
            kind = .refused
        } else if ["no route to host", "network is unreachable", "host is down", "operation timed out", "connection timed out"].contains(where: text.contains) {
            kind = .unreachable
        } else if wasConnected || ["connection reset", "broken pipe", "connection closed", "server not responding"].contains(where: text.contains) {
            kind = .disconnected
        } else {
            kind = .other
        }
        return TunnelFailure(kind: kind, diagnostic: diagnostic)
    }
}
