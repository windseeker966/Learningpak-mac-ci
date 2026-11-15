import Foundation

// 和手机复习 App 同步时的配对密钥和签名（PhoneSyncAuth）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/PhoneSyncAuth.swift Tests/PhoneSyncAuthTests.swift -o /tmp/phone-sync-auth-tests
// /tmp/phone-sync-auth-tests
@main
private enum PhoneSyncAuthTests {
    static func main() {
        typealias A = PhoneSyncAuth

        // 配对密钥：去掉连字符、空白，转大写；只认 16 个 Base32 字符
        precondition(A.normalize("abcd-efgh-ijkl-mnop") == "ABCDEFGHIJKLMNOP")
        precondition(A.normalize(" ABCD EFGH IJKL MNOP ") == "ABCDEFGHIJKLMNOP")
        precondition(A.normalize("ABCD-EFGH-IJKL-MNO") == nil, "少一位")
        precondition(A.normalize("ABCD-EFGH-IJKL-MNO1") == nil, "1 不是 Base32 字符")
        precondition(A.normalize("ABCD-EFGH-IJKL-MNO8") == nil, "8 不是 Base32 字符")

        // 签名：期望值用 Python 的 hmac、hashlib 独立算出（手机端 Java 的测试用同一组）
        precondition(A.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        precondition(A.requestSignature(secret: "ABCDEFGHIJKLMNOP", method: "POST", path: "/pull",
                                        time: 1_761_360_000_000, body: Data("{}".utf8))
                     == "a78c01dd604be8f2865ace8269c60e1778b91328b7b8ee9807dc2105104e4d8c")
        precondition(A.responseSignature(secret: "ABCDEFGHIJKLMNOP", time: 1_761_360_000_000, body: Data(#"{"v":1}"#.utf8))
                     == "26f96ea02dd08012648b8c5e98b135358776d7b2932edbecddd1c972a922e0cc")
        precondition(A.requestSignature(secret: "ABCDEFGHIJKLMNOP", method: "GET", path: "/pull",
                                        time: 1_761_360_000_000, body: Data("{}".utf8))
                     != A.requestSignature(secret: "ABCDEFGHIJKLMNOP", method: "POST", path: "/pull",
                                           time: 1_761_360_000_000, body: Data("{}".utf8)), "方法不同签名就不同")

        // 时间差 5 分钟以内才认
        precondition(A.isFresh(time: 1_000_000, now: 1_000_000 + 300_000))
        precondition(!A.isFresh(time: 1_000_000, now: 1_000_000 + 300_001))
        precondition(A.isFresh(time: 1_000_000 + 299_000, now: 1_000_000))

        print("PhoneSyncAuthTests passed")
    }
}
