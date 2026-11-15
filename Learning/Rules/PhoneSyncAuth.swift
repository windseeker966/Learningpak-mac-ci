import CryptoKit
import Foundation

// 和手机复习 App（learningpack-android）同步时的配对密钥和请求签名。协议见 learningpack-android/PROTOCOL.md。
// 只依赖 Foundation 和 CryptoKit，测试见 Tests/PhoneSyncAuthTests.swift。

nonisolated enum PhoneSyncAuth {
    /// 请求、响应的时间和本机时间相差超过这么多秒就不认
    static let maxSkew: Double = 300
    /// 密钥长度（Base32 字符数，80 位）
    static let secretLength = 16
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// 用户填的配对密钥：去掉连字符和空白、转大写；不是 16 个 Base32 字符时为 nil
    static func normalize(_ input: String) -> String? {
        let s = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard s.count == secretLength, s.allSatisfy(alphabet.contains) else { return nil }
        return s
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacHex(secret: String, _ message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 请求的签名：方法、路径（含查询串）、时间（Unix 毫秒）、请求体的 SHA-256
    static func requestSignature(secret: String, method: String, path: String, time: Int64, body: Data) -> String {
        hmacHex(secret: secret, "\(method)\n\(path)\n\(time)\n\(sha256Hex(body))")
    }

    /// 响应的签名：时间（Unix 毫秒）、响应体的 SHA-256
    static func responseSignature(secret: String, time: Int64, body: Data) -> String {
        hmacHex(secret: secret, "response\n\(time)\n\(sha256Hex(body))")
    }

    static func isFresh(time: Int64, now: Int64) -> Bool {
        abs(Double(now - time)) / 1000 <= maxSkew
    }
}
