import CryptoKit
import Foundation

// 经中转服务器交换的数据块：信箱号和加密（PhoneRelayCrypto）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/PhoneRelayCrypto.swift Tests/PhoneRelayCryptoTests.swift -o /tmp/phone-relay-crypto-tests
// /tmp/phone-relay-crypto-tests
@main
private enum PhoneRelayCryptoTests {
    static func main() {
        typealias C = PhoneRelayCrypto
        let secret = "ABCDEFGHIJKLMNOP"
        let plain = Data(#"{"v":1,"results":[]}"#.utf8)

        // 信箱号：32 个小写十六进制，同一个密钥总是同一个，换密钥就变
        let box = C.mailbox(secret: secret)
        precondition(box.count == 32 && box.allSatisfy { "0123456789abcdef".contains($0) })
        precondition(box == C.mailbox(secret: secret) && box != C.mailbox(secret: "ABCDEFGHIJKLMNOQ"))
        // 固定的值：手机端（RelayCrypto.java）要算出一样的
        precondition(box == "d034e639654fbe6d92cd8a463aab5f90", "mailbox = \(box)")

        // 加密后能解开；长度 = 12 + 明文 + 16；每次 nonce 不同，密文不同
        let a = try! C.seal(plain, secret: secret, purpose: "up")
        let b = try! C.seal(plain, secret: secret, purpose: "up")
        precondition(a.count == plain.count + 28 && a != b)
        precondition(try! C.open(a, secret: secret, purpose: "up") == plain)
        // 用途、密钥不对，或被改过：解不开
        precondition((try? C.open(a, secret: secret, purpose: "down")) == nil, "用途不对")
        precondition((try? C.open(a, secret: "ABCDEFGHIJKLMNOQ", purpose: "up")) == nil, "密钥不对")
        var tampered = a
        tampered[20] ^= 1
        precondition((try? C.open(tampered, secret: secret, purpose: "up")) == nil, "被改过")
        precondition((try? C.open(Data(count: 10), secret: secret, purpose: "up")) == nil, "太短")

        // 固定 nonce 的密文：手机端要能解开这一块（见 learningpack-android 的 RelayCryptoTest）
        let nonce = try! AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let fixed = try! C.seal(Data("hello relay".utf8), secret: secret, purpose: "down", nonce: nonce)
        precondition(fixed.base64EncodedString() == "BwcHBwcHBwcHBwcHg5hef51Ho0/F/ToUddWSXCmdwrNL8wyJhrVx",
                     "fixed = \(fixed.base64EncodedString())")

        print("PhoneRelayCryptoTests 通过")
    }
}
