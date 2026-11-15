import Foundation

// 手机额度的学习码（StudyCode）。期望值用 Python 的 hmac 独立算出，手机端（time-tracker-android 的 ScreenBudget）也用这几组核对：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/StudyCode.swift Tests/StudyCodeTests.swift -o /tmp/study-code-tests
// /tmp/study-code-tests
@main
private enum StudyCodeTests {
    /// 固定种子的随机数，检查密钥生成
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func main() {
        precondition(StudyCode.code(secret: "abc234defg", day: "2026-10-24", minutes: 85, starts: 3) == "027712")
        precondition(StudyCode.code(secret: "k7m2p9x4qe", day: "2026-01-05", minutes: 0, starts: 0) == "609220", "不足 6 位时补 0")
        precondition(StudyCode.code(secret: "k7m2p9x4qe", day: "2026-12-31", minutes: 150, starts: 4) == "935521")
        precondition(StudyCode.code(secret: "abc234defg", day: "2026-10-24", minutes: 86, starts: 3) != "027712", "分钟数不同，码不同")
        precondition(StudyCode.code(secret: "abc234defh", day: "2026-10-24", minutes: 85, starts: 3) != "027712", "密钥不同，码不同")

        var g = Seeded(state: 42)
        let secret = StudyCode.newSecret(using: &g)
        precondition(secret.count == StudyCode.secretLength)
        precondition(secret.allSatisfy { StudyCode.secretAlphabet.contains($0) })
        precondition(!secret.contains { "01ilo".contains($0) }, "不用容易看错的字符")
        var h = Seeded(state: 42)
        precondition(StudyCode.newSecret(using: &h) == secret)

        precondition(!StudyCode.countsAsStart(streakSeconds: 9 * 60 + 59))
        precondition(StudyCode.countsAsStart(streakSeconds: 10 * 60))
        print("StudyCodeTests passed")
    }
}
