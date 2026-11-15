import CryptoKit
import Foundation

/// 数据存档上传到 Google Drive 的规则：什么时候该备份、云端留哪几份、登录用的 PKCE（RFC 7636）
enum CloudBackup {
    /// 上次成功上传超过这么久，打开 App 时自动备份一次（不卡在整 24 小时：每天大致同一时间打开也能每天备份）
    static let interval: TimeInterval = 20 * 60 * 60
    /// 自动备份失败后，这么久内不再自动重试
    static let retryAfter: TimeInterval = 60 * 60
    /// 云端保留最近几份
    static let keepCount = 10

    /// lastAttempt 晚于 lastSuccess 说明上次没成功
    static func isDue(lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastAttempt, lastAttempt > lastSuccess ?? .distantPast, now.timeIntervalSince(lastAttempt) < retryAfter {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }

    struct RemoteFile: Equatable, Sendable {
        var id: String
        var name: String
        var created: Date
    }

    /// 超出 keepCount 的旧存档（按创建时间，新的留下）
    static func stale(_ files: [RemoteFile], keep: Int = keepCount) -> [RemoteFile] {
        Array(files.sorted { $0.created > $1.created }.dropFirst(keep))
    }

    /// PKCE 的 code_verifier：43～128 个 [A-Za-z0-9-._~]，这里用 32 字节随机数的 base64url（43 个字符）
    static func verifier<G: RandomNumberGenerator>(using generator: inout G) -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func verifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return verifier(using: &generator)
    }

    /// code_challenge（S256）：BASE64URL(SHA256(verifier))
    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
