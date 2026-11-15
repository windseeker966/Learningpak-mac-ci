import CryptoKit
import Foundation

/// 手机额度的学习码：iPad 显示今天学了多少分钟、开始了几次，再附一个 6 位校验码；手机（时间记录 App）输入后核对，
/// 换成手机的使用额度。离线、不联网，校验码只防手滑和随手乱填，不当作安全措施。
/// 手机端的实现（time-tracker-android 的 ScreenBudget）必须和这里一致：
/// HMAC-SHA256(key: 配对密钥的 UTF-8, message: "日期|分钟|次数" 的 UTF-8)，取前 4 字节按大端读成整数、去掉最高位，模 1,000,000，补足 6 位。
/// 日期是 StudyPacePolicy.dayKey（早上 5 点切分），手机端用同样的切分
enum StudyCode {
    /// 一段连续学习满这么久算「开始」了一次（连续学习的起止见 StudyPacePolicy）
    static let startAfter: TimeInterval = 10 * 60
    /// 配对密钥用的字符：去掉了容易看错的 0、1、i、l、o
    static let secretAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")
    static let secretLength = 10

    static func code(secret: String, day: String, minutes: Int, starts: Int) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = Array(HMAC<SHA256>.authenticationCode(for: Data("\(day)|\(minutes)|\(starts)".utf8), using: key))
        let value = (UInt32(mac[0] & 0x7f) << 24) | (UInt32(mac[1]) << 16) | (UInt32(mac[2]) << 8) | UInt32(mac[3])
        return String(format: "%06u", value % 1_000_000)
    }

    static func newSecret<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<secretLength).map { _ in secretAlphabet.randomElement(using: &generator)! })
    }

    static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return newSecret(using: &generator)
    }

    /// 连续学了 streakSeconds，算不算开始了一次
    static func countsAsStart(streakSeconds: TimeInterval) -> Bool {
        streakSeconds >= startAfter
    }
}
