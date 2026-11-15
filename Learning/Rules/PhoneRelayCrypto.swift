import CryptoKit
import Foundation

// 不在同一个网络时，经中转服务器和手机复习 App 交换的数据块：信箱号和加密。协议见 learningpack-android/PROTOCOL.md 的「中转」，
// 手机端的实现（RelayCrypto.java）必须一致。只依赖 Foundation 和 CryptoKit，测试见 Tests/PhoneRelayCryptoTests.swift。

nonisolated enum PhoneRelayCrypto {
    enum CryptoError: Error { case badBlock }

    /// 信箱号：HMAC-SHA256(配对密钥, "lp-relay-box") 的十六进制前 32 个字符
    static func mailbox(secret: String) -> String {
        String(hmac(secret: secret, "lp-relay-box").map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// 加密：AES-256-GCM，密钥 HMAC-SHA256(配对密钥, "lp-relay-key")；结果是 nonce(12) ‖ 密文 ‖ tag(16)，
    /// purpose（up、down、img:<sha>）作附加数据
    static func seal(_ plain: Data, secret: String, purpose: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key(secret: secret), nonce: nonce, authenticating: Data(purpose.utf8))
        guard let combined = box.combined else { throw CryptoError.badBlock }
        return combined
    }

    /// 解开 seal 的结果；密钥、用途不对或被改过时抛错
    static func open(_ block: Data, secret: String, purpose: String) throws -> Data {
        guard block.count >= 28 else { throw CryptoError.badBlock }
        let box = try AES.GCM.SealedBox(combined: block)
        return try AES.GCM.open(box, using: key(secret: secret), authenticating: Data(purpose.utf8))
    }

    private static func key(secret: String) -> SymmetricKey {
        SymmetricKey(data: Data(hmac(secret: secret, "lp-relay-key")))
    }

    private static func hmac(secret: String, _ message: String) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }
}
